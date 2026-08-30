# Manual acceptance

The source alpha cannot be released from unattended CI alone. Screen Recording,
Accessibility, native target selection, real event delivery, and the visible
Stop control require an unlocked interactive Mac and explicit user decisions.

Run this matrix from a clean checkout of the exact proposed release commit. Use
the deterministic two-window fixture and test data only. Do not weaken TCC,
preseed a grant, auto-click native consent, or place secrets in screenshots,
prompts, logs, or evidence.

## First-run and settings regression

Begin from a fresh test-only `ComputerUseMCP` Application Support directory and
an installed source candidate produced by `setup`:

1. launch the host and confirm its original Computer Control window appears when
   the stored onboarding revision is incomplete;
2. confirm the source-development warning clearly limits use to non-sensitive
   data and states that the release signing-identity boundary is absent;
3. confirm **General app access** defaults off and that status and Stop remain
   available while app/display listing, access, state, and input operations fail
   closed without exposing another app;
4. confirm turning the switch on does not change either macOS permission, create
   a grant, or bypass a later exact-target choice;
5. confirm Screen Recording and Accessibility appear as two separate rows,
   Input Monitoring is absent, and Check Again or application activation
   refreshes state without granting access;
6. close without Done, relaunch, and confirm setup appears again; then select
   Done, relaunch, and confirm the host remains menu-bar-only until **Computer
   Control Settings…** reopens the same window;
7. with an active fixture grant, turn General app access off and confirm the off
   state is persisted before the indicator disappears and the grant is revoked;
8. with another active fixture grant, make the protected preference write fail,
   request off again, and confirm the current process latches control off and
   Emergency-Stops even though durable persistence failed;
9. relaunch and confirm the switch remains off after a successful write while
   remembered app decisions remain listed;
10. replace the preference file with each unsafe case covered by unit tests
   (wrong mode, symbolic link, invalid schema, malformed data) in an isolated
   runtime and confirm startup or policy evaluation fails closed rather than
   visually or operationally enabling control; and
11. make the onboarding-revision persistence write fail in an isolated runtime,
    select Done, relaunch, and confirm onboarding was not recorded as complete.

The master switch is not a substitute for Stop. Confirm the target rail's Stop
revokes only its grant and menu-bar Emergency Stop revokes all grants. Because v1
does not monitor global input, also confirm that the UI tells the tester to press
Stop before manual takeover rather than implying that a local click auto-pauses
the client.

## Permission relaunch regression

Before the client matrix, install the source candidate and exercise macOS's
permission restart path:

1. enable Screen Recording for `ComputerUseMCPHost` and choose macOS **Quit &
   Reopen** when offered;
2. confirm the relaunched process has no `--development-mode` argument and that
   `doctor` still reaches the authenticated native handshake;
3. enable Accessibility, relaunch if requested, and confirm `doctor` reports
   both permissions granted; and
4. in a separate non-sensitive test runtime, confirm a no-argument ad-hoc host
   without the exact mode-`0600` source-development marker fails closed with
   `developmentModeDisabled`.

A Developer ID-signed build must select release peer verification whether the
source marker is present or absent.

Confirm lock, screen sleep, system sleep, and session resignation each revoke
active grants. Do not test or claim locked-session control: locked use is
excluded from v1 and there is no locked-use toggle.

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
6. target the redacted fixture Passcode with `computer_set_value`, approve the
   exact unchanged high-risk action through that client's supported route,
   verify changed arguments are rejected, then recapture and confirm the secure
   node still exposes no title, label, value, or actions;
7. press the native **Stop** control and verify capture and action calls fail;
8. disconnect and verify the host reports no grant from that connection.

For one window run, select **Remember this verified app identity for future
requests**, stop the grant, and start a new request. Confirm the remembered
signed app identity never preselects or automatically grants a window: the native
exact-window choice remains mandatory even when there is only one candidate. In
**Computer Control Settings…**, verify the app entry and capability summary,
remove that row, and confirm the next request needs a fresh app decision. Repeat
with two entries and verify confirmed Remove All clears both without changing an
already active grant.

At least one run must also exercise the separately approved session-only display
grant, confirm protected applications and the rail are absent from the capture,
and revoke it with Stop. Exercise clipboard restoration, stale-frame rejection,
target close/relaunch revocation, duplicate titles, a sheet or popover, an
occluded/minimized target, and concurrent connections across the matrix.

Exercise public coordinate fallback with focus restoration. If a build exposes
the optional targeted private-driver setting, confirm it is disabled by default,
rejects unsupported macOS versions, and reports unavailable when no validated
implementation exists. It must not silently switch to a private/background path.

Across the hardware matrix, explicitly cover Retina and mixed-scale displays,
negative display origins, window move/resize, full-screen, Stage Manager, and
multiple Spaces. A display grant must remain session-only after every relaunch
and must never appear in remembered app access.

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
