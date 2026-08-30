import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import {
  spawn,
  type ChildProcessWithoutNullStreams,
  type SpawnOptionsWithoutStdio
} from "node:child_process";
import {
  ComputerUseError,
  NativeApprovalRequiredError,
  ToolErrorCodeSchema,
  type ToolErrorCode
} from "../errors.js";
import {
  HelloResultSchema,
  NATIVE_CAPABILITIES,
  NATIVE_MAX_LINE_BYTES,
  NATIVE_PROTOCOL,
  WireResponseSchema,
  type BridgeCallOptions,
  type NativeBridge,
  type NativeMethod
} from "./protocol.js";

export const DEFAULT_BRIDGE_EXECUTABLE = join(
  homedir(),
  "Applications",
  "ComputerUseMCPHost.app",
  "Contents",
  "Helpers",
  "ComputerUseMCPBridge"
);

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
  removeAbortListener: () => void;
};

export type BridgeProcessClientOptions = {
  executablePath?: string;
  clientName?: string;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
  maxLineBytes?: number;
  environment?: NodeJS.ProcessEnv;
  stderr?: NodeJS.WritableStream;
  spawnChild?: (
    command: string,
    args: readonly string[],
    options: SpawnOptionsWithoutStdio & { stdio: ["pipe", "pipe", "pipe"] }
  ) => ChildProcessWithoutNullStreams;
};

/**
 * Production transport for the unprivileged MCP server. The signed native
 * bridge owns host authentication and peer attestation; this process never
 * reads the host token or connects to the privileged socket itself.
 */
export class BridgeProcessClient implements NativeBridge {
  readonly #executablePath: string;
  readonly #clientName: string;
  readonly #connectTimeoutMs: number;
  readonly #requestTimeoutMs: number;
  readonly #maxLineBytes: number;
  readonly #environment: NodeJS.ProcessEnv;
  readonly #stderr: NodeJS.WritableStream;
  readonly #spawnChild: NonNullable<BridgeProcessClientOptions["spawnChild"]>;
  readonly #instanceId = randomUUID();
  readonly #pending = new Map<string, PendingRequest>();
  #child: ChildProcessWithoutNullStreams | undefined;
  #connectionId: string | undefined;
  #connectionToken: string | undefined;
  #connectPromise: Promise<void> | undefined;
  #readBuffer = "";
  #closing = false;

  public constructor(options: BridgeProcessClientOptions = {}) {
    this.#executablePath =
      options.executablePath ??
      process.env.COMPUTER_USE_MCP_BRIDGE_PATH ??
      DEFAULT_BRIDGE_EXECUTABLE;
    if (!isAbsolute(this.#executablePath)) {
      throw new ComputerUseError(
        "BRIDGE_UNAVAILABLE",
        "COMPUTER_USE_MCP_BRIDGE_PATH must be an absolute executable path."
      );
    }
    this.#clientName = options.clientName ?? "computer-use-mcp-server";
    this.#connectTimeoutMs = options.connectTimeoutMs ?? 5_000;
    this.#requestTimeoutMs = options.requestTimeoutMs ?? 10_000;
    this.#maxLineBytes = options.maxLineBytes ?? NATIVE_MAX_LINE_BYTES;
    this.#environment = options.environment ?? process.env;
    this.#stderr = options.stderr ?? process.stderr;
    this.#spawnChild =
      options.spawnChild ??
      ((command, args, spawnOptions) =>
        spawn(command, [...args], spawnOptions) as ChildProcessWithoutNullStreams);
  }

  public isConnected(): boolean {
    return (
      this.#child !== undefined &&
      this.#child.exitCode === null &&
      this.#child.signalCode === null &&
      this.#connectionId !== undefined &&
      this.#connectionToken !== undefined
    );
  }

  public async call(
    method: NativeMethod,
    params: unknown,
    options: BridgeCallOptions = {}
  ): Promise<unknown> {
    const timeoutMs = options.timeoutMs ?? this.#requestTimeoutMs;
    const maximumTimeoutMs = method === "requestAccess" ? 300_000 : 30_000;
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > maximumTimeoutMs) {
      throw new ComputerUseError(
        "BRIDGE_PROTOCOL_ERROR",
        `Native ${method} timeouts must be between 1 and ${maximumTimeoutMs} milliseconds.`
      );
    }
    await this.#ensureConnected(options.signal);
    const connectionId = this.#connectionId;
    const connectionToken = this.#connectionToken;
    if (connectionId === undefined || connectionToken === undefined) {
      throw this.#unavailable("The native bridge did not establish a controlling connection.");
    }

    const id = randomUUID();
    return this.#request(
      id,
      {
        protocol: NATIVE_PROTOCOL,
        id,
        method,
        connectionId,
        connectionToken,
        params
      },
      { ...options, timeoutMs }
    );
  }

  public async close(): Promise<void> {
    this.#closing = true;
    const child = this.#child;
    this.#clearConnection();
    this.#rejectAll(this.#unavailable("The native bridge process closed."));
    if (child === undefined || child.exitCode !== null || child.signalCode !== null) return;

    child.stdin.end();
    if (await this.#waitForExit(child, 500)) return;
    child.kill("SIGTERM");
    if (await this.#waitForExit(child, 500)) return;
    child.kill("SIGKILL");
    await this.#waitForExit(child, 500);
  }

  async #ensureConnected(signal?: AbortSignal): Promise<void> {
    if (this.isConnected()) return;
    if (this.#connectPromise === undefined) {
      this.#closing = false;
      this.#connectPromise = this.#connect().finally(() => {
        this.#connectPromise = undefined;
      });
    }
    await this.#raceAbort(this.#connectPromise, signal);
  }

  async #connect(): Promise<void> {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = this.#spawnChild(this.#executablePath, [], {
        env: this.#environment,
        shell: false,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"]
      });
    } catch (error) {
      throw this.#unavailable(`Cannot start the native bridge at ${this.#executablePath}.`, error);
    }

    this.#child = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => this.#onData(String(chunk), child));
    child.stderr.on("data", chunk => this.#stderr.write(chunk));
    child.on("error", error => this.#onChildError(error, child));
    child.on("close", () => this.#onChildClose(child));

    const id = randomUUID();
    let result: unknown;
    try {
      result = await this.#request(
        id,
        {
          protocol: NATIVE_PROTOCOL,
          id,
          method: "hello",
          client: {
            name: this.#clientName,
            instanceId: this.#instanceId
          },
          capabilities: NATIVE_CAPABILITIES
        },
        { timeoutMs: this.#connectTimeoutMs }
      );
    } catch (error) {
      child.kill("SIGTERM");
      throw error;
    }

    const hello = HelloResultSchema.safeParse(result);
    if (!hello.success) {
      child.kill("SIGTERM");
      throw new ComputerUseError(
        "BRIDGE_PROTOCOL_ERROR",
        "The native bridge returned an invalid hello response."
      );
    }
    this.#connectionId = hello.data.connectionId;
    this.#connectionToken = hello.data.connectionToken;
  }

  #request(
    id: string,
    envelope: Record<string, unknown>,
    options: BridgeCallOptions
  ): Promise<unknown> {
    const child = this.#child;
    if (
      child === undefined ||
      child.exitCode !== null ||
      child.signalCode !== null ||
      child.stdin.destroyed
    ) {
      return Promise.reject(this.#unavailable("The native bridge process is not running."));
    }
    if (options.signal?.aborted === true) return Promise.reject(this.#abortError());

    let line: string;
    try {
      line = `${JSON.stringify(envelope)}\n`;
    } catch (error) {
      return Promise.reject(
        new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "Cannot encode the native bridge request.", {
          cause: error
        })
      );
    }
    if (Buffer.byteLength(line, "utf8") > this.#maxLineBytes) {
      return Promise.reject(
        new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge request exceeds its line limit.")
      );
    }

    const timeoutMs = options.timeoutMs ?? this.#requestTimeoutMs;
    return new Promise<unknown>((resolve, reject) => {
      const finish = (): void => {
        const pending = this.#pending.get(id);
        if (pending === undefined) return;
        clearTimeout(pending.timer);
        pending.removeAbortListener();
        this.#pending.delete(id);
      };
      const onAbort = (): void => {
        finish();
        this.#sendCancel(id);
        reject(this.#abortError());
      };
      options.signal?.addEventListener("abort", onAbort, { once: true });
      const timer = setTimeout(() => {
        finish();
        this.#sendCancel(id);
        reject(
          new ComputerUseError("ACTION_TIMEOUT", `The native operation exceeded ${timeoutMs}ms.`, {
            retryable: true,
            remediation: "Refresh state before retrying with a larger timeout_ms."
          })
        );
      }, timeoutMs);
      timer.unref?.();

      this.#pending.set(id, {
        resolve: value => {
          finish();
          resolve(value);
        },
        reject: error => {
          finish();
          reject(error);
        },
        timer,
        removeAbortListener: () => options.signal?.removeEventListener("abort", onAbort)
      });

      child.stdin.write(line, error => {
        if (error !== null && error !== undefined) {
          this.#pending
            .get(id)
            ?.reject(this.#unavailable("Failed to write to the native bridge process.", error));
        }
      });
    });
  }

  #sendCancel(requestId: string): void {
    const child = this.#child;
    const connectionId = this.#connectionId;
    const connectionToken = this.#connectionToken;
    if (
      child === undefined ||
      child.stdin.destroyed ||
      child.exitCode !== null ||
      connectionId === undefined ||
      connectionToken === undefined
    ) {
      return;
    }
    child.stdin.write(
      `${JSON.stringify({
        protocol: NATIVE_PROTOCOL,
        id: randomUUID(),
        method: "cancel",
        connectionId,
        connectionToken,
        params: { requestId }
      })}\n`
    );
  }

  #onData(chunk: string, child: ChildProcessWithoutNullStreams): void {
    if (child !== this.#child) return;
    this.#readBuffer += chunk;
    for (;;) {
      const newline = this.#readBuffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.#readBuffer.slice(0, newline);
      this.#readBuffer = this.#readBuffer.slice(newline + 1);
      if (Buffer.byteLength(line, "utf8") > this.#maxLineBytes) {
        this.#failProtocol("The native bridge exceeded its line limit.", child);
        return;
      }
      if (line.trim() !== "") this.#onLine(line, child);
    }
    if (Buffer.byteLength(this.#readBuffer, "utf8") > this.#maxLineBytes) {
      this.#failProtocol("The native bridge exceeded its line limit.", child);
    }
  }

  #onLine(line: string, child: ChildProcessWithoutNullStreams): void {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch (error) {
      this.#failProtocol("The native bridge emitted invalid JSON.", child, error);
      return;
    }

    const parsed = WireResponseSchema.safeParse(raw);
    if (!parsed.success) {
      this.#failProtocol("The native bridge emitted an invalid envelope.", child);
      return;
    }
    const pending = this.#pending.get(parsed.data.id);
    if (pending === undefined) return;
    if (parsed.data.ok) {
      pending.resolve(parsed.data.result);
      return;
    }
    if (parsed.data.error.code === "approval_required") {
      if (parsed.data.error.details === undefined) {
        pending.reject(
          new ComputerUseError(
            "BRIDGE_PROTOCOL_ERROR",
            "The native bridge omitted approval challenge details."
          )
        );
        return;
      }
      pending.reject(
        new NativeApprovalRequiredError(parsed.data.error.message, parsed.data.error.details)
      );
      return;
    }
    pending.reject(
      new ComputerUseError(this.#mapNativeCode(parsed.data.error.code), parsed.data.error.message, {
        retryable: parsed.data.error.retryable
      })
    );
  }

  #failProtocol(message: string, child: ChildProcessWithoutNullStreams, cause?: unknown): void {
    const error = new ComputerUseError("BRIDGE_PROTOCOL_ERROR", message, {
      ...(cause === undefined ? {} : { cause })
    });
    this.#rejectAll(error);
    if (child === this.#child) child.kill("SIGTERM");
  }

  #onChildError(error: Error, child: ChildProcessWithoutNullStreams): void {
    if (child !== this.#child) return;
    this.#rejectAll(this.#unavailable("The native bridge process failed.", error));
  }

  #onChildClose(child: ChildProcessWithoutNullStreams): void {
    if (child !== this.#child) return;
    this.#clearConnection();
    if (!this.#closing) {
      this.#rejectAll(this.#unavailable("The native bridge process exited unexpectedly."));
    }
  }

  #clearConnection(): void {
    this.#child = undefined;
    this.#connectionId = undefined;
    this.#connectionToken = undefined;
    this.#connectPromise = undefined;
    this.#readBuffer = "";
  }

  #rejectAll(error: Error): void {
    for (const pending of [...this.#pending.values()]) pending.reject(error);
  }

  #mapNativeCode(code: string): ToolErrorCode {
    const normalized = code.toUpperCase();
    const parsed = ToolErrorCodeSchema.safeParse(normalized);
    if (parsed.success) return parsed.data;
    if (normalized === "TIMEOUT") return "ACTION_TIMEOUT";
    if (normalized === "AUTH_FAILED" || normalized === "PROTOCOL_MISMATCH") {
      return "BRIDGE_UNAVAILABLE";
    }
    return "BRIDGE_PROTOCOL_ERROR";
  }

  #unavailable(message: string, cause?: unknown): ComputerUseError {
    return new ComputerUseError("BRIDGE_UNAVAILABLE", message, {
      retryable: true,
      remediation: "Install or start ComputerUseMCPHost, then run computer-use-mcp doctor.",
      ...(cause === undefined ? {} : { cause })
    });
  }

  #abortError(): Error {
    return new DOMException("The operation was cancelled.", "AbortError");
  }

  async #raceAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
    if (signal === undefined) return promise;
    if (signal.aborted) throw this.#abortError();
    return new Promise<T>((resolve, reject) => {
      const onAbort = (): void => reject(this.#abortError());
      signal.addEventListener("abort", onAbort, { once: true });
      promise.then(
        value => {
          signal.removeEventListener("abort", onAbort);
          resolve(value);
        },
        error => {
          signal.removeEventListener("abort", onAbort);
          reject(error);
        }
      );
    });
  }

  async #waitForExit(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<boolean> {
    if (child.exitCode !== null || child.signalCode !== null) return true;
    return new Promise<boolean>(resolve => {
      let settled = false;
      const finish = (value: boolean): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        child.off("close", onClose);
        resolve(value);
      };
      const onClose = (): void => finish(true);
      const timer = setTimeout(() => finish(false), timeoutMs);
      timer.unref?.();
      child.once("close", onClose);
    });
  }
}
