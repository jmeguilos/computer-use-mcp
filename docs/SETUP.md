# Setup

`v0.1.0-alpha.1` is a source-only release. There is no downloadable app, Homebrew
cask, npm-registry install, one-click extension, or notarized package. The steps
below build and register a local development copy.

## 1. Check prerequisites

Computer Use MCP requires macOS 14.4+, Node.js 20+, npm, and Swift 6 from full
Xcode 16 or later. Standalone Command Line Tools may compile the native package,
but they do not reliably execute its Swift Testing suite.

```sh
sw_vers -productVersion
node --version
npm --version
swift --version
xcode-select -p
```

If `xcode-select -p` fails or prints `/Library/Developer/CommandLineTools`,
install full Xcode, accept its license, and select its developer directory with
`xcode-select`. The native test gate requires `xcrun --find xctest` to succeed
and rejects a zero-test run.

## 2. Build from the locked source tree

```sh
git clone https://github.com/jmeguilos/computer-use-mcp.git
cd computer-use-mcp
npm ci
npm run provenance:scan
npm run build
npm run swift:test
npm run swift:build
```

Use `npm ci`, not `npm install`, for a reviewed release checkout: it refuses a
manifest/lockfile mismatch instead of silently rewriting dependency resolution.

For a local universal native build on Apple Silicon with the required x86_64
toolchain support:

```sh
npm run swift:universal
```

This is still an unsigned local build and is never a substitute for a signed,
notarized release.

## 3. Prepare the host

```sh
npm run setup
```

`setup` builds the stdio package and native bridge
(`com.jmeguilos.computer-use-mcp.bridge`), creates the local
`ComputerUseMCPHost.app` wrapper with bundle identifier
`com.jmeguilos.computer-use-mcp.host`, installs it in the per-user development
location, applies an explicit development-only ad-hoc signature, and launches
its permission onboarding. The installed host is started with a narrowly scoped
development verifier that still enforces same-user kernel peer credentials and
audit tokens. An ad-hoc signature is not a Developer ID or notarization claim.
Setup does not modify the TCC
database, use `sudo`, publish a package, or enable unattended startup.

Keep one app path and bundle identity while testing. Moving, replacing, or
re-signing a development app can cause macOS to treat it as a different privacy
principal and ask again.

## 4. Grant macOS permissions

The host checks two permissions independently:

1. **Screen & System Audio Recording** (called Screen Recording on some macOS
   revisions) permits window capture.
2. **Accessibility** permits semantic inspection/actions and synthetic input.

Open **System Settings → Privacy & Security**, select each category, and enable
**Computer Use MCP Host** only if you intend to use that capability. macOS may
require quitting and reopening the host after Screen Recording changes. The host
continues in a degraded state when only one permission is present and reports
which tools remain unavailable.

Input Monitoring is not a v1 requirement. Computer Use MCP never asks you to
disable SIP, run a `tccutil` database modification, grant Full Disk Access, or
install a kernel/system extension.

TCC permission is app-wide. Per-window access begins only when an MCP client
calls `computer_request_access` and you approve the native target picker.

## 5. Run the doctor

```sh
npm run doctor
```

`doctor` is read-only and should report:

- macOS, architecture, Node, npm, and Swift versions;
- source and built package versions;
- installed host path, bundle ID, and code-signing state;
- Screen Recording and Accessibility status separately;
- runtime directory, socket, and token ownership/modes;
- native bridge protocol/signing compatibility and a status handshake;
- stale duplicate host processes or an unreachable socket; and
- whether the npm package passes its source-only pack check.

The command must not auto-grant TCC access or loosen file permissions. Before
sharing output, review it for usernames, filesystem paths, app names, and window
titles.

## 6. Configure a client

Use the absolute built entry point:

```text
/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
```

Copy the relevant configuration from [Client compatibility](COMPATIBILITY.md) or
[`examples/`](../examples/). Relative paths are unreliable because desktop MCP
clients do not necessarily inherit your shell's working directory or `PATH`.

Start with harness-level approval enabled for every action tool. The native host
will still enforce its own grants and risk prompts.

## 7. First safe test

Run the synthetic fixture rather than a real application:

```sh
bash apps/macos-host/Scripts/run-fixture.sh
```

It opens windows titled **Computer Use MCP Fixture — Primary** and
**Computer Use MCP Fixture — Inspector**. In your MCP client:

1. call `computer_get_status`;
2. call `computer_list_apps` and locate the fixture;
3. request `observe` access with a clear reason;
4. approve only the Primary fixture window;
5. call `computer_get_state` and verify the left-edge observing indicator;
6. request interaction only when ready, perform a harmless fixture action, and
   verify the acting state; and
7. press **Stop**, then confirm a new state/action call is denied.

Do not begin with a password manager, terminal with secrets, production admin
console, messaging app, or a window containing customer data.

## Troubleshooting

### Client reports connection closed

- Run the exact `node /absolute/path/.../dist/index.js` command in Terminal.
- Confirm build output exists and Node is version 20 or later.
- Ensure nothing writes logs to stdout; diagnostics must use stderr.
- Run `npm run doctor` and look for a bridge-version or socket error.

### Host is unavailable

- Quit stale host copies, launch the installed development app once, and rerun
  `doctor`.
- Confirm the runtime directory belongs to the current user and is mode `0700`.
- Remove a stale socket only after every host/client process has stopped; `setup`
  should then recreate it safely.
- If `COMPUTER_USE_MCP_SOCKET_PATH` is set, ensure the host and adapter use the
  same private path.

### Screen is blank or capture is denied

- Recheck Screen Recording in System Settings.
- Fully quit and relaunch the native host after changing the permission.
- Protected or DRM-backed content may remain unavailable by design.
- Lock-screen capture is denied by design.

### Actions fail but capture works

- Recheck Accessibility separately.
- Observe again after a resize, move, display-scale change, or app relaunch.
- Prefer an Accessibility element selector over a point.
- Bring the target to the foreground; public macOS event injection cannot
  guarantee background coordinate input.

### The window has no indicator

Treat the missing indicator as no valid grant. Release access, run `doctor`, and
request it again. Do not work around this check.

## Uninstall a source build

1. press Stop and quit all MCP clients using the server;
2. quit Computer Use MCP Host;
3. remove the development app created by `setup`;
4. move `~/Library/Application Support/ComputerUseMCP` to Trash if you also want
   to remove settings and redacted audit metadata; and
5. revoke Screen Recording and Accessibility for the host in System Settings.

Deleting project files alone does not revoke macOS permissions.
