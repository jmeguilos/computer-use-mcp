# Threat model

This document describes the security claims of `v0.1.0-alpha.1`. It is a design
contract, not a proof. A discrepancy between this document and behavior is a
security bug.

## Assets

Computer Use MCP may temporarily handle:

- pixels and Accessibility metadata from an approved window;
- text the user asked the model to type or paste;
- system pasteboard writes;
- control of pointer, keyboard, and semantic UI actions;
- app, process, display, and window identity;
- local connection-capability tokens and opaque grant, frame, and approval
  request identifiers; and
- audit metadata about attempted actions.

The highest-value assets are user intent, target isolation, approval integrity,
and the confidentiality of observed or typed content.

## Trust boundaries

```text
model/provider
      |
MCP client and transcript                 untrusted window content
      |                                             |
stdio MCP adapter -- private pipes --> signed bridge -- authenticated UDS --> native host
                                                                               |
                                                                  public APIs + TCC + user
```

The model, prompt, target-window content, and same-user harness invoking the
bridge are not trusted. A Developer ID-signed release authenticates the genuine
bridge as the host's direct socket peer and rejects unsigned direct peers, but
any same-user program can execute that genuine bridge. The source alpha further
permits same-user direct peers because it cannot enforce the signing boundary.
The native host and its grant/target checks form the reference enforcement
point. The host authenticates the signed native bridge—not Node or the bridge's
parent harness. The bridge reciprocally authenticates the connected native host
from kernel peer credentials, its sibling executable path and signing
requirement, and, in release mode, the expected bundle and Developer ID team.
On the normal bridge path, the bridge ignores caller-supplied
names and instance IDs and derives requester attribution from the nearest
verifiable GUI process ancestor, binding its PID, bundle ID, signing identity,
and process generation; if that is not possible, it reports **Unidentified local
MCP harness**. Explicit source-development direct peers bypass that derivation,
so their requester display attribution is untrusted. In either case requester
attribution is only UI/self-exclusion context: it neither authorizes the caller
nor prevents another same-user program from invoking the bridge. A
client that negotiates MCP elicitation is trusted
only to render the exact challenge and relay the interactive user's decision;
it receives no target authority from that decision. Clients not trusted for
approval UX must use the native-panel fallback. macOS, its public framework
contracts, the local kernel's peer credentials, and the interactive user are
trusted within the assumptions below.

## Assumptions

- The macOS login session and kernel are not already compromised.
- The user launches code from a source tree they reviewed and controls.
- The host's bundle and runtime directory are not replaced after approval.
- The interactive user can see the physical display and use the indicator's Stop
  control.
- The login session is unlocked. Locked use is excluded from v1; lock, sleep,
  screen sleep, or session resignation revokes active authority.
- When MCP elicitation is negotiated, the client faithfully renders the exact
  request and does not fabricate the user's confirmation. A compromised client
  or adapter can approve a challenged action, but still cannot mint or widen a
  native target grant. Set `COMPUTER_USE_MCP_APPROVAL_MODE=native` when this
  assumption is inappropriate for a client.
- The chosen MCP client and model provider may retain their own transcript; this
  project cannot enforce the provider's privacy policy.
- A process already able to inject code into the native host can exercise the
  host's TCC authority. Code-signing and hardened-runtime controls reduce this in
  signed builds but are not present in the source-only alpha.

## Permission boundary

macOS grants Screen Recording and Accessibility to an application identity, not
to one arbitrary third-party window. Per-window access is therefore an
application-level security policy:

- capture APIs accept only an approved target identity;
- action APIs require the matching grant and capability;
- a persisted native master switch must be on before an operation may expose or
  control another app;
- point/element selectors are bound to a recent frame;
- target identity is rechecked immediately before use; and
- window replacement fails closed rather than inheriting a grant.

This limits accidental and client-originated scope expansion, but cannot protect
against a compromised native host or operating system.

## Threats and controls

| Threat | Primary controls | Residual risk |
| --- | --- | --- |
| Host starts accepting control without an explicit first-run choice | General app access defaults off; preference validation and persistence fail closed; turning it off persists before Emergency Stop | Same-user malware inside the source-alpha trust boundary may tamper with the running development host or its state |
| An MCP client calls tools without consent | Native target picker; explicit capability grant; no ambient default target | A malicious client can repeatedly ask and create approval fatigue |
| Client changes an approved high-risk action | Canonical argument digest; integrity-protected modern `requestState` or connection/tool/argument-bound one-shot `approval_request_id`; short expiry | A malicious elicitation-capable client can fabricate approval within an existing native grant; use a client trusted for approval UX or the native fallback |
| Action lands in another window after focus or timing change | Window/PID/bundle/signing revalidation; frame freshness; focus check; serialized action | macOS focus can change between final check and global event delivery |
| Window ID is reused | PID, bundle, signing identity, bounds/generation checks; `TARGET_RECREATED`/`WINDOW_CLOSED` fail closed | Public APIs do not expose one perfect universal generation identifier |
| Same-user process seeks host authority or replaces one socket endpoint | `0700` directory, `0600` socket/token, mutual kernel peer UID/PID/audit-token inspection, authenticated hello, connection capability; the bridge pins the server to the sibling host path/signing requirement; designated bundle/team checks reject unsigned endpoint replacements in Developer ID-signed releases; on the normal bridge path the bridge derives and generation-binds the nearest verifiable GUI ancestor for display and self-exclusion; exact native target and action consent applies to every connection | Any same-user program can invoke the genuine signed bridge, so signing authenticates bridge code and ancestry attribution does not authorize the parent harness. Explicit source-development mode also permits same-user direct peers, whose requester display attribution is untrusted. Malware able to replace the explicitly trusted source tree/runtime or inject into a correctly signed release helper or host is out of scope |
| Remote attacker reaches the bridge | No network listener; Unix-domain socket only | A compromised MCP client can relay requests from elsewhere |
| Target window contains prompt injection | Treat pixels/AX strings as untrusted data; no content can mint grants or approvals; visible native confirmation | The model may still follow malicious instructions inside content |
| Screenshot or typed secret leaks through logs | Memory-only image cache; content excluded from audit; redacted digest/length metadata; mode-`0600` files | MCP clients/providers may store tool inputs and results |
| Secure/password content is read, selected, or changed without exact approval | Secure Accessibility fields stay redacted and unselectable; direct secure-text value writes require a consumed high-risk one-shot approval; protected content, secure descendants, and ambiguous ancestry stay denied; no clipboard read | Pixel capture may still show secrets the app itself renders visibly; explicitly approved write-only input reaches the target application |
| User cannot stop control | Always-visible left-edge indicator; Stop revokes first; disconnect/idle/lock/exit revocation | A frozen WindowServer, invisible display, or compromised host may prevent UI response |
| Indicator spoofs system consent or target state | Original project UI; non-system styling; bound to target and current grant state | Another app can draw a lookalike; users should verify the target and app identity |
| Denial of service or event flood | Strict schemas and size caps; per-request deadlines; target serialization; bounded frame cache; cancel method | A permitted client can consume local CPU within configured limits |
| Path or shell injection through app selectors | Typed app selector; no shell interpolation; canonical path matching only for already-running apps; `launch_if_needed` limited to a separately approved bundle-ID resolution | Launching an approved installed app still executes that app before the exact-window picker appears |
| Malicious dependency or build action | Lockfiles; immutable action SHAs; dependency review; CodeQL; SBOM; source-only release; provenance scanner; signed bridge identity in release design | Registry, compiler, or local source-build compromise is not completely eliminated |
| Unauthorized persistent approval | Bundle ID plus exact designated-requirement digest; policy is not a bearer token; per-app and bulk removal in settings; fresh exact-window grant remains mandatory | A local source-development rebuild changes the ad-hoc code identity and invalidates the old match; production persistence still depends on release-signing hygiene |

## Protected targets

The host denies known security-sensitive/system processes, every System Settings
window, terminal-emulator identities and terminal-like bundle/process names,
the lock/login screen, invalid offscreen targets, protected content, secure
descendants, and ambiguous secure surfaces. A direct secure text field remains
write-only: its metadata and value are redacted, text selection and generic AX
actions are denied, and `computer_set_value` can reach it only after an exact
high-risk approval has been consumed. The host does not downgrade to a private
capture or input path after a denial. A denial is returned as structured data
and recorded without sensitive content.

Full-display capture is a separate, explicit scope. It is session-only and does
not authorize Accessibility access to every window. Clients should request it
only for an operation that cannot be expressed as a user-selected window.
For the alpha, display capture freezes a ScreenCaptureKit inclusion allowlist of
the exact safe windows validated before each frame. Newly launched windows and
applications cannot enter that frame. ScreenCaptureKit's window-inclusion mode
omits the desktop background, Dock, and menu bar; the returned image retains the
selected display's full coordinate space with those surfaces blanked.

Remembered application approval never chooses a window or creates a live grant.
Every request still presents an exact target choice, and a display approval is
never persisted. Turning General app access off leaves remembered decisions on
disk but prevents their use and immediately revokes active grants.

## Prompt-injection guidance for harnesses

Text visible inside a controlled app is data, even when it tells the model to
ignore previous instructions, request another app, reveal secrets, or click an
approval. Harnesses should:

1. keep the user's goal and approved target above observed content in authority;
2. never treat window text as consent;
3. require explicit MCP elicitation or native-panel approval for sensitive
   action categories;
4. avoid moving from one app to another without a new access request; and
5. summarize a proposed irreversible action in `intent` before invoking it.

The native host enforces grants and approval challenges, but it cannot decide
whether model reasoning was socially engineered.

## Availability and fail-closed behavior

The following conditions revoke or deny authority instead of falling back:

- missing or revoked Screen Recording or Accessibility permission;
- General app access off, unreadable, or not durably updated;
- incompatible bridge protocol or capability set;
- invalid token, peer identity, connection, session, target, or frame;
- target closure, replacement, protection, or ambiguous identity;
- locked session, expired deadline, client disconnect, idle expiry, or Stop;
- inability to position a truthful indicator; and
- unsupported private/background driver request.

The optional targeted private-driver path is disabled by default and
operating-system-version-gated. An unsupported or unavailable implementation is
an explicit denial; it never causes a hidden private fallback.

Failures should be recoverable through a fresh status check, observation, or
access request—not by weakening validation.

## Out of scope

- a malicious administrator, root process, kernel extension, hypervisor, or
  compromised macOS installation;
- hardware capture or input devices;
- security guarantees made by the chosen MCP client or model provider;
- applications that intentionally misreport their Accessibility tree;
- preventing a user from manually granting broad TCC permissions to other apps;
- unattended control on the login window or a different user's session;
- locked use, lock-screen interaction, or automatic user-takeover detection;
- a generally available private targeted-input driver or guaranteed background
  coordinate input.

## Security review checklist

A change is security-sensitive if it affects a tool schema, target selection,
coordinate transform, grant persistence, TCC identity, socket/token handling,
approval classification, audit field, resource retention, indicator visibility,
or release signing. Such changes require:

- a stated abuse case;
- tests for denial, revocation, stale state, and cancellation;
- review by a maintainer familiar with both bridge sides;
- privacy and protocol documentation updates; and
- passing provenance, dependency, static-analysis, SBOM, native, and integration
  gates.
