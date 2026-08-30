# Security policy

Computer Use MCP can observe pixels and accessibility metadata and can generate
input in applications the user selects. Treat vulnerabilities in its grant,
target-validation, transport, audit, capture, input, or indicator boundaries as
high impact.

## Supported versions

Only the newest tagged release is eligible for security fixes. During the alpha
period, fixes may require an immediate upgrade and may include breaking protocol
or configuration changes.

| Version | Supported |
| --- | --- |
| `0.1.0-alpha.1` | Yes |
| Earlier snapshots | No |

## Report a vulnerability privately

Use GitHub's **Security → Report a vulnerability** flow for
`jmeguilos/computer-use-mcp`. If private vulnerability reporting is not
available, email the security contact listed in the repository owner's GitHub
profile and ask for a private channel. Do not include exploit details in a
public issue, discussion, pull request, log, screenshot, or MCP transcript.

Include, when safe:

- the affected commit or version and macOS version;
- the MCP client and exact transport configuration;
- whether Screen Recording or Accessibility was granted;
- the expected target window and the window actually affected;
- minimal reproduction steps and sanitized diagnostics from `doctor`;
- impact, including whether access survives Stop, disconnect, lock, or expiry;
- any proposed mitigation.

Do not attach real screenshots, typed secrets, clipboard contents, audit logs,
or capability tokens. A synthetic reproduction using
`computer-use-mcp-fixture` is preferred.

## Response targets

Maintainers aim to acknowledge a complete report within 3 business days,
provide an initial assessment within 7 business days, and coordinate a fix and
disclosure timeline based on severity. These are targets, not a service-level
agreement.

## Safe-harbor scope

Good-faith research is welcome when it:

- uses systems and accounts you own or have explicit permission to test;
- minimizes collection and immediately deletes inadvertently captured data;
- avoids persistence, lateral movement, denial of service, and social
  engineering;
- stops after demonstrating the issue and reports it privately;
- does not weaken another user's TCC settings or bypass macOS security controls.

This policy cannot authorize testing against third-party systems or waive their
terms. We will not pursue legal action for research that follows this policy,
subject to applicable law.

## Security design

The intended invariants, residual risks, and trust boundaries are documented in
the [threat model](docs/THREAT_MODEL.md). Security-sensitive changes require
tests for denial paths as well as success paths and must pass the mandatory
checks described in [repository settings](docs/REPOSITORY_SETTINGS.md).
