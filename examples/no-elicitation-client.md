# Grant flow without MCP elicitation

A minimal or legacy MCP client does not need `elicitation/create` support. The
native target picker is the approval boundary, and the resulting grant
authorizes actions within the selected capability set until it is revoked.

## 1. Request access

Call `computer_request_access` with a human-readable reason and the smallest
capability set needed. The user selects the exact target and chooses **Allow
Once** or **Always Allow App** in native UI. The result contains an opaque
`grant_id`.

## 2. Capture current state

Call `computer_get_state` with the grant. It returns a `frame_id`, image
coordinate transform, screenshot when requested, and bounded Accessibility
state. Select an element or coordinate only from that current frame.

## 3. Act within the grant

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
    "intent": "Submit the synthetic fixture form after reviewing it",
    "timeout_ms": 10000
  }
}
```

No `approval_request_id` or retry exchange is required. The host revalidates the
connection, grant, target identity, capability, frame, semantic target, focus
destination, and protected-surface policy before dispatch.

Handle `STALE_FRAME` by capturing state again. Treat `ACCESS_DENIED`,
`action_blocked`, revocation, and target-recreation errors as final until the
user makes a new access decision. Do not switch targets or widen capabilities
without a new `computer_request_access` call.

Use the target rail's **Stop** control or `computer_release_access` when the task
is complete. Disconnect also revokes every grant owned by that MCP connection.
