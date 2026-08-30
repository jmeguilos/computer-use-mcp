# Audit log

The audit log answers **who requested what class of action against which opaque
target, when, and with what policy result**. It is not a session recording.

## Location and protection

```text
~/Library/Application Support/ComputerUseMCP/audit/events.jsonl
```

The parent directory is mode `0700` and the file is mode `0600`. Each line is an
independent JSON event. Writes are atomic under a process lock, and retention is
applied on append. A malformed or insecure audit path is an error; the host does
not silently fall back to a world-readable location.

## Default retention

- maximum age: 7 days;
- maximum entries: 10,000; and
- whichever limit removes an event first wins.

Future configuration may shorten or disable retention. Increasing retention or
exporting logs requires a privacy review and explicit user control.

## Event model

An event contains:

- event timestamp and random event ID;
- opaque connection and request IDs;
- normalized action class, not its sensitive value;
- risk tier and allowed/denied/failed/canceled result;
- stable reason code when applicable; and
- target identifiers plus salted hashes and character counts for selected
  metadata.

Window titles and bundle identifiers are represented by salted SHA-256 digests
and lengths when recorded. The salt is local. Hashes support same-installation
correlation; they are not proof that low-entropy names cannot be guessed by a
local attacker.

## Data that must never be logged

- screenshot/image bytes or OCR output;
- complete Accessibility trees or element values;
- text passed to type, paste, set-value, or select-text tools;
- previous clipboard contents or the value written to the clipboard;
- MCP prompts, model responses, or full tool arguments;
- connection capability/bootstrap tokens, grant credentials, integrity-protected
  elicitation state, or approval request IDs;
- code-signing secrets, private keys, or notarization credentials.

Errors exposed to the client follow the same rule. Tests must assert redaction
with canary secrets.

## Audit integrity limits

The alpha log is local accountability metadata, not an append-only forensic
ledger. A process running as the same user may delete it, and a compromised host
can forge it. File permissions protect against other unprivileged users, while
checksums/SBOM/provenance protect the distributed build; neither turns runtime
events into non-repudiable evidence.

Do not upload the log automatically. A user may inspect it locally and choose to
share a minimal sanitized subset for support. See [PRIVACY.md](../PRIVACY.md) and
[SECURITY.md](../SECURITY.md) before sharing diagnostics.
