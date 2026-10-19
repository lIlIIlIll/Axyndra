# Services in a live application session

An enabled native plugin can declare a Service route. The operator must first
configure its exact package digest and finite launch grant in
`settingsRoot/plugins/lifecycle.json`; a plugin declaration is not authorization
to start a process. The service then belongs to one Thread in the current
running application. It is not a detached system daemon.

Use these commands in the persistent application's prompt:

```text
/plugins service list
/plugins service start <namespace> <service-id> <route> --approve
/plugins service stop <namespace> <service-id>
```

`namespace` selects an installed, enabled plugin. `service-id` selects an exact
operator configuration entry, and `route` selects the declared Service route.
For example, a configured MCP client package may use namespace
`axyndra:mcp-client`, service ID `stdio`, and route `session`. The command and
host interfaces are the same for any supported service plugin.

Omitting `--approve` returns `plugin.service_approval_required` without creating
an Operation or starting a process, including in Yolo mode. Review the operator
launch configuration before approving. Startup records a separate canonical
maintenance Run, its host service origin and its Receipt; it does not create a
fake user message, invoke a model or occupy the model's pending approval state.
Its limited discovery window does not authorize later service writes. Each
later tool request still requires its own canonical source and frozen intents.

List and stop operate only on the current Thread. Two Threads can own separate
instances with the same configured service ID, within the operator's instance
limit. A stopped instance may remain visible as draining until both processes
acknowledge cleanup. A cleanup-pending error retains ownership and capacity;
retry stop to observe the later acknowledgement.

Changing the active view does not move or cancel the source Thread's startup or
services. Status, stop, service close and cancel in the new view do not control
that old startup; switch back to its Thread to cancel it.

Cancel active work to interrupt a startup in progress. Stop also interrupts a
matching startup. Once publication succeeds, the old startup cancellation token
is detached: cancelling an unrelated later turn does not silently revoke an
otherwise valid active service. Explicit stop, plugin revocation, operator
configuration changes, lifetime expiry and application shutdown still close it.

Embedding frontends can use `ApplicationSession.startPluginService` with
`approved: true`, `pluginServiceStatuses`, `stopPluginService`, and
`closePluginServices`. `closePluginServices` affects only this Thread's services
and does not close a shared Product. `/exit` waits for the same bounded cleanup
acknowledgement before asking the frontend to exit; Product shutdown also owns
all retained instances. A one-shot headless invocation is not a background
service host: its services stop when that Product process closes.

The underlying wire and authority limits are documented in
[the native plugin protocol](plugin-process-protocol.md).

## Working directory and executable resolution

A lifecycle service may set `cwd` to an absolute directory or a path relative
to its selected filesystem root (the package for `isolated_readonly`, otherwise
the workspace). Omitting it preserves the root directory default. Its canonical
target must be inside that root or an explicitly granted read-only directory.
Specifying a path never adds a mount. File mounts and fixed system roots alone
do not authorize an external working directory.

An executable may be absolute, relative to this working directory, or a bare
name. Bare names search the working directory and then `/usr/local/bin`,
`/usr/bin`, `/bin`, without the host's ambient PATH. Custom toolchains should
name the executable path and explicitly grant its directory when necessary.
The selected executable must still satisfy the existing visibility, regular
file, executable permission and bounded digest checks.

The canonical cwd, authored values, selected executable and digest enter the
same frozen lifecycle launch plan and existing approval. Before the actual
handoff the host resolves the cwd and executable selection again, so a symlink
retarget, changed binary or newly shadowing local command invalidates that
grant. This is the existing path/content check at the handoff boundary, not a
claim of an atomic filesystem snapshot against concurrent changes after that
check. Credentials, process ownership, startup/refresh budgets and cleanup use
the existing lifecycle services unchanged.

## Finite long-running calls

An explicit operator `protocol_limits.call_timeout_ms` may select 1 through
3,600,000 milliseconds. The default profile remains 30 seconds. The exact
profile is frozen with the approved service launch and subsequent calls;
changing it invalidates the existing grant. A plugin cannot extend the Run,
parent cancellation deadline or service lifetime by requesting a longer wait.
Startup, refresh and pure preparation keep their separate short windows.
Ordinary Tool, Command, content and HTTP profiles keep their existing limits.

`process.channel.read` accepts `wait_ms` from 0 through 1,000. A wait returns
early on bytes, EOF, failure or cancellation; it does not authorize later reads
outside the active canonical invocation. The cumulative 8,192-request ceiling
is unchanged. Long-running protocol adapters should use longer empty-read
waits instead of consuming that ceiling with 25 ms polling. Byte and output
budgets still apply to each service and its parent Run. Closing the process
interrupts an outstanding read and releases ownership only after cleanup.

This host increment does not itself establish every plugin's legacy timeout
parity. Adapters must preserve their own business deadline policy, select a
matching explicit profile, and pass the actual long-running workflow tests.
