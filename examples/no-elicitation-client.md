# Approval flow without MCP elicitation

A minimal or legacy MCP client does not need `elicitation/create` support. The
native host presents the fallback approval panel and the tool returns a
structured, complete result.

This example assumes the client has already received:

- `grant_id` from `computer_request_access`; and
- a current `frame_id` plus element IDs/coordinates from
  `computer_get_state` for that grant.

## First call

Call an action without `approval_request_id`:

```json
{
  "name": "computer_click",
  "arguments": {
    "grant_id": "grant_opaque_example_01",
    "frame_id": "frame_opaque_example_09",
    "selector": {
      "kind": "element",
      "element_id": "element_opaque_submit"
    },
    "mouse_button": "left",
    "click_count": 1,
    "intent": "Submit the synthetic fixture form after the user reviewed it",
    "timeout_ms": 10000
  }
}
```

A low-risk action may complete immediately. A sensitive action returns:

```json
{
  "ok": true,
  "status": "approval_required",
  "approval_request_id": "approval_opaque_example_17",
  "message": "Approve this exact action in Computer Use MCP Host",
  "expires_at": "2026-08-30T04:00:00Z"
}
```

Tell the user to review the target, action, and intent in the native panel. Do
not fabricate approval, poll by issuing changed actions, or switch targets.

## Exact retry

After the user approves in the native panel, retry the same tool with byte-for-
byte equivalent normalized arguments and add only `approval_request_id`:

```json
{
  "name": "computer_click",
  "arguments": {
    "grant_id": "grant_opaque_example_01",
    "frame_id": "frame_opaque_example_09",
    "selector": {
      "kind": "element",
      "element_id": "element_opaque_submit"
    },
    "mouse_button": "left",
    "click_count": 1,
    "intent": "Submit the synthetic fixture form after the user reviewed it",
    "approval_request_id": "approval_opaque_example_17",
    "timeout_ms": 10000
  }
}
```

The ID is short-lived, one-shot, and bound to connection, grant, frame, tool,
and canonical arguments. A changed retry produces `APPROVAL_MISMATCH`; an expired
or reused ID produces `APPROVAL_EXPIRED` or `APPROVAL_USED`. Obtain a new frame
before starting over after expiry or stale state.

If the user denies the native prompt, treat the denial as final. Do not retry the
same operation under a different tool or simulate it through global key events.

## Modern MCP v2 clients

Clients negotiating the 2026 MCP protocol can instead receive a tool result with
`resultType: "input_required"` and an embedded `elicitation/create` request. The
client collects the boolean decision and retries through the standard
input-required mechanism with the opaque, integrity-protected `requestState`.
The SDK can auto-fulfill that round. The server selects either that route or the
native fallback for one challenge; it never opens both prompts.
