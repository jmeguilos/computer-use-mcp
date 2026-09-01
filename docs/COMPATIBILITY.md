# MCP client compatibility

The configurations below were checked against official client documentation on
2026-08-29. Client configuration formats change independently; follow the linked
vendor documentation if a newer client rejects an example.

All examples launch the same source-built stdio entry point:

```text
/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
```

Replace that placeholder with a real absolute path. Build the repository and run
`npm run doctor` first. The npm package is not published in this alpha.

## Codex

The Codex CLI and IDE use `~/.codex/config.toml`; a trusted project can use
`.codex/config.toml`. Register from the CLI:

```sh
codex mcp add computer-use-mcp -- \
  node /ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
codex mcp list
```

Equivalent TOML:

```toml
[mcp_servers.computer_use_mcp]
command = "node"
args = ["/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js"]
startup_timeout_sec = 20
tool_timeout_sec = 310
required = true
default_tools_approval_mode = "prompt"
```

Use `/mcp` in a Codex session to confirm connection state. Keep tool approval in
prompt mode during the alpha; native grants are an additional boundary, not a
reason to disable client-side review.

Official source: [Codex MCP configuration](https://developers.openai.com/codex/mcp/).

## Claude Desktop

The alpha is a developer-defined local MCP server, not a Desktop Extension.
Claude Desktop on macOS reads:

```text
~/Library/Application Support/Claude/claude_desktop_config.json
```

Merge this entry into the existing top-level `mcpServers` object:

```json
{
  "mcpServers": {
    "computer-use-mcp": {
      "command": "node",
      "args": [
        "/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js"
      ]
    }
  }
}
```

Fully quit Claude Desktop—not only its window—and reopen it. Desktop clients may
not inherit your interactive shell's `PATH`; if `node` is not found, replace it
with the absolute path printed by `command -v node`.

Team or Enterprise policy can disable local developer MCP servers. An
administrator must allow local development; do not work around an organizational
policy. Current Claude Desktop distribution emphasizes signed desktop extensions,
which this source-only alpha intentionally does not ship.

Official sources:
[Anthropic local MCP guidance](https://support.anthropic.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)
and [the official MCP SDK host configuration](https://py.sdk.modelcontextprotocol.io/get-started/real-host/).

## Claude Code

Register a user-scoped source build:

```sh
claude mcp add --scope user computer-use-mcp -- \
  node /ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
claude mcp get computer-use-mcp
claude mcp list
```

For a reviewed team configuration, commit `.mcp.json` at the project root:

```json
{
  "mcpServers": {
    "computer-use-mcp": {
      "command": "node",
      "args": [
        "/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js"
      ],
      "env": {}
    }
  }
}
```

Claude Code asks before trusting project-scoped servers. Review the exact command
and absolute path. `local` scope is private and project-specific; `project` writes
`.mcp.json`; `user` is available across projects.

Official source: [Claude Code MCP documentation](https://docs.anthropic.com/en/docs/claude-code/mcp).

## Cursor IDE and CLI

Cursor reads project configuration from `.cursor/mcp.json` and global
configuration from `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "computer-use-mcp": {
      "command": "node",
      "args": [
        "/ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js"
      ],
      "env": {}
    }
  }
}
```

Open **Cursor Settings → MCP**, verify the command, and enable the server. Cursor
supports stdio and may support elicitation, but Computer Use MCP does not require
elicitation. Keep action tools outside broad auto-run allowlists during the
alpha. Cursor CLI uses the same MCP configuration.

Official source: [Cursor MCP documentation](https://docs.cursor.com/context/model-context-protocol).

## MCP Inspector

MCP Inspector can launch a stdio server directly:

```sh
npx --yes @modelcontextprotocol/inspector@2.4.0 \
  node /ABSOLUTE/PATH/TO/computer-use-mcp/packages/mcp/dist/index.js
```

Version `2.4.0` was the current registry version when this document was checked.
Pinning it makes a diagnostic run repeatable. The Inspector does not replace the
native target picker.

Official source: [MCP SDK Inspector guidance](https://ts.sdk.modelcontextprotocol.io/v2/get-started/first-server).

## Clients without elicitation

Elicitation is not required. A client needs only standard tool discovery/calls
and image/resource result support. After native target access is granted, action
calls run within that grant without an additional approval/retry exchange.

A client that cannot render MCP image content can request `screenshot: "resource"`; a
client with neither image nor resource support can request
`screenshot: "none"` and use bounded Accessibility state.

## Compatibility contract

| Requirement | Minimum client behavior |
| --- | --- |
| Transport | launch a local stdio MCP server |
| Tools | list and call tools with JSON objects |
| Approvals | native target grant; no MCP elicitation or action retry token required |
| Images | recommended; resource or inline image content |
| Timeouts | permit up to 300 seconds for access selection; actions cap at 30 seconds |
| Cancellation | terminate/cancel cleanly; disconnect revokes the session |

The native host is macOS-only. A remote/cloud MCP runtime cannot control the
user's Mac unless the stdio adapter and native host actually run in that same
interactive macOS login session. Do not expose the local bridge over a tunnel.
