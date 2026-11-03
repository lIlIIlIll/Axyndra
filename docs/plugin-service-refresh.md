# Explicit service directory refresh

A running service can refresh its directory through
`ProductRuntime.refreshPluginService(targetThread, namespace, serviceId,
approvalDecision: Approve)`. This is a persistent Product API; it is not a
detached command that exits while claiming a background service is ready.
The service must already be active in the same Thread and host permission
domain. A new Run on the endpoint's original host maintenance Thread carries a
real `HostServiceAction.Refresh` SystemNote and canonical ToolCall. That Thread
must be idle; its Runtime enforces this before admitting another Run. The target
user Thread remains separate. No UserMessage or ModelDecision is invented.

An operator must explicitly add a refresh window to the configured service in
`settingsRoot/plugins/lifecycle.json`:

```json
"refresh": {
  "timeout_ms": 10000,
  "max_input_bytes": 16384,
  "max_output_bytes": 65536,
  "max_writes": 8
}
```

Absent `refresh` means refresh is denied. Values must be positive, fit the
service lifetime and cumulative input/output grants, and obey the host resource
ceiling. Timeout is at most 60000 ms and writes at most 256. This conservative
external-effect window authorizes bounded discovery traffic, not an assertion
that the backend protocol is read-only. Business tool calls continue to require
their own exact frozen byte intents and child Operations.

The independent MCP client also requires a validated nonsecret configuration:

```json
"configuration": {
  "version": 1,
  "transport": "stdio",
  "request_timeout_ms": 10000,
  "directory": {"max_pages": 8, "max_tools": 64}
}
```

The plugin rejects unknown fields or unsupported values before writing an MCP
frame. This object cannot introduce credentials, commands, environment values,
network authority or host identity. The whole lifecycle file digest remains part
of the launch grant. Editing it revokes the old service; starting with changed
configuration requires a new explicit approval.

Refresh serializes with active tool preparation/execution. The host freezes the
existing endpoint, lease, launch digest, directory revision/digest and refresh
window into the approved plan. Reads and writes validate the actual live Run,
epoch, canonical Item, executing Operation, handoff and host-origin audit in the
same existing SQLite facts. The temporary observer closes when discovery ends;
no idle callback retains startup authority. Total lease resource accounting is
never reset by refresh.

Only a completed maintenance Run with the exact committed ToolResult can publish
the candidate. Publication uses the same catalog owner and compare-and-swap
revision. The entire new directory is validated first, including an empty
directory. Existing Prepared invocations retain their previous descriptor and
explicitly fail as stale; they never resolve to a different executor. If discovery
fails after I/O, the root remains Unknown and the whole service is revoked. If
discovery succeeds but catalog CAS fails, its successful execution Receipt is
retained, `plugin.lifecycle_refresh_publication_failed` reports that publication
did not occur, and the service is withdrawn to avoid a plugin/host directory
mismatch. Cleanup ownership remains until actual process-close acknowledgement.

This implementation updates catalog snapshots for new Runs. It does not yet replace
an already active Core Run's ModelLane/ToolInvocationContext at the canonical
safe cut point required by issue #39. That integration must update the same
durable lane and context path after any previous tool round completes and before
the next model effect. It must preserve the budget/token and every old Prepared
snapshot. Explicit refresh alone does not complete that requirement.
