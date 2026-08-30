# Third-party notices

The `v0.1.0-alpha.1` source tree does not vendor third-party source code,
applications, executable binaries, UI artwork, cursor artwork, or extracted
assets.

Package-manager dependencies are resolved from their upstream registries and
remain under their respective licenses. Their exact versions and licenses are
recorded by the lockfile and the release SBOM; they are not relicensed by this
project. Development tooling currently includes transitive MPL-2.0 components
from Lightning CSS and the CC-BY-3.0 SPDX exception data package; their complete
license and attribution files remain in their distributed packages. Run
`npm run sbom` to generate the current machine-readable inventory.

Before adding vendored material, a contributor must:

1. document its origin, version, purpose, and license here;
2. retain every required copyright and attribution notice;
3. confirm that redistribution is allowed;
4. isolate it from first-party code in an unmistakably named directory; and
5. update the SBOM and provenance policy exception in the same pull request.

No such exception exists in this release.
