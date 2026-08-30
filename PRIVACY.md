# Privacy

Computer Use MCP runs locally. The project itself has no hosted service,
analytics endpoint, update checker, telemetry collector, or cloud account.
Network access is not required for runtime operation.

An MCP client may send tool inputs and results—including screenshots—to the
model provider chosen by the user. That processing is controlled by the client
and provider, not this project. Review the client's data settings before granting
access to sensitive windows.

## Data handled

| Data | Why it is handled | Default persistence |
| --- | --- | --- |
| Window image | Visual state requested by the client | Memory/resource cache only; 60-second TTL |
| Accessibility tree | Semantic state and actions | Memory only |
| Typed or pasted value | Requested input action | Memory only for the action; audit records only the action class and policy metadata |
| Clipboard write | Explicit `clipboard_write` capability | Written to the system pasteboard; not copied into the audit log |
| Window identity | Target binding and revalidation | Grant lifetime; redacted audit metadata |
| Socket audit token and connection capability | Authenticate the signed native bridge and authorize local bridge calls | Memory and mode-`0600` runtime token file; never logged |
| Audit metadata | Accountability and debugging | Mode-`0600` JSON Lines, up to 7 days or 10,000 events |

The lower audit limit wins: old entries are removed when either age or count is
exceeded. Screenshot bytes, OCR text, full Accessibility values, prompt text,
typed text, clipboard contents, socket/connection capabilities,
`approval_request_id`, and elicitation `requestState` values are excluded from
audit events.

## Local paths

Runtime and audit data live under:

```text
~/Library/Application Support/ComputerUseMCP/
```

The runtime directory is mode `0700`; its socket, token, and audit files are mode
`0600`. The Unix-domain socket can be overridden for development with
`COMPUTER_USE_MCP_SOCKET_PATH`. Do not place it in a shared or world-writable
directory.

To erase project data, quit the host and all connected MCP clients, revoke any
active grant, then move the `ComputerUseMCP` directory above to Trash. Removing
that directory does not revoke macOS privacy permissions.

## macOS permissions

Screen Recording and Accessibility consent belong to macOS. View or revoke them
in **System Settings → Privacy & Security**. Revoking either permission may
require the host to be restarted before macOS reports the new state. The project
does not alter the TCC database directly.

System Screen Recording permission can technically expose more than the selected
window. The host narrows its own capture and action APIs to the approved target,
but malware running as the user or a compromised host process remains a residual
risk described in the [threat model](docs/THREAT_MODEL.md).

## User controls

- **Stop** on the left-edge indicator revokes all active access for that target.
- `computer_release_access` revokes a named grant.
- Closing or replacing the target window invalidates its grant.
- Client disconnect, lock, idle expiry, or host exit invalidates connection-bound
  grants.
- Persistent app approvals can be cleared from the host menu. They remember
  policy, not a live authority token; a new connection still
  receives a fresh bounded grant.

## Crash and diagnostic data

macOS or an MCP client may independently create crash reports or transcripts.
Those systems have their own retention rules. Sanitize diagnostics before
sharing them: even when this project's audit log is redacted, process names,
window titles, file paths, and client prompts can be sensitive.

Privacy regressions are security issues. Report them privately using
[SECURITY.md](SECURITY.md).
