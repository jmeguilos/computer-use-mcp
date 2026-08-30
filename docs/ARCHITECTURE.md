# Architecture

## Design goals

Computer Use MCP is designed around six invariants:

1. macOS privacy permissions belong to one visible, auditable native app;
2. a persisted native master switch defaults off and fails closed before any
   client can inspect or control another app;
3. a client receives no computer-control authority until the user approves a
   target and capabilities in native UI;
4. normal access is scoped to one window and revalidated before every operation;
5. the user can always see and stop active control without returning to the MCP
   client; and
6. client compatibility does not weaken the native security boundary.

The implementation deliberately separates protocol adaptation from privileged
macOS work.

## Components

### MCP stdio adapter

`packages/mcp` is the process launched by an MCP client. It:

- negotiates MCP and publishes strict JSON Schemas;
- validates and normalizes every tool argument;
- maps public tool calls to the versioned native bridge;
- converts native images to MCP image content or short-lived resources;
- binds one-shot approval request IDs to canonical action arguments;
- maps native failures to stable, structured tool errors; and
- writes protocol output only to stdout and diagnostics only to stderr.

It does not hold Accessibility or Screen Recording permission, enumerate hidden
windows independently, synthesize events itself, or connect directly to the host
socket in the release architecture.

### Signed native bridge helper

The adapter spawns `ComputerUseMCPBridge` as a child and communicates over
private inherited pipes. The helper performs strict framing and is the only
release-eligible peer for the host's Unix-domain socket. Its bundle identifier is
`com.jmeguilos.computer-use-mcp.bridge`. It presents a bootstrap socket audit
token, and the host verifies kernel UID/PID plus the helper's designated
code-signing requirement and expected team identity before issuing a short-lived
connection capability. Before it forwards the first hello, the bridge performs
the reciprocal check: it reads the server's kernel UID/PID/audit token, pins the
peer to the sibling host executable path and signing requirement, and in release
mode requires the expected host bundle and the same Developer ID team.

That signing check applies to a Developer ID-signed release. The source alpha's
explicit development mode uses an ad-hoc signature and instead enforces the
kernel-reported UID/PID, nonempty audit token, bootstrap token, authenticated
hello, and connection capability. It does not enforce a designated signing
requirement, so another process running as the same user is inside the
development-mode trust boundary. Setup records that explicit authorization in a
mode-`0600`, same-user marker so macOS permission-related Quit & Reopen launches
remain usable; a release-signed host always ignores that marker. Use source mode
only with non-sensitive data.

In a signed release, the socket check proves that the direct peer is the genuine
bridge rather than an unsigned replacement. It does not authenticate the bridge's
parent: any same-user harness can execute the genuine helper and ask it to open a
connection. The bridge discards caller-supplied names and instance IDs. Instead,
it walks its process ancestry to the nearest GUI application for which it can
bind a PID, bundle ID, designated-signing identity, and process generation; if
none is available, it presents **Unidentified local MCP harness**. This verified
process-ancestry attribution supports truthful display and self-exclusion, but it
does not authorize the ancestor or prevent another same-user process from
invoking the genuine bridge. When no verified GUI ancestor is available, the host
keeps status and inventory readable but marks every application non-grantable and
denies window and display requests before presenting native approval UI. Verified
callers remain untrusted until native UI grants an exact target, and the host's
connection-, grant-, frame-, and one-shot action checks remain authoritative.

### Native macOS host

`apps/macos-host` builds `ComputerUseMCPHost`, whose application wrapper is
`ComputerUseMCPHost.app` with bundle identifier
`com.jmeguilos.computer-use-mcp.host`. It is an AppKit accessory application
(`LSUIElement`) rather than a dock-oriented document app.

The native host owns:

- ScreenCaptureKit capture and display/window inventory;
- Accessibility inspection and semantic actions;
- Core Graphics event synthesis where a semantic action is unavailable;
- Screen Recording and Accessibility status and onboarding;
- durable fail-closed host preferences and the first-run/settings window;
- target selection, grants, revocation, expiry, and risk approval;
- the left-edge indicator and emergency Stop control;
- protected-target policy and session-lock handling; and
- privacy-preserving local audit metadata.

Only public macOS frameworks are in the normal driver path. The optional
targeted private-driver path is disabled by default and version-gated. It is not
silently selected; when the current operating-system build is unsupported or no
validated alpha implementation exists, the host reports it unavailable and
fails closed.

### Host socket

The signed helper and host communicate using newline-delimited JSON over a
per-user Unix-domain socket:

```text
~/Library/Application Support/ComputerUseMCP/runtime/host.sock
```

The containing directory is mode `0700`, and the socket and bootstrap audit token
are mode `0600`. `COMPUTER_USE_MCP_SOCKET_PATH` may override the path for isolated
development and tests. The host authenticates the incoming bridge, while the
bridge authenticates the connected host before sending hello. Both sides inspect
kernel peer credentials; each side enforces its expected bundle/team signing
identity in release mode, and the bridge additionally pins the server to the
sibling host path and signing requirement. The host then requires a
token-authenticated hello, negotiates protocol and capabilities, and assigns a
connection ID and capability. Explicit source-development mode deliberately
omits the host-side bridge-signing check described above, while the bridge still
pins the source host peer. A connection capability alone is not a target grant.

The bridge is intentionally not TCP, HTTP, WebSocket, XPC with an anonymous
service name, or a fixed unauthenticated port. It has no network listener. A
direct Node-to-socket transport may exist only behind an explicit local
development/test switch; it fails closed by default and makes a build ineligible
for release.

### Indicator and approval UI

An original 8-point-wide rail tracks the left edge of the granted window. A
compact, non-activating panel shows requester attribution, mode, and target and
exposes the Stop control. On the normal bridge path the identity is derived from
the nearest verifiable GUI process ancestor (or shown as **Unidentified local MCP
harness**); explicit source-development direct-peer attribution is untrusted.
The displayed attribution is not an authorization decision.

The indicator is excluded from capture where public APIs permit. It never
pretends to be a macOS consent dialog, and it does not steal keyboard focus from
the target merely to update status. If the indicator cannot be placed
truthfully—for example, because the target disappeared—the grant fails closed.

The indicator is also the v1 human-takeover boundary. The user presses the
target's Stop control to revoke one grant or uses Emergency Stop in the menu-bar
item to revoke all grants. The host does not monitor global user input, so local
clicks or keystrokes do not by themselves atomically pause a client.

### First-run and settings UI

The native host is a menu-bar accessory app. When its stored onboarding revision
is older than the current revision, it presents one original AppKit Computer
Control window. Selecting Done attempts to durably record that revision;
completion exists only after the protected write succeeds. Closing without Done
or a failed write leaves it incomplete so setup appears again on the next
launch. Later launches remain menu-bar-only after completion until the user
chooses **Computer Control Settings…**.

The window owns no target authority. It presents:

- a persisted **General app access** master switch, off by default;
- separate Screen Recording and Accessibility rows with refresh actions;
- a source-development trust-boundary warning when applicable; and
- requester-bound always-allowed signed-app policies with per-policy Remove and
  confirmed Remove All.

Turning General app access off persists the off state before Emergency Stop
revokes active grants. A read or persistence error must leave the policy off.
Turning it on only permits native access requests; it does not modify TCC, select
a target, or create ambient app authority.

## Permission and grant layers

There are four separate layers:

| Layer | Grants | Scope | Controlled by |
| --- | --- | --- | --- |
| macOS TCC | Screen Recording, Accessibility | Application identity; system-defined | System Settings / MDM |
| Native master policy | Permission to accept computer-use requests | This host, persisted; off by default | General app access switch |
| Bridge connection | Named native protocol capabilities | One authenticated local client connection | Native host handshake |
| Target grant | Observe, interact, clipboard write | Selected window; explicit display exception | Native approval UI or exact requester-bound saved policy |

Passing one layer never bypasses another. In particular, macOS Screen Recording
permission is system-wide for the app, while Computer Use MCP's window boundary
is enforced by its own master policy, grant, and target-validation code. The
two user-facing macOS rows remain separate; the Accessibility row includes AX
trust and public event-posting permission, not Input Monitoring.

## Grant lifecycle

1. A client starts the MCP adapter and calls `computer_request_access` with an
   app selector, reason, and requested capabilities.
2. The native host verifies that General app access and required TCC state are
   present, resolves safe Accessibility-bound candidates, and either applies an
   exact matching saved policy to one unique window or presents its target
   picker. App launch remains a separate approval.
3. A granted window is bound to its opaque window identifier, PID, bundle
   identifier, and signing identity when available. The connection receives
   an opaque `grant_id`, never an ambient host handle. Internal connection and
   native window IDs do not cross the public MCP authority boundary.
4. Before each observation or action, the host checks connection lifetime,
   grant capability, target identity, current window existence, protected-target
   policy, lock state, and request deadline.
5. The grant ends on explicit release, Stop, target closure or replacement,
   client disconnect, connection idle timeout, host exit, session lock, or
   policy revocation.

`always_allow_app` remembers a native approval policy keyed to both the verified
requesting harness identity and the signed target application, plus the approved
capability set. It does not preserve a bearer token or an unbounded live session.
Every request still receives fresh connection-bound authority and is subject to
the master switch, current TCC, protected-target policy, fresh Accessibility
binding, target lock, and mandatory indicator. A later explicit request may skip
the app prompt only when exactly one safe window matches and the requested
capabilities are a subset of the saved policy. Multiple matches, changed signing
identity, a different requester, or capability escalation opens the native
picker. Legacy consent records are prompt-only and are never upgraded silently.
Removing an always-allowed app affects future requests, not an active grant.

A display grant follows the same master-policy and TCC checks, but is approved
separately for one display, is session-only, has no Accessibility tree, and is
never persisted.

## Observation path

`computer_get_state` asks the host for one coherent frame. The host captures the
approved target, emits deterministic top-left image coordinates plus exact
image-to-global and global-to-image affine transforms, and optionally serializes
a bounded Accessibility tree. Results include a `frame_id`.

Visual point selectors and Accessibility element selectors must cite the frame
that produced them. A window move, resize, scale change, replacement, or expired
frame produces `STALE_FRAME`; the client must observe again instead of guessing.
Accessibility diffs may reference a prior frame, but the host returns a full
reset when a safe diff is not possible.

Images are either returned inline or placed in a memory-only
`computer-use://frame/<id>` resource for 60 seconds. They are not persisted by
the project.

## Action path

Semantic Accessibility actions are preferred because they can target a specific
element without relying on global coordinates. Point actions are transformed
from frame-relative pixels to current global points only after the target and
frame are revalidated. State results expose the exact image-to-global affine
matrix and its global-to-image inverse so clients can reason about the same
coordinate space without inventing a transform. Core Graphics input may require
foreground focus and is never described as background-safe.

An explicitly requested targeted private driver must pass both its enablement
and operating-system version gates. The alpha has no universally supported
private implementation; an unavailable path returns an error rather than
downgrading target validation or silently choosing another private mechanism.

Every action includes a short human-readable `intent`. The native risk engine
classifies the normalized action:

- low risk may complete under the existing grant;
- medium or high risk creates one native challenge and uses either modern MCP v2
  `input_required` elicitation or the native-panel fallback;
- blocked actions are denied regardless of client request.

Modern MCP v2 clients can receive an `input_required` result containing an
`elicitation/create` request. An accepted boolean and integrity-protected
`requestState` let the authenticated adapter resolve that exact native challenge
once. For a legacy or no-elicitation client, the host opens its native panel and
returns `approval_required`; the client retries the exact call with a short-lived
one-shot `approval_request_id`. Changed text, coordinates, modifiers, intent,
frame, or grant fail with `APPROVAL_MISMATCH`. A challenge uses one route, never
both prompts.

The native fallback panel shows a bounded, escaped text/value preview only when
the frame-bound Accessibility snapshot identifies one non-secure destination.
Secure or ambiguous destinations show payload length and format with the preview
hidden. Neither form is copied into audit metadata.

Secure text controls are write-only. Their title, label, value, and actions stay
redacted from state, and selection remains denied. A direct
`AXSecureTextField` may accept `computer_set_value` only after the action's
high-risk one-shot approval has been consumed. `AXProtectedContent`, a generic
element below a secure ancestor, or an ambiguous ancestry chain remains denied
even with an approval token. An ancestry chain is accepted only when it reaches
the concrete `AXUIElement` for the granted application's PID; role text alone is
not treated as proof of the root.

## Concurrency and cancellation

Requests carry deadlines. The native bridge supports cancellation by request ID,
and Stop has priority over queued work. Actions on one target are serialized to
avoid interleaved pointer and keyboard state. Read-only status calls may proceed
concurrently, but a capture cannot extend a revoked grant.

## Repository map

| Path | Responsibility |
| --- | --- |
| `packages/protocol` | Shared bridge constants, schemas, canonical JSON, identifiers |
| `packages/mcp` | stdio MCP server, tool schemas, helper child-process client, frame resources |
| `apps/macos-host` | Signed bridge helper plus Swift native host, macOS permissions, capture/input, approval UI, indicator |
| `tests` | Cross-component and packaging tests |
| `evals` | Synthetic behavior and safety evaluations |
| `examples` | Client configuration examples |
| `scripts` | Reproducible build, pack, SBOM, and provenance checks |

## Non-goals for the alpha

- remote or multi-user computer control;
- a hidden daemon with unattended control;
- bypassing TCC, secure-input safeguards, protected content, lock screen, or
  application security boundaries;
- locked use, lock-screen control, or unattended authentication;
- promising background coordinate input on macOS;
- OCR, keystroke capture, clipboard read, or persistent screenshot history;
- private framework compatibility or pixel-identical replication of another
  product's UI.
