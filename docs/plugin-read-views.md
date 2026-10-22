# Ordinary Tool read views

Ordinary installed Workspace contributions use this prepared-only path. Completing
the full Workspace acceptance matrix remains separate from representation limits.

An ordinary native Tool package requests `process.readview`. Its pure `prepare`
invocation receives `{input}` and returns one proposed intent:

```json
{"intents":[{"id":"query","request":{"executable":"bin/worker","arguments":["query"],"timeout_ms":30000},"resources":[{"source":"notes.txt","path":"target","mode":"file"}]}]}
```

Resource modes are `file`, `directory`, `auto`, and `optional_file`. The last
mode supports a create proposal only when the workspace parent already exists;
it exposes an empty destination for a missing file, not its parent's contents.
At most 32 authored roots expand to 1,024 total entries, depth 32 and 16 MiB of
regular-file content. The worker request has at most 128 arguments and 64 KiB
of argument text, a package-relative executable and a 1–60,000 ms timeout.
Pure preparation keeps its existing input, timeout and zero-host-service limits.

Preparation is not content-read permission. Product resolves and classifies
resources using actual Run capabilities, enumerates directories through verified
handles, and freezes physical identities, file sizes, permission classes,
package digest, generation, contribution, exact operator Tool payload profile and
the current operator-file digest.
No descriptor grant, metadata DTO, plugin assertion or model tool name replaces
canonical runtime Source authority. The host-generated parent envelope is
`{input,host_plan}` with version `read-view-intents/v2`.

An operator can select `configuration.tool_payload_limits` for the exact installed
`read` contribution. The ordinary profile is frozen before pure preparation and
copied into both parent and Derived plans. Workspace includes that exact profile
in its private worker argv, rather than accepting a model-authored result limit.
Changed profiles, package/configuration digests or generations reject the prepared
call instead of refilling its limits. Without a profile the 64 KiB read result
and UTF-8-safe truncation behavior remain unchanged.

For a 1 MiB raw page, set the existing ordinary profile fields to
`schema:axyndra.ordinary-tool-payload/v1`, `contribution:read`,
`max_input_bytes:2097152`, `max_result_bytes:1114112`,
`max_service_response_bytes:1114112`, and `max_message_bytes:2162688`.
The service bound also includes the escaped worker stdout and receipt envelope.
Dense control characters can therefore return fewer bytes than ASCII under the
same explicit profile, with `truncated:true`. Existing process-output ceilings
can narrow this representation further. The profile grants no additional read,
process-spawn, filesystem-write or network capability.

Large native invocation, service-response and reply JSON uses the shared funded
logical payload protocol with 16 KiB chunks and bounded physical frames. Exact
window identity, sequencing, digest, decoded-node and escaped-copy accounting
apply before allocation; cancellation clears the pending transfer.

At execution, the plugin requests only `process.readview({intent_id})`, with
request ID equal to the intent ID. The existing broker prepares and admits
`host.process.readview` as one exact, single-level derived operation. Existing
ParentIntent audit, active Run/Thread/epoch, committed or sealed Direct root,
parent execution handoff and immutable full-plan checks run again at child
admission, execution and handoff. Request identity cannot mint a second child.
The child is ReadOnly, Denied network, NeverReplay and requires only the exact
frozen WorkspaceRead resources. It has its own real Receipt.

After handoff, the executor rechecks the current grant, package and generation,
resource class/capability and native object identity. It opens with Linux
`openat2` no-symlink/no-magic-link resolution; it refuses non-regular objects and
multiply-linked regular files. Copy checks file metadata before and after and
requires the prepared byte count. It creates private non-executable copies.
The worker uses the shared Product process owner and bounded parent limits,
mounting only the snapshot and installed package. Cwd is the snapshot; ambient
environment, original workspace, SDK mounts and host networking are absent.
There is no Shell registration dependency. Host code does not implement read
formatting, regex, glob, hashline or edit algorithms.

The frozen directory list is a snapshot selection: newly added files do not enter
it. Each selected descendant must still have its frozen identity. Directory
traversal excludes existing sensitive-path policy plus `.env.*`, Product
settings/state roots, `.axyndra`, VCS internals and credential directories.
Plugin glob flags cannot opt them in. Explicit special regular files require
approval; special directory traversal is refused. Symlink and hardlink behavior
is deliberately more restrictive than legacy reads and remains a parity gap.

Cancellation, deadline, package disable and operator-file changes stop the
worker. Native cleanup must acknowledge release before private view deletion;
failed cleanup retains a bounded owner and capacity for retry, including host
close. No more than eight active or retained views exist per Product. Regular
filesystem metadata and copy syscalls are synchronous: byte/file/depth bounds
are enforced, but no guarantee is claimed against a kernel-stalled filesystem.

## Operator grants and approval

The existing `settingsRoot/plugins/services.json` remains the single source.
An exact installed package may additionally define ordinary Tool grants:

```json
{
  "version": 1,
  "plugins": [{
    "namespace": "axyndra:workspace",
    "package_digest": "sha256:<actual installed package digest>",
    "configuration": {}, "requests": [], "credentials": [],
    "tool_read_grants": [
      {"kind":"tool","name":"read","effect":"read_only","services":["process.readview"]},
      {"kind":"tool","name":"grep","effect":"read_only","services":["process.readview"]},
      {"kind":"tool","name":"glob","effect":"read_only","services":["process.readview"]}
    ]
  }]
}
```

Names, kind, effect and service list are exact and bounded. Unknown fields,
duplicates and kind `service` are invalid. Dynamic Service `read_only_tools`
never authorizes an ordinary Tool. An absent matching package entry is an error;
an entry with empty grants preserves explicit root approval. Updating package,
generation, contribution or configuration invalidates old prepared calls.

| Context | Ordinary approved workspace view | Explicit sensitive/outside/temp file |
| --- | --- | --- |
| AlwaysAsk, exact operator read grant | ReadOnly; no root prompt | One-time exact root approval; zero child before approval |
| AlwaysAsk, no exact grant | Root approval required | Root approval required |
| Write | Existing ExtensionInvoke prompt remains | Existing ExtensionInvoke prompt remains |
| Yolo | Existing context policy permits execution within capability ceiling | Existing context policy permits execution within capability ceiling |

Write-mode parity needs a separate host-held preauthorization proof. This
change does not skip policy based on descriptive plan fields or a plugin hint.
The product's `allow_workspace_writes` default only covers low-risk workspace
writes; it does not permit sensitive reads or extension execution.

A read-granted contribution may call only `process.readview`. UI, exec,
whole-workspace `process.readonly`, network and `file.plan.propose` requests are
rejected before child admission. An ungranted edit/write contribution can use
`file.plan.propose` under its original broad WorkspaceRead capability and exact
root approval. The primitive keeps its existing descriptor; a narrow read grant
cannot upgrade itself. Applying the immutable proposal still uses the original
`apply_file_plan` approval, durable origin proof and atomic expected-content CAS.
No direct worker writes or second pending-plan database are introduced.

## Remaining scope and validation

Workspace results still have 16 KiB input and 64 KiB result/proposal limits,
versus the separately measured legacy full 1 MiB raw read and 32 KiB write.
URI/Blob reads and exports, remote writes, large payloads, large directory
selection, Write-mode prompt parity and all old entry deletion remain open.
The new generic primitive does not automatically tighten other packages already
using the old broad `process.readonly` service.

The candidate contains 34 independent Workspace process cases, 3 retained
Workspace Product cases, 9 new Product read-view cases and 24 real SQLite
Direct/Committed scenarios. None has run for this candidate. The Product tests
need actual `AXYNDRA_WORKSPACE_PLUGIN_PACKAGE` and the adversarial native
`AXYNDRA_READ_VIEW_PLUGIN_FIXTURE` path. Protocol mocks are not Store authority
proof; successful compilation or a zero-case test filter is not validation.
