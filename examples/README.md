# Client examples

These files configure the source-built stdio server. Replace
`/ABSOLUTE/PATH/TO/computer-use-mcp` with the checkout's real absolute path after
running:

```sh
npm ci
npm run build
npm run setup
npm run doctor
```

| File | Destination/use |
| --- | --- |
| `codex-config.toml` | merge into `~/.codex/config.toml` or trusted project `.codex/config.toml` |
| `claude-desktop-config.json` | merge into the existing Claude Desktop config |
| `claude-code.mcp.json` | example project-root `.mcp.json` |
| `cursor-mcp.json` | example `.cursor/mcp.json` or `~/.cursor/mcp.json` |
| `mcp-inspector.sh` | launch pinned MCP Inspector against the local build |
| `no-elicitation-client.md` | approval retry pattern for older/minimal clients |

Do not paste one JSON file over an existing configuration; merge its
`mcpServers` member. Do not place secrets or signing credentials in MCP client
configuration. The server needs no network API key.

Client approval should remain enabled for action tools. The native grant/risk
layer remains mandatory even when a client is configured to auto-run tools, but
the two layers protect against different failures.

See [the compatibility guide](../docs/COMPATIBILITY.md) for verified locations,
CLI commands, policy notes, and official documentation links.
