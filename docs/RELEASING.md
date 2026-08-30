# Releasing

## Alpha distribution contract

`v0.1.0-alpha.1` is source-only:

- GitHub supplies the canonical source archives;
- CI may attach an inspectable npm pack tarball containing the JavaScript runtime
  and notices, but does not publish it to the npm registry;
- CI attaches checksums, SBOMs, and build provenance;
- no `.app`, `.dmg`, `.pkg`, `.xcodearchive`, or native executable is attached;
- users build the native host locally; and
- Developer ID signing, hardened runtime, and notarization are disabled by
  default.

Do not describe this alpha as notarized, production-ready, unattended, or safe
for sensitive workflows.

## Required repository controls

Before tagging, configure the branch rules in
[Repository settings](REPOSITORY_SETTINGS.md). All required checks must pass on
the exact commit, and an administrator must verify that repository release
immutability is enabled. Releases must be created by GitHub Actions from a
protected tag, not from a maintainer laptop. Store a fine-grained token limited
to this repository with read-only **Administration** permission as the protected
`source-release` environment secret `RELEASE_ADMIN_READ_TOKEN`. The workflow
uses it only to verify that release immutability is enabled before it creates a
release, then independently checks the published release's immutable status.

Complete the interactive matrix in [Manual acceptance](../tests/MANUAL_ACCEPTANCE.md)
from the exact commit, then set `ALPHA_MANUAL_ACCEPTANCE_SHA` to that full commit
SHA. The release workflow rejects a tag whose commit does not equal the recorded
value.

## Version checklist

The following must agree:

- root workspace version;
- `@jmeguilos/computer-use-mcp` version;
- bridge/tool protocol compatibility declarations;
- Apple-compliant native bundle short version/build number and the bundle's
  full `ComputerUseMCPReleaseVersion` prerelease string;
- README/SECURITY supported version;
- changelog or release notes; and
- tag `v0.1.0-alpha.1`.

For this release, the npm manifest version is exactly `0.1.0-alpha.1`.

## Pre-tag verification

From a clean checkout:

```sh
npm ci
npm run verify
npm run sbom
git status --short
```

Review:

- all tests and negative safety cases;
- `npm pack --workspace @jmeguilos/computer-use-mcp --dry-run --json`;
- the real `npm run pack:verify` archive listing;
- generated SBOM package names, versions, licenses, and unexpected binaries;
- `THIRD_PARTY_NOTICES.md` against the lockfiles;
- action SHAs and Dependabot/dependency-review results;
- `node scripts/provenance-scan.mjs`; and
- source archive contents from `git ls-files`, not the working directory.

Generated SBOM files may remain untracked locally; release automation regenerates
them from the tagged checkout.

## Source release workflow

Pushing the protected tag triggers `.github/workflows/release-source.yml`. It:

1. checks out the exact tag with no persisted credentials;
2. installs locked dependencies;
3. reruns provenance, TypeScript, native, packaging, and source-only checks;
4. runs `npm pack` and verifies that the archive contains no native bundle or
   install lifecycle script;
5. creates SPDX/CycloneDX SBOMs and SHA-256 checksums;
6. creates GitHub build attestations for generated assets; and
7. verifies repository release immutability through a read-only administration
   token before creating any release; and
8. creates a draft prerelease, attaches every source artifact, and only then
   publishes it so repository release immutability can lock the tag and assets.

There is intentionally no registry publication step and no registry token.
Maintainers must not add such a token to this workflow or repository for the
alpha.

## Signed macOS workflow

`.github/workflows/release-macos-signed.yml` is a future distribution scaffold.
It is manual-only and its job runs only when all of the following are true:

- the operator explicitly enables the dispatch input;
- repository variable `ENABLE_SIGNED_MACOS_RELEASE` equals `true`;
- the protected `macos-signing` environment approves the run;
- Developer ID certificate/keychain, team ID, Apple ID, and app-specific password
  secrets exist;
- the source revision already passed mandatory CI; and
- hardened-runtime entitlements, signature verification, notarization, stapling,
  Gatekeeper assessment, SBOM, checksum, and attestation all succeed.

The variable is unset/false by default, secrets are not required for normal CI,
and the workflow cannot fall back to an ad-hoc or unsigned public artifact. Until
a separate reviewed release enables that path, source release notes must state
that no signed/notarized binary is available.

## Recovery

If a release gate, provenance fact, dependency, signature, or artifact is wrong:

1. stop the workflow and do not reuse a failed artifact;
2. mark the GitHub release as withdrawn or delete only the erroneous draft asset;
3. notify users without publishing sensitive exploit/provenance material;
4. fix the source in a reviewed pull request;
5. issue a new version/tag rather than moving a public tag; and
6. regenerate SBOM, checksums, attestations, and release notes from the new commit.

Never overwrite an immutable public release asset with different bytes under the
same name.
