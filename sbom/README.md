# Software bill of materials

Computer Use MCP generates SBOMs from the exact locked source checkout used for
CI or a release. Generated inventories are artifacts, not hand-maintained source
files.

## Local generation

```sh
npm ci
npm run sbom
```

The command writes:

- `npm.cdx.json`: CycloneDX 1.6 inventory for the npm workspace, produced by the
  exact locked `@cyclonedx/cyclonedx-npm` development dependency; and
- `swift-dependencies.json`: SwiftPM's resolved dependency graph.

CI additionally creates a repository-wide SPDX JSON document using the pinned
SBOM action. Release workflows publish both formats with SHA-256 checksums and
GitHub build attestations.

## Review expectations

An SBOM gate fails or blocks release when it reveals:

- a dependency absent from reviewed manifests/lockfiles;
- an unknown, forbidden, or incompatible license;
- a packaged native app, executable, installer, archive, or extracted asset;
- an unexpected network/runtime dependency;
- mutable or missing version provenance; or
- a known vulnerability prohibited by dependency review policy.

An SBOM describes included components; it does not prove that a build is safe or
that every license conclusion is correct. Review it together with the lockfiles,
`THIRD_PARTY_NOTICES.md`, dependency review, CodeQL, source-only pack check, and
`scripts/provenance-scan.mjs`.

## Release naming

Release assets use versioned names and are never overwritten in place. The
source-only `v0.1.0-alpha.1` release must not include a macOS application bundle
or native executable in an SBOM subject archive. A future signed/notarized native
release requires its own SBOM and provenance attestation for the exact stapled
artifact.
