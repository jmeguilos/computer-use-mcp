# Computer Use MCP macOS host

This Swift package contains the macOS 14.4+ host, the native bridge, and a
deterministic fixture app. The bridge is Developer ID-signed in an eligible
release and ad-hoc-signed in the source-development flow. The host uses
ScreenCaptureKit, Accessibility, and public Core Graphics event APIs. Input
Monitoring is not requested. Locked-session control is not supported in v1;
lock, sleep, or session resignation revokes active grants.

For a local source build, run:

```sh
./Scripts/setup.sh
```

That thin wrapper invokes the repository's canonical
`scripts/setup-local.sh --adhoc-sign` flow. It builds an ad-hoc-signed app,
installs it in the per-user Applications directory, creates the private
source-development marker, launches the original AppKit first-run window, and
does not download anything. The marker also lets LaunchServices restart the
installed source-development host after a macOS permission change without
relying on command-line arguments. A Developer ID-signed host ignores the marker
and requires its release signing policy. Release builds should pass an explicit
Developer ID identity to `Scripts/assemble-app.sh --codesign-identity ...` and
complete the normal Apple notarization workflow outside this package.

The first-run window separates **Screen Recording** from **Accessibility** and
keeps the persisted **General app access** switch off by default. That switch is
the native master policy: off denies operations that could expose or control
another app while status and Stop remain available; turning it off also revokes
active grants. Turning it on only lets clients present access requests. It does
not change TCC, approve an app, or choose a target. Every window grant requires
an exact window choice even when the signed app identity is remembered, and
display grants are always session-only. The same window can be reopened from
**Computer Control Settings…** in the menu-bar item and supports per-app or bulk removal
of remembered decisions. See [Onboarding and settings](../../docs/ONBOARDING.md).

Each active target exposes a local Stop on its edge indicator; the menu-bar item
also provides Emergency Stop for all grants. This explicit Stop is the v1 human
takeover path because the host does not monitor global input.

Run the inspectable fixture as an actual app bundle, not a bare SwiftPM
executable:

```sh
./Scripts/run-fixture.sh
```

The fixture prints its deterministic JSON manifest to stdout and opens its two
baseline windows. Its Inspector buttons expose duplicate-title, sheet, and
popover cases on demand.

CI launches the assembled bundle in a permission-free runtime smoke mode:

```sh
./Scripts/run-fixture.sh --runtime-smoke
```

That mode exercises the fixture's two baseline windows, stable controls,
duplicate-title window, sheet, popover, and harmless actions using only its own
in-process AppKit objects. It never requests Screen Recording or Accessibility,
writes a deterministic validation report in a private temporary directory, and
then exits. The default command above remains the interactive fixture.

Alpha security policy is deliberately conservative: every System Settings window
is denied because public window metadata does not expose a stable,
locale-independent identifier for security and authorization panes. Known
terminal bundle identifiers are blocked, and case-insensitive terminal-name or
bundle fragments fail closed for newly branded variants. `launch_if_needed`
accepts a resolved bundle identifier only; path selectors may target an
already-running exact bundle path but are never executed by the host. Risk
prompts show a short escaped payload preview only when a unique, frame-bound,
non-secure Accessibility element is known; secure or ambiguous destinations show
length and format only. Direct secure text fields are write-only and require an
exact high-risk approval; protected content, secure descendants, reads, and text
selection remain denied.

The source alpha host verifies incoming peers with same-user kernel credentials
and private tokens but cannot enforce the Developer ID bridge-signing boundary;
other same-user processes are inside its development trust boundary. The bridge
also verifies the socket server's kernel identity and pins it to the sibling host
executable path and signing requirement before hello. A signed release adds the
expected bundle and Developer ID team checks in both directions. Authenticating
the genuine bridge as the host's direct socket peer does not authorize the
same-user harness that launched the bridge. On the normal
bridge path, the bridge discards caller-supplied names and instance IDs and
derives requester attribution from the nearest verifiable GUI process ancestor,
bound to its PID, bundle ID, signing identity, and process generation; it reports
**Unidentified local MCP harness** when no such ancestor is available. Explicit
source-development direct peers bypass that derivation, so their requester
display attribution is untrusted. Requester attribution is never permission to
control a target. Exact native target and action consent remains the authority
boundary in either mode.
Use only non-sensitive test data with the source alpha. The optional targeted
private input path is disabled by default, version-gated, and reports unavailable
when unsupported or not validated; it never silently replaces the public input
path.
