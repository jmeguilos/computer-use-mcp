# Required repository settings

Workflow files cannot enforce branch protection by themselves. A repository
administrator must apply these controls before accepting outside contributions
or publishing a release.

## Default branch rules

Protect `main` and require:

- pull requests with at least one approving review;
- dismissal of stale approvals after new commits;
- review by Code Owners for security-boundary paths when CODEOWNERS is present;
- conversation resolution;
- signed commits when the maintainer's workflow supports them;
- linear history;
- branches to be current before merge;
- no force pushes and no deletion; and
- administrator enforcement with no routine bypass.

Require these checks by their stable job names:

- `CI / Provenance and Node`
- `CI / Native macOS`
- `CI / Package boundary`
- `CI / Minimum Node 20`
- `Dependency review / Dependency review`
- `CodeQL / Analyze (javascript-typescript)`
- `CodeQL / Analyze (swift)` when Swift extraction is available
- `SBOM / Generate SBOM`

If GitHub renders a matrix check name differently, select the actual successful
check from a pull request. Do not remove a gate merely because it is slow or
requires a macOS runner.

`Dependency review` runs for both pull requests and pushes to `main`. Pull
requests compare their full base/head SHAs; mainline pushes compare the full
before/head SHAs. The release workflows additionally query Actions history and
require a successful `Dependency review` push workflow whose `head_sha` is the
exact release commit, so the branch rule's pull-request check is not treated as
tag evidence.

## Security features

Enable:

- private vulnerability reporting;
- dependency graph and Dependabot alerts;
- Dependabot security updates;
- secret scanning and push protection where available;
- code scanning with the checked-in CodeQL workflow; and
- repository release immutability before any public tag is pushed; and
- artifact attestations for public releases.

The dependency-review workflow is supported on public repositories. If the
repository becomes private, confirm the account has the GitHub security features
required by that action before relying on it.

## Actions policy

- Allow only actions required by checked-in workflows.
- Require actions to be pinned to a full 40-character commit SHA.
- Keep `GITHUB_TOKEN` permissions read-only by default and grant write/OIDC only
  in the release job that needs them.
- Require approval for first-time outside contributors.
- Do not expose release or signing secrets to pull-request workflows.
- Enable Dependabot updates for npm, Swift when supported, and GitHub Actions.

## Environments and variables

Create a protected `source-release` environment for GitHub release publication.
Add `RELEASE_ADMIN_READ_TOKEN` to that environment using a fine-grained token
limited to this repository with read-only **Administration** permission. It is
used only for the fail-closed immutability preflight; never substitute a broad
personal or organization token.
Create `macos-signing` only when binary distribution has completed separate
security/legal review, with required reviewers and no self-approval.

Leave `ENABLE_SIGNED_MACOS_RELEASE` unset or `false`. Do not create signing
secrets for `v0.1.0-alpha.1`. Before the first push to `main`, store the required
nonempty JSON array of private provenance deny terms in the repository secret
`PROVENANCE_DENY_TERMS`; never print its value. Protected main, SBOM, and release
gates fail closed when this secret is missing or empty. Untrusted pull-request
runs do not receive or require the secret.

Set `ALPHA_MANUAL_ACCEPTANCE_SHA` only after the interactive matrix in
[`tests/MANUAL_ACCEPTANCE.md`](../tests/MANUAL_ACCEPTANCE.md) passes against that
exact full commit SHA. Clear or replace it after every source change.

## Tags

Protect `v*` tags from update and deletion. A release tag points to an already
reviewed commit on `main` and is never moved after publication.
