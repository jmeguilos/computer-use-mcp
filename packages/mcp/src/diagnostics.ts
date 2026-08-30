import { execFile, type ExecFileException } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { lstat, open, readFile } from "node:fs/promises";
import { userInfo } from "node:os";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  normalize,
  resolve
} from "node:path";
import { fileURLToPath } from "node:url";
import { Writable } from "node:stream";
import * as z from "zod/v4";
import {
  BridgeProcessClient
} from "./bridge/process-client.js";
import { NATIVE_PROTOCOL, type NativeBridge } from "./bridge/protocol.js";
import { ComputerUseError } from "./errors.js";
import { SERVER_VERSION } from "./server.js";
import { fromNativeResult } from "./utils.js";

const EXPECTED_HOST_BUNDLE_ID = "com.jmeguilos.computer-use-mcp.host";
const EXPECTED_BRIDGE_BUNDLE_ID = "com.jmeguilos.computer-use-mcp.bridge";
const HOST_APP_NAME = "ComputerUseMCPHost.app";
const HOST_EXECUTABLE_NAME = "ComputerUseMCPHost";
const BRIDGE_EXECUTABLE_NAME = "ComputerUseMCPBridge";
const PACKAGE_NAME = "@jmeguilos/computer-use-mcp";
const MINIMUM_MACOS_VERSION = "14.4";
const MINIMUM_SWIFT_MAJOR = 6;

const NativeStatusSchema = z
  .object({
    status: z.enum(["ready", "degraded", "permission_required", "unavailable"]),
    native_version: z.string().min(1).max(256),
    platform: z.literal("macos"),
    app_control_enabled: z.boolean(),
    permissions: z
      .object({
        accessibility: z.enum(["authorized", "denied", "not_determined", "restricted"]),
        screen_recording: z.enum(["authorized", "denied", "not_determined", "restricted"])
      })
      .strict(),
    active_grants: z.array(z.unknown()).max(10_000)
  })
  .strict();

export type DiagnosticsMode = "doctor" | "setup";

export type CommandOptions = {
  cwd?: string;
  environment?: NodeJS.ProcessEnv;
  timeoutMs?: number;
};

export type CommandResult = {
  ok: boolean;
  exitCode: number | null;
  stdout: string;
  stderr: string;
  error?: string;
};

export type CommandRunner = (
  command: string,
  args: readonly string[],
  options?: CommandOptions
) => Promise<CommandResult>;

export type PathKind = "directory" | "file" | "socket" | "symlink" | "other" | "missing";

export type PathObservation = {
  exists: boolean;
  kind: PathKind;
  mode: string | null;
  owner_uid: number | null;
  error?: string;
};

export type PathInspector = (path: string) => Promise<PathObservation>;

export type DiagnosticsDependencies = {
  platform?: NodeJS.Platform;
  architecture?: string;
  nodeVersion?: string;
  nodeExecutable?: string;
  uid?: number | null;
  environment?: NodeJS.ProcessEnv;
  homeDirectory?: string;
  workingDirectory?: string;
  moduleDirectory?: string;
  hostAppPath?: string;
  bridgePath?: string;
  checkoutRoot?: string | null;
  runCommand?: CommandRunner;
  inspectPath?: PathInspector;
  readTextFile?: (path: string) => Promise<string>;
  readDevelopmentMarker?: (path: string) => Promise<string>;
  bridgeFactory?: (path: string, mode: DiagnosticsMode) => NativeBridge;
  sleep?: (milliseconds: number) => Promise<void>;
  now?: () => Date;
  setupMaxAttempts?: number;
  setupRetryDelayMs?: number;
  setupTimeBudgetMs?: number;
  monotonicNow?: () => number;
};

type PathCheck = PathObservation & {
  path: string;
  expected_kind: PathKind;
  expected_mode?: string;
  expected_owner_uid: number | null;
  ok: boolean;
};

type VersionCheck = {
  ok: boolean;
  version: string | null;
  error?: string;
};

type SigningReport = {
  ok: boolean;
  verified: boolean;
  identifier: string | null;
  expected_identifier: string;
  team_identifier: string | null;
  signature_kind: "adhoc" | "certificate" | "unknown";
  authorities: string[];
  designated_requirement: string | null;
  error?: string;
};

type NativeStatusSummary = Omit<z.infer<typeof NativeStatusSchema>, "active_grants"> & {
  active_grant_count: number;
};

type NativeHandshakeReport = {
  ok: boolean;
  attempts: number;
  max_attempts: number;
  protocol: string;
  status: NativeStatusSummary | null;
  error_code?: string;
  error?: string;
};

export type DoctorReport = {
  schema_version: 1;
  ok: boolean;
  ready_for_control: boolean;
  mode: DiagnosticsMode;
  generated_at: string;
  package: {
    name: string;
    built_version: string;
    manifest_version: string | null;
    versions_match: boolean;
    source_checkout: boolean;
    ok: boolean;
    error?: string;
  };
  system: {
    platform: { ok: boolean; value: string; expected: "darwin" };
    architecture: { ok: boolean; value: string; supported: readonly ["arm64", "x64"] };
    macos: VersionCheck & { minimum: string };
    node: VersionCheck & { minimum_major: 20 };
    npm: VersionCheck;
    swift: VersionCheck & { minimum_major: 6 };
  };
  host: {
    ok: boolean;
    app: PathCheck;
    plist: PathCheck;
    executable: PathCheck;
    bundle_id: string | null;
    expected_bundle_id: string;
    short_version: string | null;
    bundle_version: string | null;
    release_version: string | null;
    package_type: string | null;
    minimum_system_version: string | null;
    ls_ui_element: boolean | null;
    signing: SigningReport;
    error?: string;
  };
  bridge: {
    ok: boolean;
    path: string;
    configured_path_was_absolute: boolean;
    executable: PathCheck;
    signing: SigningReport;
    signing_coherent_with_host: boolean;
  };
  host_launch: {
    attempted: boolean;
    ok: boolean;
    error?: string;
  };
  runtime: {
    ok: boolean;
    socket_path_was_absolute: boolean;
    directory: PathCheck;
    socket: PathCheck;
    token: PathCheck & { read_by_cli: false };
    development_marker: PathCheck & {
      contents_checked: boolean;
      contents_valid: boolean;
      read_by_cli: boolean;
    };
  };
  processes: {
    ok: boolean;
    inspected: boolean;
    duplicate_detected: boolean;
    unexpected_path_detected: boolean;
    host_processes: Array<{ pid: number; executable_path: string }>;
    error?: string;
  };
  native_handshake: NativeHandshakeReport;
  tcc: {
    accessibility: string;
    screen_recording: string;
    ready: boolean;
  };
  source_pack_verifier?: {
    ok: boolean;
    checkout_root: string;
    method: "read_only_manifest_and_built_files";
    file_count: number;
    missing_required_files: string[];
    forbidden_entries: string[];
    error?: string;
  };
  checks: Array<{ name: string; ok: boolean; detail: string }>;
  warnings: string[];
  remediation: string[];
};

export type DiagnosticsResult = {
  report: DoctorReport;
  exitCode: number;
};

export async function collectDiagnostics(
  mode: DiagnosticsMode,
  overrides: DiagnosticsDependencies = {}
): Promise<DiagnosticsResult> {
  const platform = overrides.platform ?? process.platform;
  const architecture = overrides.architecture ?? process.arch;
  const nodeVersion = overrides.nodeVersion ?? process.versions.node;
  const nodeExecutable = overrides.nodeExecutable ?? process.execPath;
  const uid = overrides.uid === undefined ? (process.getuid?.() ?? null) : overrides.uid;
  const environment = overrides.environment ?? process.env;
  const homeDirectory = overrides.homeDirectory ?? userInfo().homedir;
  const workingDirectory = overrides.workingDirectory ?? process.cwd();
  const moduleDirectory =
    overrides.moduleDirectory ?? dirname(fileURLToPath(import.meta.url));
  const packageRoot = normalize(resolve(moduleDirectory, ".."));
  const readTextFile = overrides.readTextFile ?? (path => readFile(path, "utf8"));
  const readDevelopmentMarker =
    overrides.readDevelopmentMarker ??
    (path => defaultReadDevelopmentMarker(path, uid));
  const inspectPath = overrides.inspectPath ?? defaultInspectPath;
  const runCommand = overrides.runCommand ?? defaultRunCommand;
  const sleep = overrides.sleep ?? defaultSleep;
  const now = overrides.now ?? (() => new Date());
  const monotonicNow = overrides.monotonicNow ?? Date.now;

  const configuredBridgePath =
    overrides.bridgePath ??
    environment.COMPUTER_USE_MCP_BRIDGE_PATH ??
    join(
      homeDirectory,
      "Applications",
      HOST_APP_NAME,
      "Contents",
      "Helpers",
      BRIDGE_EXECUTABLE_NAME
    );
  const configuredPathWasAbsolute = isAbsolute(configuredBridgePath);
  const bridgePath = normalize(
    configuredPathWasAbsolute ? configuredBridgePath : resolve(workingDirectory, configuredBridgePath)
  );
  const hostAppPath = normalize(
    overrides.hostAppPath ?? deriveHostAppPath(bridgePath) ?? join(homeDirectory, "Applications", HOST_APP_NAME)
  );
  const hostPlistPath = join(hostAppPath, "Contents", "Info.plist");
  const configuredSocketPath =
    environment.COMPUTER_USE_MCP_SOCKET_PATH ??
    join(homeDirectory, "Library", "Application Support", "ComputerUseMCP", "runtime", "host.sock");
  const socketPathWasAbsolute = isAbsolute(configuredSocketPath);
  const socketPath = normalize(
    socketPathWasAbsolute ? configuredSocketPath : resolve(workingDirectory, configuredSocketPath)
  );
  const runtimeDirectoryPath = dirname(socketPath);
  const tokenPath = join(runtimeDirectoryPath, "auth.token");
  const developmentMarkerPath = join(runtimeDirectoryPath, "source-development-mode");

  const npm = npmInvocation(environment, nodeExecutable, ["--version"]);
  const [macosResult, npmResult, swiftResult] = await Promise.all([
    platform === "darwin"
      ? safeRunCommand(runCommand, "/usr/bin/sw_vers", ["-productVersion"], {
          environment,
          timeoutMs: 5_000
        })
      : Promise.resolve(commandFailure("sw_vers is only available on macOS.")),
    safeRunCommand(runCommand, npm.command, npm.args, { environment, timeoutMs: 5_000 }),
    platform === "darwin"
      ? safeRunCommand(runCommand, "/usr/bin/swift", ["--version"], {
          environment,
          timeoutMs: 10_000
        })
      : Promise.resolve(commandFailure("Swift is only probed on macOS."))
  ]);

  const macosVersion = firstNonemptyLine(macosResult.stdout);
  const npmVersion = firstNonemptyLine(npmResult.stdout);
  const swiftVersion = firstNonemptyLine(swiftResult.stdout);
  const macosCheck: VersionCheck & { minimum: string } = {
    ok: macosResult.ok && macosVersion !== null && versionAtLeast(macosVersion, MINIMUM_MACOS_VERSION),
    version: macosVersion,
    minimum: MINIMUM_MACOS_VERSION,
    ...(!macosResult.ok ? { error: commandError(macosResult) } : {})
  };
  const npmCheck = versionResult(npmResult, npmVersion);
  const swiftMajorMatch = swiftVersion?.match(/\bSwift version\s+(\d+)(?:\.|\b)/iu);
  const swiftMajor = Number.parseInt(swiftMajorMatch?.[1] ?? "0", 10);
  const swiftVersionSupported = Number.isInteger(swiftMajor) && swiftMajor >= MINIMUM_SWIFT_MAJOR;
  const swiftCheck: VersionCheck & { minimum_major: 6 } = {
    ok: swiftResult.ok && swiftVersion !== null && swiftVersionSupported,
    version: swiftVersion,
    minimum_major: MINIMUM_SWIFT_MAJOR,
    ...(!swiftResult.ok
      ? { error: commandError(swiftResult) }
      : !swiftVersionSupported
        ? { error: "Swift 6 or newer is required to build the native host." }
        : {})
  };
  const nodeMajor = Number.parseInt(nodeVersion.split(".")[0] ?? "0", 10);
  const nodeCheck: VersionCheck & { minimum_major: 20 } = {
    ok: Number.isInteger(nodeMajor) && nodeMajor >= 20,
    version: nodeVersion,
    minimum_major: 20,
    ...(!(Number.isInteger(nodeMajor) && nodeMajor >= 20)
      ? { error: "Node.js 20 or newer is required." }
      : {})
  };

  let manifestVersion: string | null = null;
  let manifestName: string | null = null;
  let manifest: Record<string, unknown> | null = null;
  let packageError: string | undefined;
  try {
    const decoded = JSON.parse(await readTextFile(join(packageRoot, "package.json"))) as unknown;
    if (decoded === null || Array.isArray(decoded) || typeof decoded !== "object") {
      throw new Error("package.json does not contain an object.");
    }
    manifest = decoded as Record<string, unknown>;
    manifestVersion = stringValue(manifest, "version");
    manifestName = stringValue(manifest, "name");
  } catch {
    packageError = "The package manifest could not be read and validated safely.";
  }

  const checkoutRoot = await resolveCheckoutRoot(
    overrides.checkoutRoot,
    packageRoot,
    inspectPath
  );
  const packageOK =
    manifestName === PACKAGE_NAME &&
    manifestVersion === SERVER_VERSION &&
    packageError === undefined;

  const expectedOwner = uid;
  const hostApp = await pathCheck(inspectPath, hostAppPath, {
    kind: "directory",
    owner: expectedOwner
  });
  const hostPlist = await pathCheck(inspectPath, hostPlistPath, {
    kind: "file",
    mode: "644",
    owner: expectedOwner
  });

  let plist: Record<string, unknown> | null = null;
  let hostError: string | undefined;
  if (hostPlist.ok && platform === "darwin") {
    const result = await safeRunCommand(
      runCommand,
      "/usr/bin/plutil",
      ["-convert", "json", "-o", "-", hostPlistPath],
      { environment, timeoutMs: 5_000 }
    );
    if (result.ok) {
      try {
        const decoded = JSON.parse(result.stdout) as unknown;
        if (decoded === null || Array.isArray(decoded) || typeof decoded !== "object") {
          throw new Error("Info.plist did not decode to an object.");
        }
        plist = decoded as Record<string, unknown>;
      } catch {
        hostError = "The installed host Info.plist did not contain valid JSON metadata.";
      }
    } else {
      hostError = commandError(result);
    }
  } else if (!hostPlist.ok) {
    hostError = hostPlist.error ?? "The installed host Info.plist is missing or unsafe.";
  }

  const hostExecutableName = stringValue(plist, "CFBundleExecutable") ?? HOST_EXECUTABLE_NAME;
  const hostExecutablePath = join(hostAppPath, "Contents", "MacOS", hostExecutableName);
  const hostExecutable = await pathCheck(inspectPath, hostExecutablePath, {
    kind: "file",
    mode: "755",
    owner: expectedOwner
  });
  const hostBundleID = stringValue(plist, "CFBundleIdentifier");
  const hostShortVersion = stringValue(plist, "CFBundleShortVersionString");
  const hostBundleVersion = stringValue(plist, "CFBundleVersion");
  const hostReleaseVersion = stringValue(plist, "ComputerUseMCPReleaseVersion");
  const hostPackageType = stringValue(plist, "CFBundlePackageType");
  const hostMinimumSystemVersion = stringValue(plist, "LSMinimumSystemVersion");
  const hostLSUIElement = booleanValue(plist, "LSUIElement");
  const hostMetadataOK =
    hostApp.ok &&
    hostPlist.ok &&
    hostExecutable.ok &&
    hostExecutableName === HOST_EXECUTABLE_NAME &&
    hostBundleID === EXPECTED_HOST_BUNDLE_ID &&
    hostReleaseVersion === SERVER_VERSION &&
    hostPackageType === "APPL" &&
    hostMinimumSystemVersion === MINIMUM_MACOS_VERSION &&
    hostLSUIElement === true &&
    hostError === undefined;

  const hostSigning = await inspectSigning(
    runCommand,
    hostAppPath,
    platform,
    environment,
    hostApp.ok,
    EXPECTED_HOST_BUNDLE_ID,
    true
  );
  const hostOK = hostMetadataOK && hostSigning.ok;

  const bridgeExecutable = await pathCheck(inspectPath, bridgePath, {
    kind: "file",
    mode: "755",
    owner: expectedOwner
  });
  const signing = await inspectSigning(
    runCommand,
    bridgePath,
    platform,
    environment,
    bridgeExecutable.ok,
    EXPECTED_BRIDGE_BUNDLE_ID,
    false
  );
  const developmentMarkerCheck = await pathCheck(inspectPath, developmentMarkerPath, {
    kind: "file",
    mode: "600",
    owner: expectedOwner
  });
  let developmentMarkerContentsChecked = false;
  let developmentMarkerContentsValid = false;
  if (developmentMarkerCheck.ok) {
    try {
      const contents = await readDevelopmentMarker(developmentMarkerPath);
      developmentMarkerContentsChecked = true;
      developmentMarkerContentsValid =
        contents === "ComputerUseMCP source development v1\n";
    } catch {
      developmentMarkerContentsValid = false;
    }
  }
  const signingCoherent = await signingCompatibility(
    runCommand,
    bridgePath,
    environment,
    hostSigning,
    signing,
    developmentMarkerCheck.ok && developmentMarkerContentsValid
  );
  const bridgeOK =
    configuredPathWasAbsolute && bridgeExecutable.ok && signing.ok && signingCoherent;

  const [preRuntimeDirectory, preSocket, preToken] = await Promise.all([
    safeInspect(inspectPath, runtimeDirectoryPath),
    safeInspect(inspectPath, socketPath),
    safeInspect(inspectPath, tokenPath)
  ]);
  const preRuntimeSafe =
    pathMissingOrMatches(preRuntimeDirectory, "directory", "700", expectedOwner) &&
    pathMissingOrMatches(preSocket, "socket", "600", expectedOwner) &&
    pathMissingOrMatches(preToken, "file", "600", expectedOwner);

  // The root setup workflow launches onboarding before invoking this command.
  // Reopening here can create a second activation race, so setup only performs
  // a bounded readiness wait for that already-requested launch.
  const hostLaunch: DoctorReport["host_launch"] = { attempted: false, ok: true };

  const maxAttempts =
    mode === "setup" ? clamp(overrides.setupMaxAttempts ?? 12, 1, 30) : 1;
  const retryDelayMs = clamp(overrides.setupRetryDelayMs ?? 500, 0, 5_000);
  const setupTimeBudgetMs = clamp(overrides.setupTimeBudgetMs ?? 15_000, 1_000, 30_000);
  const bridgeFactory =
    overrides.bridgeFactory ??
    ((path: string, diagnosticMode: DiagnosticsMode): NativeBridge =>
      new BridgeProcessClient({
        executablePath: path,
        environment,
        connectTimeoutMs: diagnosticMode === "setup" ? 1_000 : 5_000,
        requestTimeoutMs: diagnosticMode === "setup" ? 2_000 : 10_000,
        stderr: quietWritable()
      }));
  const nativeHandshake =
    bridgeOK && hostOK && preRuntimeSafe
      ? await inspectNative(
          bridgeFactory,
          bridgePath,
          mode,
          maxAttempts,
          retryDelayMs,
          sleep,
          mode === "setup" ? setupTimeBudgetMs : 10_000,
          monotonicNow
        )
      : {
          ok: false,
          attempts: 0,
          max_attempts: maxAttempts,
          protocol: `${NATIVE_PROTOCOL.major}.${NATIVE_PROTOCOL.minor}`,
          status: null,
          error: "Native handshake was skipped because bridge or host launch validation failed."
        };

  const runtimeDirectory = await pathCheck(inspectPath, runtimeDirectoryPath, {
    kind: "directory",
    mode: "700",
    owner: expectedOwner
  });
  const socket = await pathCheck(inspectPath, socketPath, {
    kind: "socket",
    mode: "600",
    owner: expectedOwner
  });
  const tokenCheck = await pathCheck(inspectPath, tokenPath, {
    kind: "file",
    mode: "600",
    owner: expectedOwner
  });
  const token: DoctorReport["runtime"]["token"] = {
    ...tokenCheck,
    read_by_cli: false
  };
  const developmentMarker: DoctorReport["runtime"]["development_marker"] = {
    ...developmentMarkerCheck,
    contents_checked: developmentMarkerContentsChecked,
    contents_valid: developmentMarkerContentsValid,
    read_by_cli: developmentMarkerContentsChecked
  };
  const runtimeOK = socketPathWasAbsolute && runtimeDirectory.ok && socket.ok && token.ok;

  const processes = await inspectHostProcesses(
    runCommand,
    platform,
    uid,
    environment,
    hostExecutablePath
  );
  const sourcePackVerifier =
    checkoutRoot === null
      ? undefined
      : await inspectSourcePack(
          inspectPath,
          checkoutRoot,
          manifest
        );

  const nativePermissions = nativeHandshake.status?.permissions;
  const appControlEnabled = nativeHandshake.status?.app_control_enabled === true;
  const tcc = {
    accessibility: nativePermissions?.accessibility ?? "unknown",
    screen_recording: nativePermissions?.screen_recording ?? "unknown",
    ready:
      nativePermissions?.accessibility === "authorized" &&
      nativePermissions.screen_recording === "authorized"
  };

  const system = {
    platform: { ok: platform === "darwin", value: platform, expected: "darwin" as const },
    architecture: {
      ok: architecture === "arm64" || architecture === "x64",
      value: architecture,
      supported: ["arm64", "x64"] as const
    },
    macos: macosCheck,
    node: nodeCheck,
    npm: npmCheck,
    swift: swiftCheck
  };
  const allRequiredChecks = [
    system.platform.ok,
    system.architecture.ok,
    system.macos.ok,
    system.node.ok,
    system.npm.ok,
    system.swift.ok,
    packageOK,
    hostOK,
    bridgeOK,
    mode !== "setup" || hostLaunch.ok,
    runtimeOK,
    processes.ok,
    nativeHandshake.ok,
    sourcePackVerifier?.ok ?? true
  ];
  const ok = allRequiredChecks.every(Boolean);
  const readyForControl =
    system.platform.ok &&
    system.architecture.ok &&
    system.macos.ok &&
    system.node.ok &&
    packageOK &&
    hostOK &&
    bridgeOK &&
    runtimeOK &&
    processes.ok &&
    nativeHandshake.ok &&
    tcc.ready &&
    appControlEnabled;

  const checks: DoctorReport["checks"] = [
    { name: "platform", ok: system.platform.ok, detail: platform },
    { name: "architecture", ok: system.architecture.ok, detail: architecture },
    { name: "macos", ok: system.macos.ok, detail: macosVersion ?? "unavailable" },
    { name: "node", ok: system.node.ok, detail: nodeVersion },
    { name: "npm", ok: system.npm.ok, detail: npmVersion ?? "unavailable" },
    { name: "swift", ok: system.swift.ok, detail: swiftVersion ?? "unavailable" },
    { name: "package_version", ok: packageOK, detail: manifestVersion ?? "unavailable" },
    { name: "installed_host", ok: hostOK, detail: hostAppPath },
    { name: "signed_bridge", ok: bridgeOK, detail: bridgePath },
    { name: "private_runtime", ok: runtimeOK, detail: runtimeDirectoryPath },
    {
      name: "duplicate_host_processes",
      ok: processes.ok,
      detail: processes.duplicate_detected
        ? "duplicates detected"
        : processes.unexpected_path_detected
          ? "unexpected host path detected"
          : "none detected"
    },
    {
      name: "native_handshake",
      ok: nativeHandshake.ok,
      detail: nativeHandshake.ok ? `protocol ${nativeHandshake.protocol} accepted` : "failed"
    },
    {
      name: "app_control",
      ok: appControlEnabled,
      detail: appControlEnabled ? "enabled" : "disabled"
    },
    ...(sourcePackVerifier === undefined
      ? []
      : [
          {
            name: "source_pack_verifier",
            ok: sourcePackVerifier.ok,
            detail: `${sourcePackVerifier.file_count} package files inspected`
          }
        ])
  ];

  const warnings: string[] = [];
  if (nativeHandshake.ok && !tcc.ready) {
    warnings.push("The native host is reachable, but Screen Recording and Accessibility are not both authorized.");
  }
  if (nativeHandshake.ok && !appControlEnabled) {
    warnings.push("The native host is reachable, but General App Access is turned off.");
  }
  if (mode === "doctor") {
    warnings.push("Doctor is read-only; it did not launch the host, alter TCC, or change runtime permissions.");
  }

  const remediation = buildRemediation({
    system,
    packageOK,
    hostOK,
    bridgeOK,
    hostLaunch,
    runtimeOK,
    processes,
    nativeHandshake,
    tccReady: tcc.ready,
    appControlEnabled,
    ...(sourcePackVerifier === undefined ? {} : { packOK: sourcePackVerifier.ok })
  });

  const report: DoctorReport = {
    schema_version: 1,
    ok,
    ready_for_control: readyForControl,
    mode,
    generated_at: now().toISOString(),
    package: {
      name: PACKAGE_NAME,
      built_version: SERVER_VERSION,
      manifest_version: manifestVersion,
      versions_match: manifestVersion === SERVER_VERSION,
      source_checkout: checkoutRoot !== null,
      ok: packageOK,
      ...(packageError === undefined ? {} : { error: packageError })
    },
    system,
    host: {
      ok: hostOK,
      app: hostApp,
      plist: hostPlist,
      executable: hostExecutable,
      bundle_id: hostBundleID,
      expected_bundle_id: EXPECTED_HOST_BUNDLE_ID,
      short_version: hostShortVersion,
      bundle_version: hostBundleVersion,
      release_version: hostReleaseVersion,
      package_type: hostPackageType,
      minimum_system_version: hostMinimumSystemVersion,
      ls_ui_element: hostLSUIElement,
      signing: hostSigning,
      ...(hostError === undefined ? {} : { error: hostError })
    },
    bridge: {
      ok: bridgeOK,
      path: bridgePath,
      configured_path_was_absolute: configuredPathWasAbsolute,
      executable: bridgeExecutable,
      signing,
      signing_coherent_with_host: signingCoherent
    },
    host_launch: hostLaunch,
    runtime: {
      ok: runtimeOK,
      socket_path_was_absolute: socketPathWasAbsolute,
      directory: runtimeDirectory,
      socket,
      token,
      development_marker: developmentMarker
    },
    processes,
    native_handshake: nativeHandshake,
    tcc,
    ...(sourcePackVerifier === undefined ? {} : { source_pack_verifier: sourcePackVerifier }),
    checks,
    warnings,
    remediation
  };
  return { report, exitCode: ok ? 0 : 1 };
}

async function defaultRunCommand(
  command: string,
  args: readonly string[],
  options: CommandOptions = {}
): Promise<CommandResult> {
  return new Promise(resolveResult => {
    const execOptions = {
      encoding: "utf8" as const,
      maxBuffer: 1024 * 1024,
      timeout: options.timeoutMs ?? 10_000,
      windowsHide: true,
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      ...(options.environment === undefined ? {} : { env: options.environment })
    };
    execFile(command, [...args], execOptions, (error, stdout, stderr) => {
      const exception = error as ExecFileException | null;
      resolveResult({
        ok: exception === null,
        exitCode:
          exception === null
            ? 0
            : typeof exception.code === "number"
              ? exception.code
              : null,
        stdout,
        stderr,
        ...(exception === null ? {} : { error: safeError(exception) })
      });
    });
  });
}

async function defaultInspectPath(path: string): Promise<PathObservation> {
  try {
    const status = await lstat(path);
    const kind: PathKind = status.isSymbolicLink()
      ? "symlink"
      : status.isDirectory()
        ? "directory"
        : status.isFile()
          ? "file"
          : status.isSocket()
            ? "socket"
            : "other";
    return {
      exists: true,
      kind,
      mode: (status.mode & 0o777).toString(8).padStart(3, "0"),
      owner_uid: status.uid
    };
  } catch (error) {
    const code = errorCode(error);
    if (code === "ENOENT" || code === "ENOTDIR") {
      return { exists: false, kind: "missing", mode: null, owner_uid: null };
    }
    return {
      exists: false,
      kind: "missing",
      mode: null,
      owner_uid: null,
      error: "Path metadata inspection failed."
    };
  }
}

async function safeRunCommand(
  runner: CommandRunner,
  command: string,
  args: readonly string[],
  options: CommandOptions
): Promise<CommandResult> {
  try {
    return await runner(command, args, options);
  } catch (error) {
    return commandFailure(safeError(error));
  }
}

function commandFailure(error: string): CommandResult {
  return { ok: false, exitCode: null, stdout: "", stderr: "", error };
}

function commandError(result: CommandResult): string {
  void result;
  return "The diagnostic subprocess failed.";
}

function versionResult(result: CommandResult, version: string | null): VersionCheck {
  return {
    ok: result.ok && version !== null,
    version,
    ...(!result.ok ? { error: commandError(result) } : {})
  };
}

function npmInvocation(
  environment: NodeJS.ProcessEnv,
  nodeExecutable: string,
  args: readonly string[]
): { command: string; args: readonly string[] } {
  const npmExecPath = environment.npm_execpath;
  if (npmExecPath !== undefined && isAbsolute(npmExecPath)) {
    return { command: nodeExecutable, args: [npmExecPath, ...args] };
  }
  return { command: "npm", args };
}

async function pathCheck(
  inspector: PathInspector,
  path: string,
  expected: { kind: PathKind; mode?: string; owner: number | null }
): Promise<PathCheck> {
  let observation: PathObservation;
  try {
    observation = await inspector(path);
  } catch {
    observation = {
      exists: false,
      kind: "missing",
      mode: null,
      owner_uid: null,
      error: "Path metadata inspection failed."
    };
  }
  const modeMatches = expected.mode === undefined || observation.mode === expected.mode;
  const ownerMatches = expected.owner === null || observation.owner_uid === expected.owner;
  return {
    path,
    ...observation,
    expected_kind: expected.kind,
    ...(expected.mode === undefined ? {} : { expected_mode: expected.mode }),
    expected_owner_uid: expected.owner,
    ok: observation.exists && observation.kind === expected.kind && modeMatches && ownerMatches
  };
}

function deriveHostAppPath(bridgePath: string): string | null {
  const helpers = dirname(bridgePath);
  const contents = dirname(helpers);
  const app = dirname(contents);
  if (
    basename(bridgePath) === BRIDGE_EXECUTABLE_NAME &&
    basename(helpers) === "Helpers" &&
    basename(contents) === "Contents" &&
    basename(app).endsWith(".app")
  ) {
    return app;
  }
  return null;
}

async function inspectSigning(
  runCommand: CommandRunner,
  signedPath: string,
  platform: NodeJS.Platform,
  environment: NodeJS.ProcessEnv,
  pathOK: boolean,
  expectedIdentifier: string,
  deep: boolean
): Promise<SigningReport> {
  if (platform !== "darwin" || !pathOK) {
    return {
      ok: false,
      verified: false,
      identifier: null,
      expected_identifier: expectedIdentifier,
      team_identifier: null,
      signature_kind: "unknown",
      authorities: [],
      designated_requirement: null,
      error: "Code-signing inspection requires the expected installed macOS path."
    };
  }
  const [verification, display] = await Promise.all([
    safeRunCommand(
      runCommand,
      "/usr/bin/codesign",
      ["--verify", ...(deep ? ["--deep"] : []), "--strict", "--verbose=2", signedPath],
      { environment, timeoutMs: 10_000 }
    ),
    safeRunCommand(
      runCommand,
      "/usr/bin/codesign",
      ["--display", "--verbose=4", "--requirements", "-", signedPath],
      { environment, timeoutMs: 10_000 }
    )
  ]);
  const summaryText = `${display.stdout}\n${display.stderr}`;
  const identifier = captureLine(summaryText, "Identifier");
  const team = captureLine(summaryText, "TeamIdentifier");
  const signature = captureLine(summaryText, "Signature");
  const authorities = [...summaryText.matchAll(/^Authority=(.+)$/gmu)].map(match => match[1] ?? "");
  const requirementMatch = summaryText.match(/designated => (.+)$/mu);
  const designatedRequirement = requirementMatch?.[1]?.trim() ?? null;
  const signatureKind =
    signature?.toLowerCase() === "adhoc" || /\badhoc\b/iu.test(summaryText)
      ? "adhoc"
      : authorities.length > 0 || (team !== null && team !== "not set")
        ? "certificate"
        : "unknown";
  const teamIdentifier = team === null || team === "not set" ? null : team;
  const ok = verification.ok && display.ok && identifier === expectedIdentifier;
  return {
    ok,
    verified: verification.ok,
    identifier,
    expected_identifier: expectedIdentifier,
    team_identifier: teamIdentifier,
    signature_kind: signatureKind,
    authorities,
    designated_requirement: designatedRequirement,
    ...(!ok
      ? {
          error: !verification.ok
            ? commandError(verification)
            : !display.ok
              ? commandError(display)
              : "The signing identifier does not match the expected identity."
        }
      : {})
  };
}

async function signingCompatibility(
  runCommand: CommandRunner,
  bridgePath: string,
  environment: NodeJS.ProcessEnv,
  host: SigningReport,
  bridge: SigningReport,
  developmentMarkerValid: boolean
): Promise<boolean> {
  if (!host.ok || !bridge.ok) return false;
  if (host.signature_kind === "adhoc" || bridge.signature_kind === "adhoc") {
    return (
      host.signature_kind === "adhoc" &&
      bridge.signature_kind === "adhoc" &&
      host.team_identifier === null &&
      bridge.team_identifier === null &&
      developmentMarkerValid
    );
  }
  if (
    host.signature_kind !== "certificate" ||
    bridge.signature_kind !== "certificate" ||
    host.team_identifier === null ||
    bridge.team_identifier !== host.team_identifier ||
    !/^[A-Z0-9]{10}$/u.test(host.team_identifier)
  ) {
    return false;
  }
  const exactRequirement =
    `identifier "${EXPECTED_BRIDGE_BUNDLE_ID}" and anchor apple generic and ` +
    `certificate leaf[subject.OU] = "${host.team_identifier}"`;
  const verification = await safeRunCommand(
    runCommand,
    "/usr/bin/codesign",
    ["--verify", "--strict", `-R=${exactRequirement}`, bridgePath],
    { environment, timeoutMs: 10_000 }
  );
  return verification.ok;
}

async function defaultReadDevelopmentMarker(
  path: string,
  expectedUID: number | null
): Promise<string> {
  if (expectedUID === null) {
    throw new Error("A user identity is required to inspect the development marker.");
  }
  const handle = await open(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    const before = await handle.stat();
    if (
      !before.isFile() ||
      before.uid !== expectedUID ||
      (before.mode & 0o777) !== 0o600 ||
      before.size < 0 ||
      before.size > 128
    ) {
      throw new Error("The development marker has unsafe metadata.");
    }
    const buffer = Buffer.alloc(before.size);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    const after = await handle.stat();
    if (bytesRead !== before.size || after.size !== before.size) {
      throw new Error("The development marker changed during inspection.");
    }
    return buffer.toString("utf8");
  } finally {
    await handle.close();
  }
}

function pathMissingOrMatches(
  observation: PathObservation,
  kind: PathKind,
  mode: string,
  owner: number | null
): boolean {
  if (!observation.exists) return observation.error === undefined;
  return (
    observation.kind === kind &&
    observation.mode === mode &&
    (owner === null || observation.owner_uid === owner)
  );
}

async function inspectNative(
  bridgeFactory: NonNullable<DiagnosticsDependencies["bridgeFactory"]>,
  bridgePath: string,
  mode: DiagnosticsMode,
  maxAttempts: number,
  retryDelayMs: number,
  sleep: NonNullable<DiagnosticsDependencies["sleep"]>,
  timeBudgetMs: number,
  monotonicNow: NonNullable<DiagnosticsDependencies["monotonicNow"]>
): Promise<NativeHandshakeReport> {
  const deadline = monotonicNow() + timeBudgetMs;
  let attempts = 0;
  let lastErrorCode = "BRIDGE_UNAVAILABLE";
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const remainingBeforeAttempt = deadline - monotonicNow();
    if (remainingBeforeAttempt < 100) break;
    attempts = attempt;
    let bridge: NativeBridge | undefined;
    try {
      bridge = bridgeFactory(bridgePath, mode);
      const raw = fromNativeResult(
        await bridge.call("status", {}, {
          timeoutMs: Math.min(mode === "setup" ? 2_000 : 10_000, remainingBeforeAttempt)
        })
      );
      const parsed = NativeStatusSchema.safeParse(raw);
      if (!parsed.success) {
        throw new ComputerUseError(
          "BRIDGE_PROTOCOL_ERROR",
          "The native status response has an incompatible shape."
        );
      }
      const { active_grants: activeGrants, ...safeStatus } = parsed.data;
      const status: NativeStatusSummary = {
        ...safeStatus,
        active_grant_count: activeGrants.length
      };
      return {
        ok: status.native_version === SERVER_VERSION,
        attempts: attempt,
        max_attempts: maxAttempts,
        protocol: `${NATIVE_PROTOCOL.major}.${NATIVE_PROTOCOL.minor}`,
        status,
        ...(status.native_version === SERVER_VERSION
          ? {}
          : { error: "The native host and MCP package release versions do not match." })
      };
    } catch (error) {
      lastErrorCode = diagnosticErrorCode(error);
      if (!isTransientDiagnosticError(error)) {
        return {
          ok: false,
          attempts,
          max_attempts: maxAttempts,
          protocol: `${NATIVE_PROTOCOL.major}.${NATIVE_PROTOCOL.minor}`,
          status: null,
          error_code: lastErrorCode,
          error: "The native diagnostic failed with a non-retryable compatibility or validation error."
        };
      }
    } finally {
      if (bridge !== undefined) {
        try {
          await bridge.close();
        } catch {
          // Closing a failed diagnostic bridge must not hide its actual probe result.
        }
      }
    }
    if (attempt < maxAttempts) {
      const remaining = deadline - monotonicNow();
      if (remaining <= 0) break;
      await sleep(Math.min(retryDelayMs, remaining));
    }
  }
  return {
    ok: false,
    attempts,
    max_attempts: maxAttempts,
    protocol: `${NATIVE_PROTOCOL.major}.${NATIVE_PROTOCOL.minor}`,
    status: null,
    error_code: lastErrorCode,
    error: "The native host did not become ready within the bounded setup/doctor window."
  };
}

async function inspectHostProcesses(
  runCommand: CommandRunner,
  platform: NodeJS.Platform,
  uid: number | null,
  environment: NodeJS.ProcessEnv,
  expectedExecutablePath: string
): Promise<DoctorReport["processes"]> {
  if (platform !== "darwin" || uid === null) {
    return {
      ok: false,
      inspected: false,
      duplicate_detected: false,
      unexpected_path_detected: false,
      host_processes: [],
      error: "Host process inspection requires a macOS user identity."
    };
  }
  const result = await safeRunCommand(
    runCommand,
    "/bin/ps",
    ["-axo", "pid=,uid=,comm="],
    { environment, timeoutMs: 5_000 }
  );
  if (!result.ok) {
    return {
      ok: false,
      inspected: false,
      duplicate_detected: false,
      unexpected_path_detected: false,
      host_processes: [],
      error: commandError(result)
    };
  }
  const hostProcesses: Array<{ pid: number; executable_path: string }> = [];
  for (const line of result.stdout.split(/\r?\n/u)) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+?)\s*$/u);
    if (match === null) continue;
    const pid = Number.parseInt(match[1] ?? "", 10);
    const owner = Number.parseInt(match[2] ?? "", 10);
    const executablePath = match[3] ?? "";
    if (owner === uid && basename(executablePath) === HOST_EXECUTABLE_NAME) {
      hostProcesses.push({ pid, executable_path: executablePath });
    }
  }
  hostProcesses.sort((left, right) => left.pid - right.pid);
  const duplicate = hostProcesses.length > 1;
  const unexpectedPath = hostProcesses.some(
    process => normalize(process.executable_path) !== normalize(expectedExecutablePath)
  );
  return {
    ok: !duplicate && !unexpectedPath,
    inspected: true,
    duplicate_detected: duplicate,
    unexpected_path_detected: unexpectedPath,
    host_processes: hostProcesses,
    ...(duplicate || unexpectedPath
      ? {
          error: duplicate
            ? "Multiple same-user ComputerUseMCPHost processes are running."
            : "A same-name host is running from an unexpected executable path."
        }
      : {})
  };
}

async function resolveCheckoutRoot(
  configured: string | null | undefined,
  packageRoot: string,
  inspectPath: PathInspector
): Promise<string | null> {
  if (configured === null) return null;
  const candidate = normalize(configured ?? resolve(packageRoot, "../.."));
  if (normalize(packageRoot) !== normalize(join(candidate, "packages", "mcp"))) {
    return null;
  }
  const [git, rootManifest, verifier] = await Promise.all([
    safeInspect(inspectPath, join(candidate, ".git")),
    safeInspect(inspectPath, join(candidate, "package.json")),
    safeInspect(inspectPath, join(candidate, "scripts", "verify-pack.sh"))
  ]);
  const gitOK = git.exists && (git.kind === "directory" || git.kind === "file");
  if (gitOK && rootManifest.exists && rootManifest.kind === "file" && verifier.exists && verifier.kind === "file") {
    return candidate;
  }
  return null;
}

async function safeInspect(inspector: PathInspector, path: string): Promise<PathObservation> {
  try {
    return await inspector(path);
  } catch {
    return {
      exists: false,
      kind: "missing",
      mode: null,
      owner_uid: null,
      error: "Path metadata inspection failed."
    };
  }
}

async function inspectSourcePack(
  inspectPath: PathInspector,
  checkoutRoot: string,
  manifest: Record<string, unknown> | null
): Promise<NonNullable<DoctorReport["source_pack_verifier"]>> {
  const requiredFiles = [
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
  const packageRoot = join(checkoutRoot, "packages", "mcp");
  const observations = await Promise.all(
    requiredFiles.map(async path => ({ path, observation: await safeInspect(inspectPath, join(packageRoot, path)) }))
  );
  const missing = observations
    .filter(({ observation }) => !observation.exists || observation.kind !== "file")
    .map(({ path }) => path);
  const configuredFiles = manifest?.["files"];
  const allowedFiles = ["dist", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"];
  const forbidden = Array.isArray(configuredFiles)
    ? configuredFiles.filter(
        (entry): entry is string => typeof entry === "string" && !allowedFiles.includes(entry)
      )
    : ["package.json#files"];
  const lifecycleScripts = [
    "preinstall",
    "install",
    "postinstall",
    "prepack",
    "prepare",
    "prepublish",
    "prepublishOnly"
  ];
  const scripts = recordValue(manifest, "scripts");
  const forbiddenLifecycle = lifecycleScripts.filter(name => typeof scripts?.[name] === "string");
  const indexPath = observations.find(entry => entry.path === "dist/index.js")?.observation;
  const indexExecutable =
    indexPath !== undefined &&
    indexPath.exists &&
    indexPath.kind === "file" &&
    indexPath.mode !== null &&
    (Number.parseInt(indexPath.mode, 8) & 0o111) !== 0;
  const configuredFilesOK =
    Array.isArray(configuredFiles) &&
    configuredFiles.length === allowedFiles.length &&
    allowedFiles.every(entry => configuredFiles.includes(entry));
  const manifestOK =
    stringValue(manifest, "name") === PACKAGE_NAME &&
    stringValue(manifest, "version") === SERVER_VERSION &&
    stringValue(manifest, "license") === "Apache-2.0" &&
    configuredFilesOK;
  const ok =
    missing.length === 0 &&
    forbidden.length === 0 &&
    forbiddenLifecycle.length === 0 &&
    indexExecutable &&
    manifestOK;
  const errors = [
    ...(forbiddenLifecycle.length === 0
      ? []
      : [`Forbidden lifecycle scripts: ${forbiddenLifecycle.join(", ")}`]),
    ...(!indexExecutable ? ["The packed CLI entry point is not executable."] : []),
    ...(!manifestOK ? ["The package manifest identity does not match the release contract."] : [])
  ];
  return {
    ok,
    checkout_root: checkoutRoot,
    method: "read_only_manifest_and_built_files",
    file_count: observations.length,
    missing_required_files: missing,
    forbidden_entries: forbidden,
    ...(errors.length === 0 ? {} : { error: errors.join(" ") })
  };
}

function buildRemediation(input: {
  system: DoctorReport["system"];
  packageOK: boolean;
  hostOK: boolean;
  bridgeOK: boolean;
  hostLaunch: DoctorReport["host_launch"];
  runtimeOK: boolean;
  processes: DoctorReport["processes"];
  nativeHandshake: NativeHandshakeReport;
  tccReady: boolean;
  appControlEnabled: boolean;
  packOK?: boolean;
}): string[] {
  const remediation = new Set<string>();
  if (!input.system.platform.ok || !input.system.macos.ok) {
    remediation.add("Use macOS 14.4 or newer in an unlocked user session.");
  }
  if (!input.system.node.ok || !input.system.npm.ok) {
    remediation.add("Install Node.js 20 or newer with a working npm command.");
  }
  if (!input.system.swift.ok) {
    remediation.add("Install Xcode 16 or matching Command Line Tools with Swift 6 or newer.");
  }
  if (!input.packageOK || input.packOK === false) {
    remediation.add("Rebuild from the locked source checkout and run npm run pack:verify.");
  }
  if (!input.hostOK || !input.bridgeOK) {
    remediation.add("Run npm run setup to reinstall the expected per-user host and signed bridge.");
  }
  if (!input.hostLaunch.ok || !input.nativeHandshake.ok) {
    remediation.add("Open ComputerUseMCPHost.app, wait for it to finish starting, then rerun doctor.");
  }
  if (!input.runtimeOK) {
    remediation.add("Quit stale host copies and inspect the reported runtime owner, type, and mode; do not loosen permissions.");
  }
  if (input.processes.duplicate_detected || input.processes.unexpected_path_detected) {
    remediation.add("Quit every stale ComputerUseMCPHost copy, then launch only the reported installed app.");
  }
  if (input.nativeHandshake.ok && !input.tccReady) {
    remediation.add("Use the host status menu and System Settings to resolve the reported native permission state, then relaunch if macOS requests that.");
  }
  if (input.nativeHandshake.ok && !input.appControlEnabled) {
    remediation.add("Open Computer Control Settings from the host status menu and turn on General App Access when you are ready to accept access requests.");
  }
  return [...remediation];
}

function recordValue(
  record: Record<string, unknown> | null,
  key: string
): Record<string, unknown> | null {
  const value = record?.[key];
  return value !== null && !Array.isArray(value) && typeof value === "object"
    ? (value as Record<string, unknown>)
    : null;
}

function stringValue(record: Record<string, unknown> | null, key: string): string | null {
  const value = record?.[key];
  return typeof value === "string" ? value : null;
}

function booleanValue(record: Record<string, unknown> | null, key: string): boolean | null {
  const value = record?.[key];
  return typeof value === "boolean" ? value : null;
}

function firstNonemptyLine(value: string): string | null {
  return value
    .split(/\r?\n/u)
    .map(line => line.trim())
    .find(line => line.length > 0) ?? null;
}

function captureLine(value: string, key: string): string | null {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return value.match(new RegExp(`^${escaped}=(.+)$`, "mu"))?.[1]?.trim() ?? null;
}

function versionAtLeast(actual: string, minimum: string): boolean {
  const actualParts = actual.split(".").map(part => Number.parseInt(part, 10));
  const minimumParts = minimum.split(".").map(part => Number.parseInt(part, 10));
  if (actualParts.some(part => !Number.isInteger(part))) return false;
  const length = Math.max(actualParts.length, minimumParts.length);
  for (let index = 0; index < length; index += 1) {
    const left = actualParts[index] ?? 0;
    const right = minimumParts[index] ?? 0;
    if (left > right) return true;
    if (left < right) return false;
  }
  return true;
}

function safeError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.replace(/[\r\n\t]+/gu, " ").trim().slice(0, 2_000) || "Unknown diagnostic failure.";
}

function diagnosticErrorCode(error: unknown): string {
  if (error instanceof ComputerUseError) return error.code;
  if (error instanceof Error && error.name === "AbortError") return "CANCELLED";
  return "DIAGNOSTIC_FAILURE";
}

function isTransientDiagnosticError(error: unknown): boolean {
  return (
    (error instanceof ComputerUseError &&
      (error.code === "BRIDGE_UNAVAILABLE" || error.code === "ACTION_TIMEOUT")) ||
    (error instanceof Error && error.name === "AbortError")
  );
}

function errorCode(error: unknown): string | null {
  if (error === null || typeof error !== "object") return null;
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" ? code : null;
}

function quietWritable(): NodeJS.WritableStream {
  return new Writable({
    write(_chunk, _encoding, callback): void {
      callback();
    }
  });
}

function defaultSleep(milliseconds: number): Promise<void> {
  return new Promise(resolveSleep => setTimeout(resolveSleep, milliseconds));
}

function clamp(value: number, minimum: number, maximum: number): number {
  if (!Number.isFinite(value)) return minimum;
  return Math.min(maximum, Math.max(minimum, Math.trunc(value)));
}
