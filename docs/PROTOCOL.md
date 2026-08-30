# Protocol

Computer Use MCP has three local protocol layers:

1. standard MCP over stdio between a client and the Node.js adapter; and
2. private child-process framing between the adapter and the signed
   `ComputerUseMCPBridge` helper; and
3. a versioned, authenticated JSON-Lines bridge over a Unix-domain socket between
   that signed helper and the native macOS host.

This separation is a security boundary. MCP compatibility never grants macOS
authority by itself.

## MCP transport

The command `computer-use-mcp` is a stdio server. stdin and stdout are reserved
for MCP JSON-RPC. Human diagnostics go to stderr. The alpha does not expose SSE,
Streamable HTTP, TCP, or a remote endpoint.

Inputs are strict objects: unknown fields, invalid enum members, over-limit
strings, non-finite coordinates, and malformed IDs are rejected before reaching
the native host. Completed tool results include a boolean `ok` discriminator;
the modern approval route instead uses the standard MCP `input_required` result.

## Capabilities and target handles

Public grants use three user-facing capabilities:

| Capability | Allows | Does not allow |
| --- | --- | --- |
| `observe` | capture approved target; read bounded Accessibility state | pointer, keyboard, clipboard writes |
| `interact` | semantic actions and bounded pointer/keyboard events in target | clipboard write without its capability; another target |
| `clipboard_write` | explicit write/paste requested by a tool | reading prior clipboard contents |

After access is granted, the client receives one opaque `grant_id`. Internal
connection and native window identifiers are deliberately not public MCP
authority. Every observation and action carries:

```json
{
  "grant_id": "opaque-grant-id"
}
```

## Tools

The alpha exposes exactly 15 MCP tools: five discovery/lifecycle tools, one
observation tool, and nine action tools.

### Discovery and lifecycle

| Tool | Important input | Result |
| --- | --- | --- |
| `computer_get_status` | `{}` | versions, TCC state, readiness, active grants, pending approvals |
| `computer_list_displays` | `include_mirrored` (default `true`) | grantable display metadata; no screenshot |
| `computer_list_apps` | `running_only` (default `true`) | app identity, PID when running, window count, grantability |
| `computer_request_access` | discriminated `target`, `reason`, `capabilities`, `timeout_ms` | granted `grant_id` or denied/pending/permission-required status |
| `computer_release_access` | `grant_id`, `timeout_ms` | released or not-found status |

An access target is either a selected window or an explicit display. A window's
app selector is a discriminated object using `bundle_id`, `name`, or absolute
`path`:

```json
{
  "target": {
    "kind": "window",
    "app": { "kind": "bundle_id", "value": "com.example.Example" },
    "window_hint": "Synthetic form",
    "launch_if_needed": false
  },
  "reason": "Fill the synthetic test form the user requested",
  "capabilities": ["observe", "interact"]
}
```

`launch_if_needed` is accepted only with a bundle-ID selector. A path selector
may match an already-running app at that exact canonical bundle path, but the
alpha never launches an executable named by a path. Name selectors likewise
select running applications only.

For a display, the target is
`{"kind":"display","display_id":"opaque-display-id"}` using an ID from
`computer_list_displays`. The host presents native UI for target and persistence
choice. A client cannot name an arbitrary native window ID and skip selection.
Full-display grants are always session-only.

A successful access result has the shape:

```json
{
  "ok": true,
  "status": "granted",
  "grant_id": "opaque-grant-id",
  "target": {
    "kind": "window",
    "app": {
      "bundle_id": "com.example.Example",
      "name": "Example",
      "pid": 4321
    },
    "title": "Synthetic form",
    "bounds_points": { "x": 80, "y": 60, "width": 900, "height": 700 },
    "display_id": "opaque-display-id"
  },
  "capabilities": ["observe", "interact"],
  "idle_expires_at": "2026-08-30T04:15:00Z",
  "session_only": false
}
```

Target metadata is descriptive and redacted/bounded where necessary; only
`grant_id` is accepted as the public authority handle. `computer_release_access`
takes that ID and a bounded timeout.

### Observation

`computer_get_state` accepts:

- `grant_id`;
- optional `since_frame_id` for an Accessibility diff;
- `screenshot`: `inline`, `resource`, or `none`;
- `max_width_px` from 320 through 4096;
- `include_accessibility` and a bounded `max_accessibility_chars`; and
- `timeout_ms` from 100 through 30,000.

A completed state includes `grant_id`, target metadata, `frame_id`, capture time,
an exact invertible coordinate transform, optional bounded structured
Accessibility state, and optional PNG metadata. Accessibility state is either a
parent-first `full` node list or a deterministic `diff` bound to the supplied
`since_frame_id`. A safe diff that cannot be produced is replaced by a full
snapshot carrying `reset_reason`; display grants return an explicit empty full
tree because Accessibility authority remains window-scoped. Secure nodes are
marked and never include their value. Inline mode returns image content in the
MCP result.
Resource mode returns a
`computer-use://frame/<frame-id>` URI with a 60-second expiry. Resource bytes are
memory-only and capped at 5 MiB of decoded PNG data; clients must not assume a
frame remains available.

Coordinates use top-left image pixels. `coordinate_space` contains `width_px`,
`height_px`, `global_bounds_points`, and exact affine transforms
`image_to_global` and `global_to_image`. Each transform is the object
`{a,b,c,d,tx,ty}`. Both are returned publicly and validated as inverses. The host
recomputes and rechecks the current transform before an action; a client-provided
coordinate never overrides it.

### Actions

| Tool | Selector/arguments |
| --- | --- |
| `computer_click` | `selector`, `mouse_button`, `click_count` |
| `computer_drag` | point `from`, point `to`, `duration_ms` |
| `computer_scroll` | optional `selector`, `direction`, `amount`, `unit` |
| `computer_press_key` | `key`, `modifiers` |
| `computer_type_text` | `text`, `interval_ms` |
| `computer_paste` | `text`, optional `format: "text"`; requires `clipboard_write` |
| `computer_set_value` | element `selector`, `value` |
| `computer_select_text` | element `selector`, `text`, optional `prefix`/`suffix`, `selection_type` |
| `computer_perform_secondary_action` | element `selector`, named `action` |

Every action also requires top-level `grant_id`, the current `frame_id`, a
non-empty `intent`, an optional `approval_request_id` used only for a native
fallback retry, and a bounded `timeout_ms`.

Selectors are frame-bound:

```json
{ "kind": "element", "element_id": "opaque-element-id" }
```

```json
{ "kind": "point", "x": 412, "y": 238 }
```

Element selectors are preferred. A point is valid only in the exact coordinate
space of the top-level `frame_id`. The host returns `STALE_FRAME` after a
material target or transform change; the client must call `computer_get_state`
again.

A completed action returns `grant_id`, current target metadata, `action_id`, and
completion time. `approval_required` returns only its one-shot
`approval_request_id`, message, and expiry; it does not create a second grant.

### Conservative tool annotations

Status, inventory, and state observation are annotated as read-only. Access
request/release and input tools are non-read-only; input tools are also marked
potentially destructive and open-world. Client approval settings are useful
defense in depth, but native grants remain mandatory even if a harness
auto-approves MCP tools.

## Approval: modern elicitation and native fallback

Risk classification and the one-shot challenge live in the native host. One
challenge uses exactly one of two user-experience routes.

For a client negotiating the modern 2026 MCP protocol and input-required
support, the server returns an `input_required` result containing one
`elicitation/create` request. The client obtains an accepted boolean and retries
with the byte-exact, integrity-protected opaque `requestState`. The authenticated
adapter validates that state, resolves the matching native challenge once, and
executes only the canonically identical action. A rejected elicitation is final.
This route treats the MCP client as the user-facing approval mediator; clients
that are not trusted to render and relay that decision should set
`COMPUTER_USE_MCP_APPROVAL_MODE=native` in the server environment to force the
native fallback instead.

Legacy clients and clients without elicitation use the native-panel fallback.
The first call returns a complete tool result:

```json
{
  "ok": true,
  "status": "approval_required",
  "approval_request_id": "opaque-one-shot-request-id",
  "message": "Approve this exact action in Computer Use MCP Host",
  "expires_at": "2026-08-30T04:00:00Z"
}
```

The client should wait for the user to decide in the native panel, then retry the
same tool with identical normalized arguments plus `approval_request_id`. The ID
is connection-, grant-, frame-, tool-, and argument-bound, expires quickly, and
is consumed once. A changed retry returns `APPROVAL_MISMATCH`; reuse returns
`APPROVAL_USED`. Denial is final.

Clients that cannot automatically retry can simply issue the same tool call in a
new model step. They do not need a special MCP capability. The server never opens
both an MCP elicitation and native panel for the same challenge. See the
[no-elicitation example](../examples/no-elicitation-client.md).

## Success, denial, and errors

An operation that reached policy returns `ok: true` even when the user denies it;
the `status` communicates `denied`, `pending`, `permission_required`,
`approval_required`, or `completed`. A validation, transport, or execution
failure returns:

```json
{
  "ok": false,
  "error": {
    "code": "STALE_FRAME",
    "message": "The target changed after the referenced frame.",
    "retryable": true,
    "remediation": "Call computer_get_state and choose a selector from the new frame."
  }
}
```

Stable alpha error codes include:

`PERMISSION_REQUIRED`, `ACCESS_DENIED`, `APP_NOT_RUNNING`,
`WINDOW_NOT_GRANTED`, `WINDOW_CLOSED`, `STALE_FRAME`, `ELEMENT_NOT_FOUND`,
`ELEMENT_NOT_ACTIONABLE`, `FOCUS_FAILED`, `SCREEN_CAPTURE_FAILED`,
`ACTION_TIMEOUT`, `CANCELLED`, `APPROVAL_EXPIRED`, `APPROVAL_USED`,
`APPROVAL_MISMATCH`, `BUSY`, `UNSUPPORTED`, `BRIDGE_UNAVAILABLE`,
`BRIDGE_PROTOCOL_ERROR`, and `INTERNAL_ERROR`.

Clients should retry only when `retryable` is true and should follow
`remediation`. They must not turn a denial into a less-scoped or unvalidated
fallback action.

## Native bridge

The native bridge protocol version is `1.0` and uses one JSON object per line.
The Node adapter first spawns `ComputerUseMCPBridge` over private child pipes. A
host-socket connection begins with a token-authenticated hello containing peer
metadata, protocol version, and requested native capabilities. The host verifies
the kernel-reported helper UID/PID and bootstrap socket audit token; rejects
unsupported capabilities; and returns a connection ID and connection
capability. Developer ID-signed releases also require the helper's designated
signing requirement and expected team identity. Explicit source-development
mode is ad-hoc signed and does not perform that signing check.

Subsequent helper-to-host requests contain at least:

- protocol version;
- unique request ID;
- connection ID and connection capability token;
- method;
- typed params; and
- absolute deadline.

The method set is `status`, `listDisplays`, `listApps`, `requestAccess`,
`releaseAccess`, `getState`, `action`, `approveRisk`, `cancel`, and `stop`.
`cancel` names an outstanding request; `stop` revokes before acknowledging.

Responses echo the request ID and contain either a typed result or a structured
error. Unknown methods, extra fields, duplicate IDs, oversized lines, expired
deadlines, and incompatible versions are rejected. The bridge never accepts a
shell command, arbitrary Accessibility object pointer, global coordinate without
a frame, or raw native window handle from the MCP client.

## Compatibility and versioning

MCP protocol negotiation follows the installed official SDK. The native bridge
uses semantic major/minor compatibility: a major mismatch is fatal; a host may
accept a peer at an equal or older minor version only when every requested
capability is supported.

Tool additions may be backward-compatible. Removing/renaming a tool, changing a
field's meaning, weakening a default, or changing target/approval semantics
requires a documented compatibility decision and normally a version increment.
The exact TypeScript schemas remain authoritative when prose and generated JSON
Schema differ.
