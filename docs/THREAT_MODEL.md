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

The model, prompt, target-window content, and other same-user processes are not
automatically trusted. The native host and its grant/target checks form the
reference enforcement point. The host authenticates the signed native
bridge—not Node directly. A client that negotiates MCP elicitation is trusted
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
- point/element selectors are bound to a recent frame;
- target identity is rechecked immediately before use; and
- window replacement fails closed rather than inheriting a grant.

This limits accidental and client-originated scope expansion, but cannot protect
against a compromised native host or operating system.

## Threats and controls

| Threat | Primary controls | Residual risk |
| --- | --- | --- |
| An MCP client calls tools without consent | Native target picker; explicit capability grant; no ambient default target | A malicious client can repeatedly ask and create approval fatigue |
| Client changes an approved high-risk action | Canonical argument digest; integrity-protected modern `requestState` or connection/tool/argument-bound one-shot `approval_request_id`; short expiry | A malicious elicitation-capable client can fabricate approval within an existing native grant; use a client trusted for approval UX or the native fallback |
| Action lands in another window after focus or timing change | Window/PID/bundle/signing revalidation; frame freshness; focus check; serialized action | macOS focus can change between final check and global event delivery |
| Window ID is reused | PID, bundle, signing identity, bounds/generation checks; `TARGET_RECREATED`/`WINDOW_CLOSED` fail closed | Public APIs do not expose one perfect universal generation identifier |
| Same-user process connects to the host | `0700` directory, `0600` socket/token, kernel peer UID/PID, authenticated hello, connection capability; designated signing requirement/team check in Developer ID-signed releases | Explicit source-development mode omits signing verification, so same-user malware is inside its trust boundary; malware able to inject into a correctly signed release helper or host is out of scope |
| Remote attacker reaches the bridge | No network listener; Unix-domain socket only | A compromised MCP client can relay requests from elsewhere |
| Target window contains prompt injection | Treat pixels/AX strings as untrusted data; no content can mint grants or approvals; visible native confirmation | The model may still follow malicious instructions inside content |
| Screenshot or typed secret leaks through logs | Memory-only image cache; content excluded from audit; redacted digest/length metadata; mode-`0600` files | MCP clients/providers may store tool inputs and results |
| Secure/password content is read or overwritten | Secure Accessibility fields redacted; protected targets denied; no clipboard read; explicit clipboard-write grant | Pixel capture may still show secrets the app itself renders visibly |
| User cannot stop control | Always-visible left-edge indicator; Stop revokes first; disconnect/idle/lock/exit revocation | A frozen WindowServer, invisible display, or compromised host may prevent UI response |
| Indicator spoofs system consent or target state | Original project UI; non-system styling; bound to target and current grant state | Another app can draw a lookalike; users should verify the target and app identity |
| Denial of service or event flood | Strict schemas and size caps; per-request deadlines; target serialization; bounded frame cache; cancel method | A permitted client can consume local CPU within configured limits |
| Path or shell injection through app selectors | Typed app selector; no shell interpolation; canonical path matching only for already-running apps; `launch_if_needed` limited to a separately approved bundle-ID resolution | Launching an approved installed app still executes that app before the exact-window picker appears |
| Malicious dependency or build action | Lockfiles; immutable action SHAs; dependency review; CodeQL; SBOM; source-only release; provenance scanner; signed bridge identity in release design | Registry, compiler, or local source-build compromise is not completely eliminated |
| Unauthorized persistent approval | Bundle ID plus exact designated-requirement digest; policy is not a bearer token; host-menu clear action; fresh exact-window grant | A local source-development rebuild changes the ad-hoc code identity and invalidates the old match; production persistence still depends on release-signing hygiene |

## Protected targets

The host denies known security-sensitive/system processes, every System Settings
window, terminal-emulator identities and terminal-like bundle/process names,
secure input fields, the lock/login screen, invalid offscreen targets, and
surfaces that public APIs mark as protected. It does not downgrade to a private
capture or input path after a denial. A denial is returned as structured data and
recorded without sensitive content.

Full-display capture is a separate, explicit scope. It is session-only and does
not authorize Accessibility access to every window. Clients should request it
only for an operation that cannot be expressed as a user-selected window.
For the alpha, display capture freezes a ScreenCaptureKit inclusion allowlist of
the exact safe windows validated before each frame. Newly launched windows and
applications cannot enter that frame. ScreenCaptureKit's window-inclusion mode
omits the desktop background, Dock, and menu bar; the returned image retains the
selected display's full coordinate space with those surfaces blanked.

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
- incompatible bridge protocol or capability set;
- invalid token, peer identity, connection, session, target, or frame;
- target closure, replacement, protection, or ambiguous identity;
- locked session, expired deadline, client disconnect, idle expiry, or Stop;
- inability to position a truthful indicator; and
- unsupported private/background driver request.

Failures should be recoverable through a fresh status check, observation, or
access request—not by weakening validation.

## Out of scope

- a malicious administrator, root process, kernel extension, hypervisor, or
  compromised macOS installation;
- hardware capture or input devices;
- security guarantees made by the chosen MCP client or model provider;
- applications that intentionally misreport their Accessibility tree;
- preventing a user from manually granting broad TCC permissions to other apps;
- unattended control on the login window or a different user's session.

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
