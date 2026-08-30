# Manual acceptance

The source alpha cannot be released from unattended CI alone. Screen Recording,
Accessibility, native target selection, real event delivery, and the visible
Stop control require an unlocked interactive Mac and explicit user decisions.

Run this matrix from a clean checkout of the exact proposed release commit. Use
the deterministic two-window fixture and test data only. Do not weaken TCC,
preseed a grant, auto-click native consent, or place secrets in screenshots,
prompts, logs, or evidence.

## Required clients

Record the installed version and result for each current client:

| Client | Required route |
| --- | --- |
| Codex | stdio MCP configuration and the approval route it advertises |
| Claude Desktop or Claude Code | stdio MCP configuration and its advertised approval route |
| Cursor | stdio MCP configuration and its advertised approval route |
| MCP Inspector | interactive stdio tool calls and its advertised approval route |
| Minimal no-elicitation client | native one-shot approval/retry fallback |

For every row, complete this sequence on a fresh MCP connection:

1. connect and confirm exactly 15 namespaced tools;
2. call status and list the fixture application;
3. request one exact fixture-window grant and reject the duplicate-title
   ambiguity by selecting the intended window in native UI;
4. capture state, verify the screenshot/Accessibility bounds, and confirm the
   left-edge rail is absent from captured pixels;
5. perform one harmless frame-bound action and verify the fixture result;
6. trigger one risky fixture action, approve the exact unchanged action through
   that client's supported route, and verify changed arguments are rejected;
7. press the native **Stop** control and verify capture and action calls fail;
8. disconnect and verify the host reports no grant from that connection.

At least one run must also exercise the separately approved session-only display
grant, confirm protected applications and the rail are absent from the capture,
and revoke it with Stop. Exercise clipboard restoration, stale-frame rejection,
target close/relaunch revocation, duplicate titles, a sheet or popover, an
occluded/minimized target, and concurrent connections across the matrix.

## Evidence and release binding

Keep a local, content-free record containing only:

- full commit SHA, release version, date, macOS version, hardware/display layout,
  and tester;
- client and host versions;
- pass/fail for each step and any non-sensitive error code; and
- confirmation that the host, bridge, fixture, and audit files used expected
  identities and permissions.

Do not commit screenshots, Accessibility contents, clipboard values, capability
tokens, socket credentials, or approval IDs. After every row passes, set the
repository variable `ALPHA_MANUAL_ACCEPTANCE_SHA` to the tested full commit SHA.
Any source change invalidates the record and requires the matrix to be rerun.
