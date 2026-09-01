# Setup

`v0.1.0-alpha.1` is the source-only release candidate and has not been published.
There is no downloadable app, Homebrew cask, npm-registry install, one-click
extension, or notarized package. The steps below build and register a local
development copy.

The native first-run and settings experience is described separately in
[Onboarding and settings](ONBOARDING.md).

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
its original AppKit first-run window. The installed host is started with a
narrowly scoped development verifier that still enforces same-user kernel peer
credentials and audit tokens. The bridge independently checks the connected
server's kernel identity and pins it to the installed sibling host path and
signing requirement before sending hello. An ad-hoc signature is not a Developer
ID or notarization claim.
Setup does not modify the TCC
database, use `sudo`, publish a package, or enable unattended startup.

Keep one app path and bundle identity while testing. Moving, replacing, or
re-signing a development app can cause macOS to treat it as a different privacy
principal and ask again.

The source-development verifier cannot enforce the Developer ID bridge-signing
boundary, so another process running as the same user may also connect directly.
A future signed release can reject unsigned direct peers, but any same-user
program can still launch the genuine bridge; signing does not authenticate its
parent harness. Native exact-target and action consent remains mandatory. Use
only non-sensitive test windows with this source alpha. The installed host shows
the source-mode warning during first-run and in settings.

## 4. Complete first-run access setup

The settings window begins with **General app access** off. Leave it off while
reviewing the two macOS permission rows. Off is a native fail-closed control
policy, not a TCC setting: operations that could inspect or change another app
are denied, while status and Stop remain available.

The host checks two permissions independently:

1. **Screen & System Audio Recording** (called Screen Recording on some macOS
   revisions) permits window capture.
2. **Accessibility** permits semantic inspection/actions and synthetic input.

Open **System Settings → Privacy & Security**, select each category, and enable
**Jules Marvine Computer Use** only if you intend to use that capability. macOS may
require quitting and reopening the host after Screen Recording changes. The host
continues in a degraded state when only one permission is present and reports
which tools remain unavailable.

Return to the host and select **Check Again** after each change. Accessibility
status includes semantic AX access and permission to post public Core Graphics
events; it is still presented as one user-facing Accessibility row. Input
Monitoring and event listening are neither shown nor requested.

Turn **General app access** on only when both rows show the state you expect. When
on, it permits connected clients to present a native target request, but grants
no window, display, or action authority by itself. Turning the switch off later
persists the off state and immediately Emergency-Stops active grants. A settings
or preference persistence failure fails closed.

Input Monitoring is not a v1 requirement. Computer Use MCP never asks you to
disable SIP, run a `tccutil` database modification, grant Full Disk Access, or
install a kernel/system extension.

TCC permission is app-wide. Per-window access begins only when an MCP client
calls `computer_request_access`. A first or unmatched request requires the
native exact-target picker. **Always Allow App** can satisfy a later explicit
request only for the same verified requester, signed target, and approved
capability subset when exactly one safe Accessibility-bound window matches.
Ambiguity, requester or target-signature changes, and capability escalation
prompt again. Application launch remains a separate approval; display approval
is session-only and never remembered. Legacy consent records remain prompt-only
until the user makes a new explicit Always Allow decision.

On the normal bridge path, caller-supplied names and instance IDs are discarded.
The bridge attributes each connection to the nearest verifiable GUI process
ancestor, binding its PID, bundle ID, signing identity, and process generation,
or reports **Unidentified local MCP harness** when no such ancestor is available.
Any same-user process can still invoke the genuine bridge, so this attribution
does not replace exact native target or action consent.

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

The command must not auto-grant TCC access, open onboarding, modify the master
switch or onboarding revision, or loosen file permissions. Before sharing
output, review it for usernames, filesystem paths, app names, and window titles.

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

If you select **Always Allow App**, end the grant and request access again from
the same verified client. With only the Primary window matching, the host should
create a fresh exact-window grant without another app prompt and still show the
control rail. Launch the Inspector window and repeat without a unique hint; the
native exact-window picker must return. Confirm the policy appears in **Computer
Control Settings… → Always-allowed apps**, then test its per-row Remove control.
A request from another client, a capability escalation, or a changed app signing
identity must prompt again. A display request must offer session-only approval
and disappear when stopped or disconnected.

Stop is the v1 human-takeover boundary. The host does not monitor global keyboard
or pointer input, so manually clicking or typing is not an atomic pause. Press
the target rail's Stop first, or use the menu-bar Emergency Stop for all grants.

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
- Source-development builds use an ad-hoc signature whose code identity changes
  when the executable changes. If `doctor` reports a permission denied while the
  installed host's toggle appears on, remove that stale host row, add the exact
  installed `~/Applications/ComputerUseMCPHost.app` again, enable it, and relaunch
  the host. This does not apply to a stable Developer ID-signed distribution.
- Protected or DRM-backed content may remain unavailable by design.
- Lock-screen capture is denied by design.

### Actions fail but capture works

- Confirm **Computer Control Settings… → General app access** is on. If it is off,
  leave it off until you intentionally want clients to request control.
- Recheck Accessibility separately.
- Observe again after a resize, move, display-scale change, or app relaunch.
- Prefer an Accessibility element selector over a point.
- Bring the target to the foreground; public macOS event injection cannot
  guarantee background coordinate input.
- Do not try to force the optional targeted private driver. It is disabled by
  default, version-gated, and fails closed when unsupported or unavailable.

### The window has no indicator

Treat the missing indicator as no valid grant. Release access, run `doctor`, and
request it again. Do not work around this check.

### Control stops when the Mac locks or sleeps

This is expected. Locked use is excluded from v1, and lock, sleep, screen sleep,
or session resignation revokes active grants. Unlock the session, review the
settings state, and request a fresh exact target.

## Uninstall a source build

1. press Stop and quit all MCP clients using the server;
2. quit Jules Marvine Computer Use;
3. remove the development app created by `setup`;
4. move `~/Library/Application Support/ComputerUseMCP` to Trash if you also want
   to remove settings and redacted audit metadata; and
5. revoke Screen Recording and Accessibility for the host in System Settings.

Deleting project files alone does not revoke macOS permissions.
