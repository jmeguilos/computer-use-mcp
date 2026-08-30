# Computer Use MCP macOS host

This Swift package contains the macOS 14.4+ host, the signed native bridge, and a deterministic fixture app. It uses ScreenCaptureKit, Accessibility, and public CoreGraphics event APIs. Input Monitoring is not requested.

For a local source build, run:

```sh
./Scripts/setup.sh
```

That thin wrapper invokes the repository's canonical `scripts/setup-local.sh --adhoc-sign` flow. It builds an ad-hoc-signed app, installs it in the per-user Applications directory, creates the private source-development marker, launches onboarding, and does not download anything. Release builds should instead pass an explicit Developer ID identity to `Scripts/assemble-app.sh --codesign-identity ...` and complete the normal Apple notarization workflow outside this package.

Run the inspectable fixture as an actual app bundle (not a bare SwiftPM executable) with:

```sh
./Scripts/run-fixture.sh
```

The fixture prints its deterministic JSON manifest to stdout and opens its two baseline windows. Its Inspector buttons expose duplicate-title, sheet, and popover cases on demand.

Alpha security policy is deliberately conservative: every System Settings window is denied, because public window metadata does not expose a stable locale-independent identifier for security and authorization panes. Known terminal bundle identifiers are blocked, and case-insensitive terminal-name/bundle fragments fail closed for newly branded variants. `launch_if_needed` accepts a resolved bundle identifier only; path selectors may target an already-running exact bundle path but are never executed by the host. Risk prompts show a short escaped payload preview only when a unique frame-bound non-secure accessibility element is known; secure or ambiguous destinations show length and format only.
