# Computer Use MCP

Computer Use MCP is a local, window-scoped computer-control server for macOS. It
exposes a conservative Model Context Protocol (MCP) tool surface that can be
launched by Codex, Claude Desktop, Claude Code, Cursor, MCP Inspector, or any
other stdio-capable MCP host.

> **Alpha status:** `v0.1.0-alpha.1` is the prepared source-only
> security-preview release candidate; it has not been tagged or published yet.
> It does not include a prebuilt, signed, or notarized macOS application. Review
> the code, build it locally, and use it only with non-sensitive data while the
> interfaces and safety controls are still changing.

## What makes it different

- Access is granted to one selected window (or, only when explicitly requested,
  one display), not implicitly to the whole desktop.
- A persisted **General app access** switch defaults to off. When off, the native
  host fails closed for operations that could inspect or control another app;
  status and Stop remain available.
- Every observation and action is checked against a short-lived local capability
  and the current window owner, process, and identity.
- A non-activating control rail appears on the left edge of the controlled
  window. It shows the requester identity that the native bridge derived from
  the nearest verifiable GUI process ancestor (or **Unidentified local MCP
  harness**), mode, and target; **Stop** immediately revokes active access.
- Screen Recording and Accessibility are requested separately and remain under
  macOS System Settings. The application cannot silently grant them to itself.
- Remembering an approved signed app never chooses a target. Every new grant
  still requires an exact window choice; display grants are always session-only.
- The native host uses public ScreenCaptureKit, Accessibility, and Core Graphics
  APIs. The optional targeted private-driver path is disabled by default,
  version-gated, and fails closed when unavailable.
- Risk classification and one-shot challenge binding live in the native host.
  Modern clients collect the user's decision through MCP elicitation; clients
  without elicitation use the native approval panel.
- Screenshots and typed text are not written to the audit log. See
  [Privacy](PRIVACY.md) for the exact defaults.

## Architecture

```text
Codex / Claude / Cursor / Inspector / another MCP host
                         |
                    MCP over stdio
                         |
          @jmeguilos/computer-use-mcp
                         |
             private child-process pipes
                         |
        signed ComputerUseMCPBridge helper
                         |
       authenticated local Unix-domain socket
                         |
              Computer Use MCP Host.app
            /              |              \
 ScreenCaptureKit   Accessibility/CGEvent   left-edge indicator
```

The Node.js process is a protocol adapter. It spawns the locally signed native
bridge over private child pipes; only that bridge may authenticate to the host's
socket in the release architecture. Before forwarding the first hello, the
bridge independently verifies the socket peer's kernel UID/PID/audit token and
pins it to the sibling host executable path and signing requirement; release
mode also requires the expected host bundle and Developer ID team. The native
host owns macOS TCC permissions, window selection, grants, capture, input, the
visible indicator, and the audit trail. The boundary is intentional: an MCP
process never receives ambient authority merely because a client launched it.
Bridge signing proves which code connected to the socket; it does not prove
which same-user harness invoked that bridge. The bridge ignores caller-supplied
names and instance IDs and derives requester attribution from the nearest
verifiable GUI process ancestor, binding its PID, bundle ID, signing identity,
and process generation. That attribution describes observed process ancestry;
it is not caller authorization. Exact native target consent and risk-based
action approval remain mandatory for every caller.

Read [Architecture](docs/ARCHITECTURE.md), [Protocol](docs/PROTOCOL.md), and the
[Threat model](docs/THREAT_MODEL.md) before extending the control surface.

## Requirements

- macOS 14.4 or later
- Node.js 20 or later and npm
- Xcode 16 or later, or matching Command Line Tools with Swift 6
- A local interactive login session (not SSH-only, a launch daemon, or a locked
  screen)

## Build the alpha from source

```sh
git clone https://github.com/jmeguilos/computer-use-mcp.git
cd computer-use-mcp
npm ci
npm run build
npm run swift:build
npm run setup
npm run doctor
```

`setup` builds both native executables, installs an explicitly development-only
ad-hoc-signed app in the current user's `Applications` directory, and launches
the original first-run settings window. It never edits the TCC database or uses
`sudo`. `doctor`
is read-only: it reports versions,
paths, host reachability, socket permissions, TCC state, and packaging problems
without changing permissions.

For the original first-run window and its controls, see
[Onboarding and settings](docs/ONBOARDING.md). For the complete source-build and
permission flow, see [Setup](docs/SETUP.md).
Contributors should also read [Local development](docs/LOCAL_DEVELOPMENT.md).

## Connect an MCP client

Build first, then use the absolute path to the generated stdio entry point:

```text
/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
```

For example, Codex can register the source build with:

```sh
codex mcp add computer-use-mcp -- \
  node /ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
```

Current, copyable configurations are in [Client compatibility](docs/COMPATIBILITY.md)
and [`examples/`](examples/). Those instructions were last checked against each
vendor's official documentation on 2026-08-29.

## Safety model in one minute

1. The client starts the stdio adapter.
2. The adapter spawns the native bridge over private pipes. The host verifies the
   bridge's peer UID/PID and socket audit token before issuing a connection
   capability over a mode-`0600` Unix-domain socket inside a mode-`0700` runtime
   directory. Before sending hello, the bridge verifies the host peer's kernel
   identity and pins it to the sibling host executable path and signing
   requirement. Developer ID-signed releases additionally enforce the expected
   bundle and team identity in both directions. Those checks reject unsigned
   release replacements, but any same-user program can launch the genuine bridge
   and request a connection. This alpha's ad-hoc-signed source-development mode
   also permits same-user direct peers. In both modes, the caller remains
   untrusted until the native host grants an exact target and, when required, one
   exact action. On the normal bridge path, caller-provided names and instance IDs
   are discarded; the bridge attributes the request to the nearest verifiable GUI
   process ancestor, or reports **Unidentified local MCP harness** when it cannot
   derive one.
3. On first run, the native settings window keeps General app access off until
   the user enables it and reports Screen Recording and Accessibility as two
   separate macOS decisions. Turning the switch on grants no target authority.
4. `computer_request_access` opens native UI. The user chooses an exact window
   and capabilities, then allows that target, optionally remembers its verified
   app identity, or denies the request. A remembered app still requires an exact
   window choice. A separately requested display is session-only and can never
   be remembered.
5. The host binds a grant to the connection and selected target identity. It
   revalidates that identity before every capture and action.
6. The indicator stays visible while a grant is active. Stop, window closure,
   target replacement, session lock, timeout, or client disconnect revokes it.

System Screen Recording permission is necessarily broader than one window. The
project's per-window boundary is therefore an application-enforced capability,
not a claim that macOS TCC itself is window-scoped. See the
[Threat model](docs/THREAT_MODEL.md#permission-boundary).

Use **Stop** on the target indicator, or **Emergency Stop** in the host's
menu-bar item, before taking over manually. V1 does not monitor global user input
and does not support control while the session is locked; lock or sleep revokes
active authority.

## Tools

The alpha exposes exactly 15 tools covering discovery/status, grant lifecycle,
state capture, pointer, keyboard, scrolling, semantic Accessibility actions, and
clipboard writes. The authoritative list and request/response rules live in
[Protocol](docs/PROTOCOL.md). Tools fail closed when a grant is absent, stale, or
does not contain the required capability.

## Release policy

`v0.1.0-alpha.1` is prepared for source-only GitHub distribution with checksums,
an SBOM, and an inspectable npm pack artifact, but no public release has been
created yet. Nothing is published to the npm registry. The Developer ID,
hardened-runtime, and notarization workflow is disabled by default and requires
an explicitly protected release environment. See [Releasing](docs/RELEASING.md).

## Contributing and security

Contributions must satisfy the [clean-room provenance policy](docs/PROVENANCE.md)
and pass the automated provenance gate. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
before opening a pull request.

Do not report vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md)
instead.

## License

Copyright 2026 jmeguilos and contributors. Licensed under the
[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) and
[third-party notices](THIRD_PARTY_NOTICES.md).

Apple, Anthropic, Claude, Cursor, OpenAI, and Codex are trademarks of their
respective owners. This independent project is not endorsed by or affiliated
with those companies.
