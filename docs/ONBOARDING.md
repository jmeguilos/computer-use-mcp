# Onboarding and settings

Computer Use MCP starts conservatively. On a first launch, the native menu-bar
host opens its Computer Control settings window, but it does not enable control,
grant macOS privacy access, or select an application on the user's behalf.

This guide describes the source alpha. Use only an unlocked, interactive macOS
14.4+ session and non-sensitive test windows.

## First-run flow

1. **Review the source-build warning.** An ad-hoc source build authenticates the
   local bridge with kernel-reported same-user credentials and private tokens,
   while the bridge pins the server to the sibling host path and signing
   requirement before hello. Source mode cannot enforce the host-side Developer
   ID bridge-signing boundary used by a signed release. Another process running
   as the same user is inside the source alpha's trust boundary. A signed release
   can authenticate bridge code, not authorize the same-user harness that
   launched it. On the normal bridge path,
   the bridge ignores caller-supplied names and derives requester attribution
   from the nearest verifiable GUI process ancestor, or reports **Unidentified
   local MCP harness**. Explicit source-development direct peers bypass that
   derivation, so requester display attribution must be treated as untrusted;
   native target and action consent is still required in either mode.
2. **Choose whether to accept computer-control requests.** **General app
   access** is a native, persisted master switch and defaults to off. Turning it
   on only allows connected MCP clients to ask for access. It does not grant a
   macOS permission, choose a target, or approve an action.
3. **Grant Screen Recording separately.** The **Screen visibility** row reports
   Screen Recording state and links to the applicable macOS permission flow.
   macOS may require **Quit & Reopen** before the new state is visible.
4. **Grant Accessibility separately.** The **App interaction** row reports the
   Accessibility capability used for semantic inspection, actions, and public
   event posting. Input Monitoring is not requested or required in v1.
5. **Select Check Again.** Permission prompts and System Settings changes can be
   asynchronous. Return to the host and refresh until both rows report ready.
6. **Finish onboarding with Done.** Done attempts to durably record the current
   onboarding revision and leaves the host available from its menu-bar item.
   Setup is complete only if that protected preference write succeeds. Closing
   without Done, or a failed write, leaves the revision incomplete so first-run
   setup appears again on the next launch. The same window is always available
   from **Computer Control Settings…**.

The two macOS permissions are application-wide TCC decisions. Neither gives an
MCP client a window, display, or action grant. If either required permission is
missing, or General app access is off, the host fails closed for operations that
could inspect or control another application. Status and Stop remain available.

## Approving an exact target

After setup, a client calls `computer_request_access` with a reason and bounded
capabilities. Native UI then requires a concrete target choice:

- a **window grant** is bound to that exact window and current app/process
  identity; or
- a **display grant** is bound to one selected display, is session-only, and is
  never remembered.

**Always Allow App** is the persistent app choice. It remembers the verified
requesting harness identity, signed target application identity, and approved
capability set. It never creates ambient authority: the harness must make a new
explicit request, the host must resolve exactly one safe Accessibility-bound
window, and the control rail must appear before a new connection-bound grant is
published. Multiple matching windows, a changed requester or app signature, and
capability escalation open the native picker again. Display requests remain
session-only, and application launch has its own prompt.

The settings window lists **Always-allowed apps**. **Remove** deletes one saved
requester/app policy and **Remove All** deletes all of them after confirmation.
Removal changes future requests; use Stop to end an already active exact-target
grant. Records created by an older build under the prompt-every-window wording
remain prompt-only until a new explicit Always Allow decision is made.

## General app access

The General app access switch is independent of both TCC and always-allowed apps:

- **Off** is the default and blocks computer-use operations that could expose or
  change another app. Turning it off immediately invokes Emergency Stop and
  revokes active grants.
- **On** permits new native access requests but conveys no target authority by
  itself.
- Turning the switch off does not delete always-allowed app policies. Remove them
  separately if they should no longer be recognized on future requests.
- A preference read or persistence failure must fail closed; the UI must not
  claim that control is enabled when the native policy could not persist it.

## Stop and human takeover

Each active grant has a visible edge rail or helper-owned status panel showing
the bridge-derived requester identity (or **Unidentified local MCP harness**),
mode, target, and **Stop**. That identity is bound to the nearest verifiable GUI
ancestor's PID, bundle ID, signing identity, and process generation, but it is
attribution rather than target authority. Stop revokes that target grant before
closing its indicator. **Emergency Stop** in the menu-bar item revokes all active
grants.

This explicit Stop path is v1's human-takeover mechanism. The host does not
observe global keyboard or pointer input, so merely clicking or typing does not
atomically pause the MCP client. Press Stop before taking over a target.

Lock, sleep, session resignation, disconnect, target replacement, idle expiry,
or host exit also revokes active authority. Locked use is excluded from v1:
there is no lock-screen control, locked-use toggle, or unattended authentication.

## Current input-driver boundary

Semantic Accessibility actions are preferred. Public Core Graphics coordinate
fallbacks may temporarily focus a target and then restore prior focus. The
optional targeted private-driver path is disabled by default, version-gated, and
reported unavailable when the running macOS build is unsupported or the alpha
has no validated implementation. The host fails closed instead of silently
selecting a private or background input path.

## Returning to settings

Open the host's menu-bar item and choose **Computer Control Settings…** to:

- turn General app access on or off;
- review Screen Recording and Accessibility separately;
- refresh permission state with Check Again;
- remove one or all always-allowed app policies; or
- use Emergency Stop before changing control policy.

**Saved App Access…** is a shortcut to the same settings window, not a second
approval surface. The menu's **General App Access** item controls the same
persisted master switch; it is not a separate grant.

For build and client configuration steps, continue with [Setup](SETUP.md). For
the enforcement boundaries behind this flow, see [Architecture](ARCHITECTURE.md)
and the [Threat model](THREAT_MODEL.md).
