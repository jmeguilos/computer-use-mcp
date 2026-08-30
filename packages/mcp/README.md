# Computer Use MCP

`@jmeguilos/computer-use-mcp` is a local, stdio-only MCP server for observing
and controlling explicitly granted macOS windows or displays. It is designed
for MCP clients such as Claude Desktop, Claude Code, Codex, and Cursor.

The Node.js server launches the signed `ComputerUseMCPBridge` helper over
private stdin/stdout pipes. The helper authenticates to `ComputerUseMCPHost`
and carries the operating-system identity checks; the MCP server never reads a
host secret, never opens a network listener, and never writes diagnostics to
its MCP stdout stream.

## Requirements

- macOS 14.4 or newer
- Node.js 20 or newer
- `ComputerUseMCPHost.app` installed in `~/Applications`
- Accessibility and Screen Recording permissions granted to the native host

## Build and run

This alpha is source-only and is not published to the npm registry. Build it
from a trusted checkout:

```sh
cd /absolute/path/to/computer-use-mcp
npm ci
npm run setup
```

The root setup command installs and opens the per-user native host, then the
MCP `setup` command waits up to a bounded readiness deadline. The `setup`
subcommand does not launch a second host copy.

The helper defaults to
`~/Applications/ComputerUseMCPHost.app/Contents/Helpers/ComputerUseMCPBridge`.
Source builds may select an explicit signed helper with
`COMPUTER_USE_MCP_BRIDGE_PATH`.

Check the native connection without starting MCP framing:

```sh
node /absolute/path/to/computer-use-mcp/packages/mcp/dist/index.js doctor
```

## Client configuration

### Codex

```sh
codex mcp add computer-use -- node \
  /absolute/path/to/computer-use-mcp/packages/mcp/dist/index.js
```

### Claude Code

```sh
claude mcp add --transport stdio --scope user computer-use -- \
  node /absolute/path/to/computer-use-mcp/packages/mcp/dist/index.js
```

### Claude Desktop and Cursor

```json
{
  "mcpServers": {
    "computer-use": {
      "command": "node",
      "args": [
        "/absolute/path/to/computer-use-mcp/packages/mcp/dist/index.js"
      ]
    }
  }
}
```

## Safety model

- A user grants one exact window or one display. The returned `grant_id` is the
  only public authority and is revoked when released or when the connection
  closes.
- Display grants are session-only.
- Every interaction requires a current `frame_id` and a human-readable
  `intent`. Element IDs and image coordinates are frame-bound.
- Access capabilities are cumulative: `interact` requires `observe`, and
  `clipboard_write` requires both. Paste accepts plain text only.
- The native access picker defaults to a 120-second timeout and accepts up to
  300 seconds. Action calls default to, and are capped at, 30 seconds so native
  risk confirmation has a usable response window.
- `computer_get_state` returns a bounded, flat structured accessibility tree.
  Supplying `since_frame_id` may return a deterministic `diff` bound to that
  exact base frame. When a safe diff is unavailable, the host returns a `full`
  tree with an explicit `reset_reason`. Display state uses an explicit empty
  `full` tree because AX elements are window-scoped. Secure nodes are marked
  and never expose values.
- Higher-risk actions use one challenge. Modern MCP clients receive form
  elicitation; clients without that capability use the native approval panel
  and retry the exact call with its one-shot `approval_request_id`.
- Set `COMPUTER_USE_MCP_APPROVAL_MODE=native` to require the one-shot native
  approval panel even when a client advertises form elicitation. The default is
  `auto`.
- Screenshots are PNG only, capped at 5 MiB decoded. Resource delivery expires
  after 60 seconds.

## Tools

Inventory and grants:

- `computer_get_status`
- `computer_list_displays`
- `computer_list_apps`
- `computer_request_access`
- `computer_release_access`

State and actions:

- `computer_get_state`
- `computer_click`
- `computer_drag`
- `computer_scroll`
- `computer_press_key`
- `computer_type_text`
- `computer_paste`
- `computer_set_value`
- `computer_select_text`
- `computer_perform_secondary_action`

Every completed tool response includes both `structuredContent` and a compact
JSON text fallback. Screenshot calls additionally return MCP image content or
an ephemeral resource link. Logs and native helper diagnostics go to stderr.

## License

Apache License 2.0. Copyright 2026 jmeguilos.
