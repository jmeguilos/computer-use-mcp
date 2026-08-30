# Test layout

The executable test suites live with the code they verify:

- `packages/protocol/test`: cross-language wire invariants and canonical approval binding.
- `packages/mcp/test`: MCP schemas, responses, cancellation, native-bridge failure modes, and compatibility.
- `apps/macos-host/Tests`: permissions, grants, capture transforms, action policy, IPC, lifecycle, audit redaction, and fixture behavior.
- `evals/fixture.xml`: read-only agent-use evaluations against deterministic pre-granted fixture state.

The root `npm run verify` command runs the mandatory source-release gates. Live UI and harness smoke checks are intentionally separate because they require an unlocked, interactive Mac and explicit grants.

The required release matrix and evidence rules are in
[Manual acceptance](MANUAL_ACCEPTANCE.md). A repository variable binds a passing
manual run to the exact release commit.
