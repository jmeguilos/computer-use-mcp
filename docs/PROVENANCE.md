# Clean-room provenance policy

Computer Use MCP is independently authored. Behavioral compatibility is defined
from public specifications, platform documentation, user-authored requirements,
and tests written from observable inputs and outputs. Compatibility is not a
license to copy another product's implementation or visual assets.

This policy applies to code, tests, documentation, protocol descriptions,
fixtures, icons, cursor art, screenshots, build products, generated code, and
training/context material intentionally used to produce a contribution.

## Permitted inputs

- public MCP specifications and official SDK documentation;
- public Apple developer documentation and headers shipped in the selected SDK;
- official public documentation for supported MCP clients;
- original design notes, threat models, and test cases written for this project;
- behavior observed through ordinary documented product use, recorded as
  abstract requirements without copying content or implementation details; and
- third-party libraries intentionally added through a package manager when their
  license, version, and purpose are reviewed and captured in the lockfile/SBOM.

## Prohibited material

- copied or mechanically translated third-party source code without an approved
  compatible-license contribution path;
- decompiled, disassembled, class-dumped, injected, or otherwise extracted
  implementation code;
- extracted application bundles, frameworks, binaries, compiled asset catalogs,
  icons, cursor artwork, animations, screenshots, or audio;
- private SDKs, leaked documentation, credentials, signing material, crash dumps,
  or protocol captures containing another person's data;
- generated code or prose produced from prohibited material; and
- any file whose origin or redistribution rights cannot be established.

Do not commit research dumps “temporarily.” Use synthetic fixtures and abstract
notes. If a source cannot be cited publicly and reviewed safely, it is not an
acceptable implementation input.

## Independent compatibility workflow

For compatibility work, separate observation from implementation:

1. Write an issue containing only the user-visible scenario, public API
   constraints, abstract input/output behavior, and safety expectation.
2. Have implementation code written from that issue and official documentation,
   without access to non-permitted source or assets.
3. Verify with an original synthetic fixture and black-box acceptance test.
4. Record deviations explicitly; do not fill gaps by importing another product.

Pixel-identical UI replication is not a goal. The left-edge indicator uses
original layout, colors, copy, shapes, and interaction code designed for this
project.

## Third-party contributions

Every pull request must affirm:

- I authored the contribution or have the right to submit it;
- it is licensed under Apache-2.0;
- it was created only from permitted inputs above;
- no prohibited source, binary, asset, or private data is included; and
- all intentional dependencies or vendored material are disclosed.

Vendoring is exceptional. It requires advance maintainer approval, an isolated
directory, exact source/version URL, license compatibility review, retained
notices, an entry in `THIRD_PARTY_NOTICES.md`, and SBOM coverage. There are no
vendoring exceptions in `v0.1.0-alpha.1`.

## Automated gate

`node scripts/provenance-scan.mjs` scans the tracked source set and fails on:

- packaged apps/installers/archives and native executable magic;
- binary or oversized files not permitted in this source-only release;
- directories associated with vendored or extracted material;
- known credential/key markers;
- mutable GitHub Action references instead of full commit SHAs;
- registry publication commands in workflow execution steps; and
- maintainer-supplied private deny terms.

The scanner is a backstop, not a legal conclusion. Passing it does not establish
copyright ownership or clean-room authorship. Reviewers must still inspect file
origin and the pull-request attestation.

Maintainers can supply a JSON array of literal, case-insensitive deny terms in
`PROVENANCE_DENY_TERMS`. The scanner reports only affected file paths, not secret
term values. Local and untrusted pull-request scans may omit it. Protected
`main`, source-release, and signed-release jobs set
`PROVENANCE_REQUIRE_DENY_TERMS=1` and fail unless the repository secret contains
a nonempty array. This keeps private provenance terms out of the public project
without making the release gate optional.

Every tracked file is scanned, including a file forcibly committed beneath a
normally ignored dependency, build, artifact, or generated-SBOM path. Such a
tracked ignored-path file is itself a gate failure. Ignore rules apply only to
untracked local outputs.

## Suspected provenance issue

Stop redistribution and report privately through [SECURITY.md](../SECURITY.md).
Do not open a public issue containing the questionable material. Maintainers will
quarantine the affected release, preserve minimal metadata, determine removal
and notification needs, and regenerate release artifacts only from a reviewed
clean commit.
