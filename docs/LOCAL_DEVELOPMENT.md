# Local development

## Toolchains

- Node.js 20 or later; release jobs use a maintained LTS and CI separately tests
  the final Node.js 20 release
- npm with the committed lockfile
- macOS 14.4 or later
- Swift 6 toolchain from full Xcode 16 or later, with source compatibility kept
  at Swift language mode 5 where declared. Standalone Command Line Tools can
  compile the package but cannot be trusted to execute its Swift Testing suite.

Runtime dependencies must remain minimal. Do not add a package merely to avoid a
small standard-library implementation, especially in authentication, canonical
JSON, audit, or file-permission code.

## Bootstrap

```sh
npm ci
npm run build
npm run swift:build
```

The workspace contains:

- `packages/protocol`: shared TypeScript bridge contracts and canonicalization;
- `packages/mcp`: stdio MCP adapter and tests;
- `apps/macos-host`: SwiftPM native host, core library, app, fixture, and tests;
- `tests`: cross-process and packaging tests; and
- `evals`: deterministic, synthetic safety/behavior cases.

## Fast feedback

```sh
npm run typecheck
npm test
npm run build
npm run swift:test
```

The native test command fails unless SwiftPM discovers and executes at least 44
tests. It also rejects a Command Line Tools-only developer directory because
that configuration can compile the test bundle, run zero tests, and still exit
successfully.

Run the full gate before a pull request:

```sh
npm run verify
```

That includes provenance, TypeScript checks, native tests/build, and a real
`npm pack` inspection. It does not publish anything.

## Native fixture

```sh
bash apps/macos-host/Scripts/run-fixture.sh
```

The script assembles and ad-hoc signs the fixture as an app bundle so it has a
stable bundle identity and ordinary AppKit lifecycle. The fixture is the only
acceptable default target for integration tests that
exercise Screen Recording or Accessibility. It uses synthetic labels and values
and exposes deterministic Primary and Inspector windows. Tests must never select
an arbitrary frontmost user window.

Native unit tests should inject clocks, target inventories, permission state,
event sinks, and audit stores. A unit-test failure must not post a real input
event. UI/integration tests that do post events require an explicit environment
opt-in and must verify the fixture's bundle identity first.

## Run the MCP server directly

```sh
node packages/mcp/dist/index.js
```

The process will wait for MCP JSON-RPC on stdin. Silence is normal. Never use
`console.log` in the stdio server or any imported module; a single non-protocol
line corrupts the connection. Use stderr through the project's redacting logger.

For an isolated host socket during development:

```sh
export COMPUTER_USE_MCP_SOCKET_PATH="$(mktemp -d)/host.sock"
```

Use the same value for host and signed helper. The parent directory must be
private to the user. Do not use `/tmp/host.sock`, a checked-in path, a shared
directory, or a network filesystem.

The release architecture never lets Node connect directly to the host socket. A
direct adapter transport may be enabled only by an explicit test/development
configuration in an isolated fixture environment. It must fail closed when the
switch is absent, and any build using it is release-ineligible.

## MCP Inspector

After building and starting the native host:

```sh
npx --yes @modelcontextprotocol/inspector@2.4.0 \
  node "$PWD/packages/mcp/dist/index.js"
```

The Inspector is a development client, not the native permission surface. Access
and risk approvals still occur in Computer Use MCP Host. Do not enable the
Inspector's broad tool auto-approval while testing action policy.

## Test matrix

Every target/action change should cover at least:

| Case | Required result |
| --- | --- |
| No TCC permissions | structured permission-required response; no prompt loop |
| Screen Recording only | observation behavior matches policy; interaction denied |
| Accessibility only | capture unavailable; no unintended global action |
| User denies target | no grant, no indicator, audit denial only |
| Observe-only grant | capture succeeds; all action/clipboard tools denied |
| Window moves/resizes | old point selector becomes stale or transforms safely |
| Target closes/relaunches | grant does not transfer to replacement window |
| Secure/protected target | denied without private fallback |
| Risk approval changed args | `APPROVAL_MISMATCH` |
| Token reuse/expiry | `APPROVAL_USED` or `APPROVAL_EXPIRED` |
| Stop during action | revoke first; outstanding action cancels |
| Client disconnect/idle | connection grants and challenges revoked |
| Locked session | capture and action fail closed |
| Multi-display scale change | deterministic transform or `STALE_FRAME` |

Use synthetic text in screenshots and audit fixtures. Never commit a captured
desktop image, real accessibility dump, application bundle, extracted resource,
or raw protocol trace containing personal data.

## Protocol changes

Update schemas on both bridge sides and `docs/PROTOCOL.md` in the same change.
Canonicalization and approval-digest tests must use shared golden values. A major
bridge mismatch must fail at hello; it must not attempt best-effort decoding.

New MCP tools need:

- strict input and output schemas with explicit limits;
- conservative MCP annotations;
- a native capability and target-scope decision;
- risk tier and approval behavior;
- audit metadata definition;
- denial, stale-target, cancellation, and timeout tests; and
- threat-model/privacy review.

## Packaging

```sh
npm run pack:verify
npm run sbom
```

The pack verifier creates an archive in a temporary directory, inspects its
contents and lifecycle scripts, and deletes it. It rejects native applications,
installers, and archives in the npm package. `npm run sbom` writes generated
manifests under `sbom/`; generated inventories are release artifacts unless a
maintainer explicitly updates the checked-in policy.

Do not run a registry publication command. The alpha's npm tarball is for local
inspection and GitHub release evidence only.

## Code style and review

- Prefer small value types, explicit actors/queues, injected side effects, and
  exhaustive enums in Swift.
- Prefer Zod strict schemas, typed errors, canonical serialization, and abortable
  operations in TypeScript.
- Bound every externally supplied string, array, image, timeout, and recursion
  depth.
- Keep secrets/content out of errors and test snapshots.
- Use `apply_patch`-sized focused changes; do not mix generated artifacts with
  security logic.
- Run `git diff --check` and inspect the staged file list before committing.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the contributor attestation and
[Releasing](RELEASING.md) for protected release steps.
