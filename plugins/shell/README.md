# Independent Shell plugin — migration in progress

The native endpoint owns the Shell contribution and uses the public managed
process-channel protocol. Its Python backend owns command validation, Bash
session state, PTY handling and command output. The trusted host still owns
canonical sources, exact prepared writes, approval, namespace isolation,
budgets, revocation and final resource cleanup. Discovery starts no shell.

Build with `bash plugins/shell/build-package.sh --output NEW_DIRECTORY`.
The package includes its native executable, runtime closure, licenses and
Python backend. Python 3 and Bash are explicit optional dependencies. The
Minimal host does not need either dependency for this plugin's absence.

After import and enable, configure the `session` Service with the installed
backend path and `/usr/bin/python3 -u`, plus `--workspace` and the approved
workspace root. Bind the installed package digest and explicit read-only
mount for the backend. Default denied networking uses a persistent shell;
use `--oneshot` for an explicitly network-enabled configuration. The operator's
filesystem/network sandbox remains authoritative. A normal writable shell
requires the `workspace_readwrite` grant. A read-only instance additionally
uses `--readonly`, a read-only backend filesystem and denied networking.
Only the operator's explicit `read_only_tools` entry can classify
`bash_readonly` as read-only; backend metadata does not grant permission.

An explicit long-call protocol profile and matching
`{"version":1,"request_timeout_ms":610000}` allow the 0..600 second command
timeout policy (`0` selects 600 seconds). The host's parent Run/cancellation
deadline and service lifetime still bound the call. Empty process reads use
the supported 1,000 ms wait without increasing the host's total RPC quota.
Directory refresh keeps the Host's separate 25 ms bound; the native window
selects that bound only while an actual refresh owns the channel.
Persistent calls retain environment, functions and cwd within this one
instance. PTY calls are isolated one-shot commands. Stdin for a user command
is EOF so it cannot consume the persistent shell's completion script.

This candidate is unfinished. Its backend business tests do not prove native
protocol, real Product/SQLite approval, sandbox or recovery. The 1.1.0 endpoint declares
`supports_preparation_reference: true` and requests the existing host Task
runtime for `async: true`; it requires the corresponding managed-job host
increment. Its pure preparation still performs no backend I/O. The initial endpoint has 16 KiB input
and 64 KiB result bounds, with a bounded 24 KiB combined output preview. Complete
large-output/artifact parity, validated async lifecycle, installation/Product tests,
default distribution and deletion of the old built-in Shell path remain
required before A4-02 can be marked complete.

The subsequent output candidate adds the explicit backend `--stream-output`
option. Output larger than 4 KiB is sent as bounded UTF-8 chunks through the
native endpoint to the host's current-invocation `output.artifact` service. The
host returns the immutable reference; the backend cannot choose one. The final
Shell result carries small previews and full artifact descriptors. The native
endpoint validates the stream identity, ordering, length and host digest, and
an incomplete transfer produces Unknown. Empty stderr polls wait locally so
they cannot block stdout or artifact requests in the host's synchronous service
callback loop.

The backend's 15 actual tests cover complete 3 MB UTF-8 streaming and escaped
control characters. Native protocol and actual Product/SQLite/GC tests for this
increment are authored but not yet run. The original process-channel output
ceiling still includes protocol framing: a full 16 MiB of semantic output has
not been established. Input capacity, complete legacy artifact parity and runtime validation of async
remain unfinished; this option does not complete A4-02.


For asynchronous execution, the host freezes the original command bytes, tool,
input, service binding, child identity, deadline and budget in the approved
plan. The launch requires `Delegate` in addition to the command's original
capabilities and effect policy, and the product's async setting must be enabled.
Approval rejection creates no background Task and writes no command. A launch
result describes a queued Task; it does not claim command completion.

The same native endpoint consumes a host-bound reference to the original
Thread/Run/epoch/call preparation. The actual invocation has the child Task's
identity and its own canonical Operation and Receipt. The backend receives the
original frozen request with `async: false`: it remains synchronous within the
host-owned Task and cannot detach itself. Normal foreground completion leaves
the Task alive. Actual cancellation or service revocation terminates its owned
process tree. Unknown effects retain their budget even after process cleanup
is acknowledged, and restored journals cannot replay the command.

One running managed job reserves this service instance until execution and
cleanup settle. Other calls and refreshes on that instance are refused while
it is reserved; another Thread uses a separate service instance. This does not
add concurrent commands to one persistent Bash interpreter.

The managed-job increment contains six Product/SQLite cases, three native host
declaration/handshake cases and fourteen packaged protocol cases (including
the prior synchronous/artifact cases). They are authored, not yet executed.
See [managed service jobs](../../docs/plugin-managed-jobs.md). The old built-in
Shell path remains until the combined real-runtime parity checks pass.

The bounded artifact transport can use the Host writer's existing 16 KiB UTF-8
append limit. Canonical Base64 is retained across both wire hops for escaped
control characters, so a chunk stays below the original physical frame and
service-argument limits. Native identity, exact byte offsets, complete SHA-256,
the 16 MiB total, service quota and call timeout are unchanged. This increment
still requires the original complete Product ASCII/NUL artifact and next-call
test; a smaller package protocol case does not establish that capacity.


The compact-read increment explicitly requests `encoding: "base64"` on
`process.channel.read`. It requires a host that implements this optional field.
The result has only `bytes_base64` and `eof`; omitted encoding and explicit
`"hex"` retain the existing `bytes_hex` response, including HTTP stream reads.
Each Base64 channel read is bounded to 32 KiB decoded (43692 encoded bytes);
hex retains its 16 KiB decoded cap. The original 64 KiB IPC limit and 16 KiB
artifact append limit remain unchanged. Empty data represents a quiet
poll or EOF according to the separate `eof` flag. Canonical Base64 is decoded
as bytes, so a read can split UTF-8 or contain non-text data; full JSON frames
and artifact text still undergo their existing strict UTF-8 validation.

Encoding does not change the service's approved process, source, write intent,
Root/child Receipt checks, read windows, raw stdout/stderr meter, secret filter,
aggregate output ceiling or deadline. Invalid encodings and unknown fields are
rejected before a pipe read. Secrets are withheld before representation is
chosen. This increment adds five real Product/SQLite/OS cases, two native decoder
cases and two actual packaged-backend protocol cases. They are authored and
unrun until the formal fresh-package and Product gates execute. It does not
establish the original full 16 MiB ASCII/NUL artifact performance requirement.

The refresh-poll companion adds one packaged real-backend protocol case for
Base64 discovery reads, original 25 ms refresh bounds, invalidation of the old
prepared call, one successful newly prepared command and changed-configuration
rejection without new I/O. It is authored and unrun; normal call/startup limits
and every Host permission check are unchanged.


The representation-cap companion adds one actual Product raw-pipe case for a
queued 32 KiB binary chunk, byte identity, the original raw meter, bounded JSON
representation, EOF and close acknowledgment. Decoder and protocol negative
cases reject 32769 decoded channel bytes; artifact negatives retain their
16384-byte bound. All original 16 MiB ASCII/NUL acceptance tests and 60-second
call deadlines are retained. This candidate is authored and unrun until the
fresh native and Product gates execute.
