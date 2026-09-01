# Contributing

Computer Use MCP welcomes focused, reviewable contributions. Because the
project crosses macOS privacy boundaries, correctness includes denying access
safely, showing truthful control state, and preserving provenance—not only
making an action succeed.

## Before you start

1. Read the [architecture](docs/ARCHITECTURE.md),
   [threat model](docs/THREAT_MODEL.md), and
   [source provenance policy](docs/PROVENANCE.md).
2. Search existing issues and open a design issue for a new permission,
   persistent grant type, transport, private API, capture mode, or action class.
3. Keep security reports private as described in [SECURITY.md](SECURITY.md).

## Provenance attestation

By submitting a contribution, you attest that you authored it or have the right
to submit and redistribute it under compatible terms. Declare adapted source,
retain required notices, and identify its immutable upstream revision. Do not
submit decompiled output, extracted binary resources, unlicensed artwork,
private-data dumps, credentials, or signing material.

The pull-request template requires this attestation, and
`npm run provenance:scan` enforces the mechanical part of the policy.

## Local workflow

```sh
npm ci
npm run provenance:scan
npm run typecheck
npm test
npm run build
npm run swift:test
npm run swift:build
npm run pack:verify
```

`npm run verify` runs the full sequence. See
[Local development](docs/LOCAL_DEVELOPMENT.md) for native fixtures, permission
testing, and MCP Inspector.

## Change requirements

- Add or update tests for success, denial, stale target, timeout, cancellation,
  and disconnect behavior where applicable.
- Never log screenshot bytes, accessibility values from secure fields, typed
  text, clipboard data, capability tokens, or raw prompts.
- Keep stdout reserved for MCP JSON-RPC in the stdio process; diagnostics belong
  on stderr.
- Use public macOS APIs. A proposal involving private API research requires
  maintainer and security review before code is written.
- Update protocol schemas and `docs/PROTOCOL.md` together. Breaking bridge or
  tool changes require a version decision.
- Update `PRIVACY.md`, the threat model, and audit tests when data collection or
  retention changes.
- Pin GitHub Actions to a full commit SHA and let Dependabot propose updates.
- Do not add runtime network access without a threat-model update and explicit
  user control.

## Pull requests

Keep changes small enough to audit. Explain the user-visible behavior, security
impact, evidence, and rollback. Include screenshots only when they contain
synthetic fixture content and no personal data. All required checks must pass;
maintainers do not merge around provenance, test, dependency-review, CodeQL, or
SBOM failures.

Contributors retain copyright in their contributions and license them under the
project's Apache-2.0 license. A separate contributor license agreement is not
currently required.
