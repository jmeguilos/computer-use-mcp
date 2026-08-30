import { describe, expect, it } from "vitest";
import type { NativeBridge, NativeMethod } from "../src/bridge/protocol.js";
import {
  collectDiagnostics,
  type CommandOptions,
  type CommandResult,
  type DiagnosticsDependencies,
  type PathObservation
} from "../src/diagnostics.js";
import { ComputerUseError } from "../src/errors.js";
import { runCli } from "../src/index.js";

const checkout = "/checkout";
const home = "/Users/diagnostic-user";
const host = `${home}/Applications/ComputerUseMCPHost.app`;
const bridge = `${host}/Contents/Helpers/ComputerUseMCPBridge`;
const runtime = `${home}/Library/Application Support/ComputerUseMCP/runtime`;

const requiredPackFiles = [
  "package.json",
  "README.md",
  "LICENSE",
  "THIRD_PARTY_NOTICES.md",
  "dist/index.js",
  "dist/index.d.ts",
  "dist/server.js",
  "dist/server.d.ts",
  "dist/bridge/index.js",
  "dist/bridge/index.d.ts",
  "dist/bridge/process-client.js",
  "dist/bridge/process-client.d.ts",
  "dist/bridge/protocol.js",
  "dist/bridge/protocol.d.ts"
];

class ReadyBridge implements NativeBridge {
  public async call(method: NativeMethod): Promise<unknown> {
    if (method !== "status") throw new Error(`Unexpected diagnostic method: ${method}`);
    return {
      status: "ready",
      nativeVersion: "0.1.0-alpha.1",
      platform: "macos",
      appControlEnabled: true,
      permissions: { accessibility: "authorized", screenRecording: "authorized" },
      activeGrants: []
    };
  }

  public async close(): Promise<void> {}

  public isConnected(): boolean {
    return true;
  }
}

function observed(kind: PathObservation["kind"], mode: string): PathObservation {
  return { exists: true, kind, mode, owner_uid: 501 };
}

function successful(stdout = "", stderr = ""): CommandResult {
  return { ok: true, exitCode: 0, stdout, stderr };
}

function createDependencies(options: {
  checkoutRoot?: string | null;
  bridgeFactory?: DiagnosticsDependencies["bridgeFactory"];
  setupMaxAttempts?: number;
  sleep?: DiagnosticsDependencies["sleep"];
} = {}): {
  dependencies: DiagnosticsDependencies;
  commands: Array<{ command: string; args: readonly string[]; options?: CommandOptions }>;
  reads: string[];
} {
  const commands: Array<{ command: string; args: readonly string[]; options?: CommandOptions }> = [];
  const reads: string[] = [];
  const paths = new Map<string, PathObservation>([
    [`${checkout}/.git`, observed("directory", "700")],
    [`${checkout}/package.json`, observed("file", "644")],
    [`${checkout}/scripts/verify-pack.sh`, observed("file", "755")],
    [host, observed("directory", "755")],
    [`${host}/Contents/Info.plist`, observed("file", "644")],
    [`${host}/Contents/MacOS/ComputerUseMCPHost`, observed("file", "755")],
    [bridge, observed("file", "755")],
    [runtime, observed("directory", "700")],
    [`${runtime}/host.sock`, observed("socket", "600")],
    [`${runtime}/auth.token`, observed("file", "600")],
    [`${runtime}/source-development-mode`, observed("file", "600")],
    ...requiredPackFiles.map(
      path =>
        [
          `${checkout}/packages/mcp/${path}`,
          observed("file", path === "dist/index.js" ? "755" : "644")
        ] as const
    )
  ]);

  const runCommand = async (
    command: string,
    args: readonly string[],
    commandOptions?: CommandOptions
  ): Promise<CommandResult> => {
    commands.push({ command, args, ...(commandOptions === undefined ? {} : { options: commandOptions }) });
    if (command === "/usr/bin/sw_vers") return successful("14.6.1\n");
    if (command === "/usr/bin/swift") return successful("Apple Swift version 6.0\n");
    if (command === "npm" && args[0] === "--version") return successful("11.5.1\n");
    if (command === "npm" && args[0] === "pack") {
      return successful(
        JSON.stringify([
          {
            files: requiredPackFiles.map(path => ({
              path,
              ...(path === "dist/index.js" ? { mode: 0o755 } : {})
            }))
          }
        ])
      );
    }
    if (command === "/usr/bin/plutil") {
      return successful(
        JSON.stringify({
          CFBundleExecutable: "ComputerUseMCPHost",
          CFBundleIdentifier: "com.jmeguilos.computer-use-mcp.host",
          CFBundleShortVersionString: "0.1.0",
          CFBundleVersion: "1",
          CFBundlePackageType: "APPL",
          ComputerUseMCPReleaseVersion: "0.1.0-alpha.1",
          LSMinimumSystemVersion: "14.4",
          LSUIElement: true
        })
      );
    }
    if (command === "/usr/bin/codesign" && args[0] === "--verify") return successful();
    if (command === "/usr/bin/codesign" && args[0] === "--display") {
      const identifier = args.at(-1) === host
        ? "com.jmeguilos.computer-use-mcp.host"
        : "com.jmeguilos.computer-use-mcp.bridge";
      return successful(
        "",
        [
          `Identifier=${identifier}`,
          "Signature=adhoc",
          "TeamIdentifier=not set",
          `designated => identifier "${identifier}"`
        ].join("\n")
      );
    }
    if (command === "/bin/ps") {
      return successful(`123 501 ${host}/Contents/MacOS/ComputerUseMCPHost\n`);
    }
    if (command === "/usr/bin/open") return successful();
    return { ok: false, exitCode: 127, stdout: "", stderr: "unexpected command" };
  };

  const dependencies: DiagnosticsDependencies = {
    platform: "darwin",
    architecture: "arm64",
    nodeVersion: "20.18.0",
    nodeExecutable: "/usr/local/bin/node",
    uid: 501,
    environment: {},
    homeDirectory: home,
    workingDirectory: checkout,
    moduleDirectory: `${checkout}/packages/mcp/dist`,
    hostAppPath: host,
    bridgePath: bridge,
    checkoutRoot: options.checkoutRoot === undefined ? checkout : options.checkoutRoot,
    runCommand,
    inspectPath: async path =>
      paths.get(path) ?? { exists: false, kind: "missing", mode: null, owner_uid: null },
    readTextFile: async path => {
      reads.push(path);
      if (path !== `${checkout}/packages/mcp/package.json`) throw new Error("Unexpected file read");
      return JSON.stringify({
        name: "@jmeguilos/computer-use-mcp",
        version: "0.1.0-alpha.1",
        license: "Apache-2.0",
        files: ["dist", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"],
        scripts: {}
      });
    },
    readDevelopmentMarker: async path => {
      reads.push(path);
      if (path !== `${runtime}/source-development-mode`) {
        throw new Error("Unexpected development marker read");
      }
      return "ComputerUseMCP source development v1\n";
    },
    bridgeFactory: options.bridgeFactory ?? (() => new ReadyBridge()),
    sleep: options.sleep ?? (async () => undefined),
    now: () => new Date("2026-08-29T20:00:00.000Z"),
    ...(options.setupMaxAttempts === undefined
      ? {}
      : { setupMaxAttempts: options.setupMaxAttempts })
  };
  return { dependencies, commands, reads };
}

describe("doctor and setup diagnostics", () => {
  it("emits one JSON line with read-only host, signing, runtime, TCC, and pack evidence", async () => {
    const { dependencies, commands, reads } = createDependencies();
    let stdout = "";
    let stderr = "";
    const exitCode = await runCli(["doctor"], {
      diagnostics: dependencies,
      stdout: { write: value => (stdout += value) },
      stderr: { write: value => (stderr += value) }
    });
    expect(exitCode).toBe(0);
    expect(stderr).toBe("");
    expect(stdout.endsWith("\n")).toBe(true);
    expect(stdout.trim().split("\n")).toHaveLength(1);

    const report = JSON.parse(stdout) as Record<string, unknown>;
    expect(report).toMatchObject({
      ok: true,
      ready_for_control: true,
      mode: "doctor",
      package: { built_version: "0.1.0-alpha.1", source_checkout: true },
      system: {
        platform: { value: "darwin" },
        architecture: { value: "arm64" },
        node: { version: "20.18.0" },
        npm: { version: "11.5.1" },
        swift: { version: "Apple Swift version 6.0" }
      },
      host: {
        bundle_id: "com.jmeguilos.computer-use-mcp.host",
        release_version: "0.1.0-alpha.1",
        signing: { verified: true, identifier: "com.jmeguilos.computer-use-mcp.host" }
      },
      bridge: {
        path: bridge,
        signing: {
          verified: true,
          identifier: "com.jmeguilos.computer-use-mcp.bridge",
          signature_kind: "adhoc"
        },
        signing_coherent_with_host: true
      },
      runtime: {
        directory: { mode: "700", kind: "directory" },
        socket: { mode: "600", kind: "socket" },
        token: { mode: "600", kind: "file", read_by_cli: false },
        development_marker: { mode: "600", contents_valid: true, read_by_cli: true }
      },
      native_handshake: { attempts: 1, status: { status: "ready" } },
      tcc: { accessibility: "authorized", screen_recording: "authorized", ready: true },
      source_pack_verifier: { ok: true }
    });
    expect(commands.some(call => call.command === "/usr/bin/open")).toBe(false);
    expect(reads).toContain(`${checkout}/packages/mcp/package.json`);
    expect(reads).toContain(`${runtime}/source-development-mode`);
    expect(reads).not.toContain(`${runtime}/auth.token`);
  });

  it("retries boundedly after the setup workflow has launched the native host", async () => {
    let attempts = 0;
    const sleeps: number[] = [];
    const { dependencies, commands } = createDependencies({
      checkoutRoot: null,
      bridgeFactory: () => {
        attempts += 1;
        if (attempts < 3) {
          return {
            call: async () => {
              throw new ComputerUseError("BRIDGE_UNAVAILABLE", "host socket not ready");
            },
            close: async () => undefined,
            isConnected: () => false
          };
        }
        return new ReadyBridge();
      },
      sleep: async milliseconds => {
        sleeps.push(milliseconds);
      }
    });
    const result = await collectDiagnostics("setup", dependencies);
    expect(result.exitCode).toBe(0);
    expect(result.report.host_launch).toMatchObject({ attempted: false, ok: true });
    expect(result.report.native_handshake).toMatchObject({ ok: true, attempts: 3, max_attempts: 12 });
    expect(sleeps).toEqual([500, 500]);
    expect(commands.filter(call => call.command === "/usr/bin/open")).toHaveLength(0);
    expect(result.report).not.toHaveProperty("source_pack_verifier");
  });

  it("stops retrying at the configured bound and reports failure without leaking a token", async () => {
    let attempts = 0;
    const sleeps: number[] = [];
    const { dependencies } = createDependencies({
      checkoutRoot: null,
      setupMaxAttempts: 3,
      bridgeFactory: () => {
        attempts += 1;
        return {
          call: async () => {
            throw new ComputerUseError("BRIDGE_UNAVAILABLE", "still starting");
          },
          close: async () => undefined,
          isConnected: () => false
        };
      },
      sleep: async milliseconds => {
        sleeps.push(milliseconds);
      }
    });
    const result = await collectDiagnostics("setup", dependencies);
    expect(result.exitCode).toBe(1);
    expect(attempts).toBe(3);
    expect(sleeps).toEqual([500, 500]);
    expect(result.report.native_handshake).toMatchObject({
      ok: false,
      attempts: 3,
      max_attempts: 3,
      error_code: "BRIDGE_UNAVAILABLE",
      error: "The native host did not become ready within the bounded setup/doctor window."
    });
    expect(JSON.stringify(result.report)).not.toContain("auth token contents");
    expect(result.report.runtime.token.read_by_cli).toBe(false);
  });

  it("requires the exact fixed development marker for ad-hoc host and bridge signatures", async () => {
    let bridgeAttempts = 0;
    const { dependencies } = createDependencies({ checkoutRoot: null });
    dependencies.readDevelopmentMarker = async () => "marker-content-canary";
    dependencies.bridgeFactory = () => {
      bridgeAttempts += 1;
      return new ReadyBridge();
    };

    const result = await collectDiagnostics("doctor", dependencies);
    expect(result.exitCode).toBe(1);
    expect(result.report.bridge).toMatchObject({
      ok: false,
      signing_coherent_with_host: false
    });
    expect(result.report.runtime.development_marker).toMatchObject({
      contents_checked: true,
      contents_valid: false,
      read_by_cli: true
    });
    expect(result.report.native_handshake.attempts).toBe(0);
    expect(bridgeAttempts).toBe(0);
    expect(JSON.stringify(result.report)).not.toContain("marker-content-canary");
  });

  it("verifies release host/helper signing coherence with an exact codesign requirement", async () => {
    const { dependencies, commands } = createDependencies({ checkoutRoot: null });
    const baseRunCommand = dependencies.runCommand!;
    dependencies.runCommand = async (command, args, options) => {
      if (command === "/usr/bin/codesign" && args[0] === "--display") {
        await baseRunCommand(command, args, options);
        const identifier = args.at(-1) === host
          ? "com.jmeguilos.computer-use-mcp.host"
          : "com.jmeguilos.computer-use-mcp.bridge";
        return successful(
          "",
          [
            `Identifier=${identifier}`,
            "Authority=Developer ID Application: Example",
            "TeamIdentifier=ABCDE12345",
            `designated => identifier "${identifier}" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"`
          ].join("\n")
        );
      }
      return baseRunCommand(command, args, options);
    };

    const result = await collectDiagnostics("doctor", dependencies);
    expect(result.exitCode).toBe(0);
    expect(result.report.host.signing).toMatchObject({
      signature_kind: "certificate",
      team_identifier: "ABCDE12345"
    });
    expect(result.report.bridge).toMatchObject({
      ok: true,
      signing_coherent_with_host: true,
      signing: { signature_kind: "certificate", team_identifier: "ABCDE12345" }
    });
    const requirementCall = commands.find(
      call =>
        call.command === "/usr/bin/codesign" &&
        call.args.some(argument => argument.startsWith("-R="))
    );
    expect(requirementCall?.args).toContain(
      '-R=identifier "com.jmeguilos.computer-use-mcp.bridge" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"'
    );
  });

  it("fails closed on unsafe token metadata without reading the token or spawning the bridge", async () => {
    let bridgeAttempts = 0;
    const { dependencies, reads } = createDependencies({ checkoutRoot: null });
    const baseInspectPath = dependencies.inspectPath!;
    dependencies.inspectPath = async path =>
      path === `${runtime}/auth.token`
        ? { exists: true, kind: "file", mode: "644", owner_uid: 501 }
        : baseInspectPath(path);
    dependencies.bridgeFactory = () => {
      bridgeAttempts += 1;
      return new ReadyBridge();
    };

    const result = await collectDiagnostics("doctor", dependencies);
    expect(result.report.runtime.token).toMatchObject({ ok: false, mode: "644", read_by_cli: false });
    expect(result.report.native_handshake.attempts).toBe(0);
    expect(bridgeAttempts).toBe(0);
    expect(reads).not.toContain(`${runtime}/auth.token`);
  });

  it("does not retry a malformed native status response", async () => {
    let attempts = 0;
    const sleeps: number[] = [];
    const { dependencies } = createDependencies({ checkoutRoot: null });
    dependencies.setupMaxAttempts = 8;
    dependencies.bridgeFactory = () => {
      attempts += 1;
      return {
        call: async () => ({ status: "ready" }),
        close: async () => undefined,
        isConnected: () => true
      };
    };
    dependencies.sleep = async milliseconds => {
      sleeps.push(milliseconds);
    };

    const result = await collectDiagnostics("setup", dependencies);
    expect(attempts).toBe(1);
    expect(sleeps).toEqual([]);
    expect(result.report.native_handshake).toMatchObject({
      ok: false,
      attempts: 1,
      error_code: "BRIDGE_PROTOCOL_ERROR"
    });
  });

  it("honors one global setup readiness deadline, not a fresh deadline per retry", async () => {
    let monotonic = 0;
    let attempts = 0;
    const sleeps: number[] = [];
    const { dependencies } = createDependencies({ checkoutRoot: null });
    dependencies.setupMaxAttempts = 12;
    dependencies.setupTimeBudgetMs = 1_000;
    dependencies.monotonicNow = () => monotonic;
    dependencies.bridgeFactory = () => {
      attempts += 1;
      return {
        call: async () => {
          monotonic = 1_000;
          throw new ComputerUseError("BRIDGE_UNAVAILABLE", "still starting");
        },
        close: async () => undefined,
        isConnected: () => false
      };
    };
    dependencies.sleep = async milliseconds => {
      sleeps.push(milliseconds);
    };

    const result = await collectDiagnostics("setup", dependencies);
    expect(attempts).toBe(1);
    expect(sleeps).toEqual([]);
    expect(result.report.native_handshake).toMatchObject({ ok: false, attempts: 1 });
  });

  it("detects duplicate and unexpected-path host processes", async () => {
    const { dependencies } = createDependencies({ checkoutRoot: null });
    const baseRunCommand = dependencies.runCommand!;
    dependencies.runCommand = async (command, args, options) => {
      if (command === "/bin/ps") {
        await baseRunCommand(command, args, options);
        return successful(
          [
            `123 501 ${host}/Contents/MacOS/ComputerUseMCPHost`,
            "456 501 /private/tmp/ComputerUseMCPHost"
          ].join("\n")
        );
      }
      return baseRunCommand(command, args, options);
    };

    const result = await collectDiagnostics("doctor", dependencies);
    expect(result.report.processes).toMatchObject({
      ok: false,
      inspected: true,
      duplicate_detected: true,
      unexpected_path_detected: true
    });
    expect(result.report.processes.host_processes.map(process => process.pid)).toEqual([123, 456]);
    expect(result.report.ready_for_control).toBe(false);
  });

  it("keeps runtime readiness distinct from optional source toolchain health and redacts subprocess output", async () => {
    const commandCanary = "diagnostic-command-output-canary";
    const { dependencies } = createDependencies({ checkoutRoot: null });
    const baseRunCommand = dependencies.runCommand!;
    dependencies.runCommand = async (command, args, options) => {
      if (command === "/usr/bin/swift") {
        await baseRunCommand(command, args, options);
        return { ok: false, exitCode: 1, stdout: "", stderr: commandCanary };
      }
      return baseRunCommand(command, args, options);
    };

    const result = await collectDiagnostics("doctor", dependencies);
    expect(result.exitCode).toBe(1);
    expect(result.report.ok).toBe(false);
    expect(result.report.ready_for_control).toBe(true);
    expect(result.report.system.swift.ok).toBe(false);
    expect(JSON.stringify(result.report)).not.toContain(commandCanary);
  });

  it("rejects an installed Swift toolchain older than Swift 6", async () => {
    const { dependencies } = createDependencies({ checkoutRoot: null });
    const baseRunCommand = dependencies.runCommand!;
    dependencies.runCommand = async (command, args, options) => {
      if (command === "/usr/bin/swift") {
        await baseRunCommand(command, args, options);
        return successful("Apple Swift version 5.10.1\n");
      }
      return baseRunCommand(command, args, options);
    };

    const result = await collectDiagnostics("doctor", dependencies);
    expect(result.exitCode).toBe(1);
    expect(result.report.ready_for_control).toBe(true);
    expect(result.report.system.swift).toEqual({
      ok: false,
      version: "Apple Swift version 5.10.1",
      minimum_major: 6,
      error: "Swift 6 or newer is required to build the native host."
    });
    expect(result.report.remediation).toContain(
      "Install Xcode 16 or matching Command Line Tools with Swift 6 or newer."
    );
  });
});
