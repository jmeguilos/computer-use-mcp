import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createConnection, type Socket } from "node:net";
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

const DEFAULT_SOCKET_PATH = join(
  homedir(),
  "Library",
  "Application Support",
  "ComputerUseMCP",
  "runtime",
  "host.sock"
);

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
  removeAbortListener: () => void;
};

type NativeSocketClientOptions = {
  socketPath?: string;
  authTokenPath?: string;
  clientName?: string;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
  maxLineBytes?: number;
};

export class NativeSocketClient implements NativeBridge {
  readonly #socketPath: string;
  readonly #authTokenPath: string;
  readonly #clientName: string;
  readonly #connectTimeoutMs: number;
  readonly #requestTimeoutMs: number;
  readonly #maxLineBytes: number;
  readonly #instanceId = randomUUID();
  readonly #pending = new Map<string, PendingRequest>();
  #socket: Socket | undefined;
  #connectionId: string | undefined;
  #connectionToken: string | undefined;
  #connectPromise: Promise<void> | undefined;
  #readBuffer = "";

  public constructor(options: NativeSocketClientOptions = {}) {
    this.#socketPath =
      options.socketPath ?? process.env.COMPUTER_USE_MCP_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
    this.#authTokenPath = options.authTokenPath ?? join(dirname(this.#socketPath), "auth.token");
    this.#clientName = options.clientName ?? "computer-use-mcp-server";
    this.#connectTimeoutMs = options.connectTimeoutMs ?? 5_000;
    this.#requestTimeoutMs = options.requestTimeoutMs ?? 10_000;
    this.#maxLineBytes = options.maxLineBytes ?? NATIVE_MAX_LINE_BYTES;
  }

  public isConnected(): boolean {
    return (
      this.#socket !== undefined &&
      !this.#socket.destroyed &&
      this.#connectionId !== undefined &&
      this.#connectionToken !== undefined
    );
  }

  public async call(
    method: NativeMethod,
    params: unknown,
    options: BridgeCallOptions = {}
  ): Promise<unknown> {
    await this.#ensureConnected(options.signal);
    const connectionId = this.#connectionId;
    const connectionToken = this.#connectionToken;
    if (connectionId === undefined || connectionToken === undefined) {
      throw this.#unavailable("The native companion did not establish a controlling connection.");
    }

    const timeoutMs = options.timeoutMs ?? this.#requestTimeoutMs;
    const maximumTimeoutMs = method === "requestAccess" ? 300_000 : 30_000;
    if (!Number.isFinite(timeoutMs) || timeoutMs < 100 || timeoutMs > maximumTimeoutMs) {
      throw new ComputerUseError(
        "BRIDGE_PROTOCOL_ERROR",
        `Native ${method} timeouts must be between 100 and ${maximumTimeoutMs} milliseconds.`
      );
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
        deadlineUnixMs: Date.now() + timeoutMs,
        params
      },
      { ...options, timeoutMs }
    );
  }

  public async close(): Promise<void> {
    const socket = this.#socket;
    this.#socket = undefined;
    this.#connectionId = undefined;
    this.#connectionToken = undefined;
    this.#connectPromise = undefined;
    if (socket !== undefined && !socket.destroyed) {
      await new Promise<void>(resolve => {
        socket.once("close", () => resolve());
        socket.end();
      });
    }
    this.#rejectAll(this.#unavailable("The native bridge connection closed."));
  }

  async #ensureConnected(signal?: AbortSignal): Promise<void> {
    if (this.isConnected()) return;
    if (this.#connectPromise === undefined) {
      this.#connectPromise = this.#connect().finally(() => {
        this.#connectPromise = undefined;
      });
    }
    await this.#raceAbort(this.#connectPromise, signal);
  }

  async #connect(): Promise<void> {
    let token: string;
    try {
      token = (await readFile(this.#authTokenPath, "utf8")).trim();
    } catch (error) {
      throw this.#unavailable(
        `Cannot read the native companion token at ${this.#authTokenPath}.`,
        error
      );
    }
    if (token.length < 16) {
      throw this.#unavailable("The native companion token is missing or malformed.");
    }

    const socket = createConnection({ path: this.#socketPath });
    this.#socket = socket;
    socket.setEncoding("utf8");
    socket.on("data", chunk => this.#onData(String(chunk)));
    socket.on("error", error => this.#onSocketError(error));
    socket.on("close", () => this.#onSocketClose());

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        socket.destroy();
        reject(this.#unavailable(`Timed out connecting to ${this.#socketPath}.`));
      }, this.#connectTimeoutMs);
      const cleanup = (): void => {
        clearTimeout(timer);
        socket.off("connect", onConnect);
        socket.off("error", onError);
      };
      const onConnect = (): void => {
        cleanup();
        resolve();
      };
      const onError = (error: Error): void => {
        cleanup();
        reject(this.#unavailable(`Cannot connect to ${this.#socketPath}.`, error));
      };
      socket.once("connect", onConnect);
      socket.once("error", onError);
    });

    const id = randomUUID();
    const uid = process.getuid?.();
    if (uid === undefined) {
      throw this.#unavailable("The native bridge requires a Unix user identity.");
    }
    const result = await this.#request(
      id,
      {
        protocol: NATIVE_PROTOCOL,
        id,
        method: "hello",
        auth: { token },
        client: {
          name: this.#clientName,
          pid: process.pid,
          uid,
          instanceId: this.#instanceId
        },
        capabilities: NATIVE_CAPABILITIES
      },
      { timeoutMs: this.#connectTimeoutMs }
    );
    const hello = HelloResultSchema.safeParse(result);
    if (!hello.success) {
      socket.destroy();
      throw new ComputerUseError(
        "BRIDGE_PROTOCOL_ERROR",
        "The native companion returned an invalid hello response."
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
    const socket = this.#socket;
    if (socket === undefined || socket.destroyed) {
      return Promise.reject(this.#unavailable("The native bridge is not connected."));
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
            remediation: "Refresh window state before retrying with a larger timeout_ms."
          })
        );
      }, timeoutMs);

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

      socket.write(line, error => {
        if (error !== null && error !== undefined) {
          const pending = this.#pending.get(id);
          pending?.reject(this.#unavailable("Failed to write to the native bridge.", error));
        }
      });
    });
  }

  #sendCancel(requestId: string): void {
    const socket = this.#socket;
    const connectionId = this.#connectionId;
    const connectionToken = this.#connectionToken;
    if (
      socket === undefined ||
      socket.destroyed ||
      connectionId === undefined ||
      connectionToken === undefined
    )
      return;
    socket.write(
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

  #onData(chunk: string): void {
    this.#readBuffer += chunk;
    for (;;) {
      const newline = this.#readBuffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.#readBuffer.slice(0, newline);
      this.#readBuffer = this.#readBuffer.slice(newline + 1);
      if (Buffer.byteLength(line, "utf8") > this.#maxLineBytes) {
        this.#socket?.destroy(
          new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge exceeded its line limit.")
        );
        return;
      }
      if (line.trim() === "") continue;
      this.#onLine(line);
    }
    if (Buffer.byteLength(this.#readBuffer, "utf8") > this.#maxLineBytes) {
      this.#socket?.destroy(
        new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge exceeded its line limit.")
      );
    }
  }

  #onLine(line: string): void {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch (error) {
      this.#socket?.destroy(
        new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge emitted invalid JSON.", {
          cause: error
        })
      );
      return;
    }

    const parsed = WireResponseSchema.safeParse(raw);
    if (!parsed.success) {
      this.#socket?.destroy(
        new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge emitted an invalid envelope.")
      );
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
    const code = this.#mapNativeCode(parsed.data.error.code);
    pending.reject(
      new ComputerUseError(code, parsed.data.error.message, {
        retryable: parsed.data.error.retryable
      })
    );
  }

  #onSocketError(error: Error): void {
    this.#rejectAll(this.#unavailable("The native bridge socket failed.", error));
  }

  #onSocketClose(): void {
    this.#socket = undefined;
    this.#connectionId = undefined;
    this.#connectionToken = undefined;
    this.#readBuffer = "";
    this.#rejectAll(this.#unavailable("The native bridge connection closed."));
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
      remediation: "Start ComputerUseMCPHost and run computer-use-mcp doctor.",
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
}
