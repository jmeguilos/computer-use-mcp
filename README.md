# Computer Use MCP

Computer Use MCP is a local, window-scoped computer-control server for macOS. It
exposes a conservative Model Context Protocol (MCP) tool surface that can be
launched by Codex, Claude Desktop, Claude Code, Cursor, MCP Inspector, or any
other stdio-capable MCP host.

> **Alpha status:** `v0.1.0-alpha.1` is a source-only security-preview release.
> It does not include a prebuilt, signed, or notarized macOS application. Review
> the code, build it locally, and use it only with non-sensitive data while the
> interfaces and safety controls are still changing.

## What makes it different

- Access is granted to one selected window (or, only when explicitly requested,
  one display), not implicitly to the whole desktop.
- Every observation and action is checked against a short-lived local capability
  and the current window owner, process, and identity.
- A non-activating control rail appears on the left edge of the controlled
  window. It identifies the harness, mode, and target; **Stop** immediately
  revokes active access.
- Screen Recording and Accessibility are requested separately and remain under
  macOS System Settings. The application cannot silently grant them to itself.
- The native host uses public ScreenCaptureKit, Accessibility, and Core Graphics
  APIs. Private automation APIs are neither required nor enabled.
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
socket in the release architecture. The native host owns macOS TCC permissions,
window selection, grants, capture, input, the visible indicator, and the audit
trail. The boundary is intentional: an MCP process never receives ambient
authority merely because a client launched it.

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
permission onboarding. It never edits the TCC database or uses `sudo`. `doctor`
is read-only: it reports versions,
paths, host reachability, socket permissions, TCC state, and packaging problems
without changing permissions.

For the complete source-build and permission flow, see [Setup](docs/SETUP.md).
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
   directory. Developer ID-signed releases additionally enforce the bridge's
   designated signing requirement and team identity. This alpha's ad-hoc-signed
   source-development mode cannot enforce that signing boundary; same-user
   malware is therefore outside its trust boundary.
3. `computer_request_access` opens native UI. The user chooses a window and
   capabilities, then selects allow once, session-only, always allow this app, or
   deny.
4. The host binds a grant to the connection and selected target identity. It
   revalidates that identity before every capture and action.
5. The indicator stays visible while a grant is active. Stop, window closure,
   target replacement, session lock, timeout, or client disconnect revokes it.

System Screen Recording permission is necessarily broader than one window. The
project's per-window boundary is therefore an application-enforced capability,
not a claim that macOS TCC itself is window-scoped. See the
[Threat model](docs/THREAT_MODEL.md#permission-boundary).

## Tools

The alpha exposes exactly 15 tools covering discovery/status, grant lifecycle,
state capture, pointer, keyboard, scrolling, semantic Accessibility actions, and
clipboard writes. The authoritative list and request/response rules live in
[Protocol](docs/PROTOCOL.md). Tools fail closed when a grant is absent, stale, or
does not contain the required capability.

## Release policy

`v0.1.0-alpha.1` is distributed from GitHub as source plus checksums, an SBOM,
and an inspectable npm pack artifact. Nothing is published to the npm registry.
The Developer ID, hardened-runtime, and notarization workflow is disabled by
default and requires an explicitly protected release environment. See
[Releasing](docs/RELEASING.md).

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
