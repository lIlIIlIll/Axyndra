# Todo through the selected Native contribution

Todo parsing, task transitions, markdown formatting and import interpretation
belong to the installed Workflow Native package. Product has presentation DTOs and a readonly UI markdown renderer.
The display renderer never parses editor text, creates a plan or changes the
editor digest. Kernel contains no Todo status, item or phase types, static Todo executor,
slash algorithm, or metadata writer.

An operator must install and enable the current Native Workflow package, allow
its exact `todo` document through `plugins/documents.json`, and select its real
tool and command in `plugins/todo-tools.json`:

```json
{"schema":"axyndra.todo-tools/v1","namespace":"axyndra:workflow","package_digest":"<actual installed package SHA256>","tool":"todo","command":"todo"}
```

Selection alone grants no access. The current generation, full implementation
version, package fingerprint, actual command route, thread and document
configuration are checked again at execution and continuation. Missing,
disabled, replaced or unprovided components return explicit errors; Product
does not restore an old executor or select another package automatically.

The current fact lives exclusively in `plugin_documents`, under the actual
thread, main lane, selected namespace and `todo` key. Reading the UI or RPC
state is a readonly projection of that row. `get_state` reports
`todoComponentError` when the projection is unavailable. The former
`thread_metadata.todo_payload` is preserved as cold migration data and is never
updated alongside the current document.

Ordinary `/todo` changes and editor replacements use one actual canonical
document Root, its completed ContextRead and its original CAS. Editor changes
carry the digest of the displayed document; a concurrent change is rejected
without overwriting bytes. A pending review is visible through the same
Application approval surface and its real operation ID. RPC `set_todos` returns
`awaitingApproval: true` and `todoPhases: null` until committed, and emits the actual
approval frame. The historical Unit setter returns `todo.approval_required`
instead of claiming an uncommitted write succeeded.

## Import, export and explicit resource effects

`/todo import [reference]` (default `TODO.md`) produces a description after a real document read.
It does not open a file or URI. Submit `/todo resource` to run the selected
Workspace Native read Root. For an artifact or custom URI, submit
`/todo resource` again to run the separate Host resource Root, with its own
approval if required. Submit `/todo commit` only after the complete raw read
has finished. The commit is a new document Root and CAS; approval of a read or
of the earlier proposal does not approve this write.

`/todo export [destination]` (default `TODO.md`) reads the actual document and proposes its
markdown. Submit `/todo resource` to run the independent `export_artifact`
file Root or `write_resource` URI Root. File export uses the existing immutable
artifact owner and atomic export. A URI uses the registered trusted handler;
the Native process receives no handler, database, file descriptor or callback.
Rejecting the resource approval leaves the destination and document unchanged.

These routes retain the original resource limits: raw ordinary Workspace
results are bounded by their existing 262144-byte frame; resource read pages
are at most 1 MiB; URI writes are at most 32768 UTF8 bytes; file artifact export
retains its existing 16 MiB ceiling. A truncated page or mismatched
`returned_bytes`/`bytes` is rejected before import commit. The Native command
JSON convenience form remains bounded by 65536 encoded bytes and is not an
unlimited import interface. Actual canonical argument, Native frame and
document budgets also apply. An oversized encoded editor or migration input
returns an explicit error and preserves the old/current data; it is not
silently shortened. The document repository's existing 8 MiB validation and
frozen-payload/reference paths remain unchanged; this is a storage limit,
not a claim that every 8 MiB document fits a single ordinary frontend frame.

## Cold data and rollback

The existing schema 27 to 28 transaction already copies historical Todo JSON
into the canonical document table while retaining its cold source bytes. This
candidate leaves that SQL and the accepted schema27 entry fix byte for byte
unchanged. No additional migration runs during state display, session
restoration or compaction. `/todo migrate` is an explicit actual document Root. It accepts the
historical phase/task list JSON through the Native decoder, verifies the
displayed input digest, and requires an absent current document. Unsupported,
malformed, oversized or conflicting old data is rejected before document
write; the cold field is retained byte for byte. A current document is never
replaced by cold data through this command.

Before opting into migration, retain an offline backup of the existing state
database and operator files. Disabling the package preserves both the new
document and old cold field. Restore a backup only while the application is
closed; retirement does not re-enable the former metadata writer. Legacy
algorithms exist only in `support_tests/workspace_legacy_oracle` to preserve
historical assertions, and are not a production fallback.

Cold migration freezes the exact stored legacy bytes (an absent or empty field has the explicit `[]` input). The actual retained document owner rechecks those bytes before preparation, approval and result consumption. A changed cold input is rejected; it is never re-encoded or overwritten as part of migration. This input check is not a grant or an additional fact store.

## Frontend and SDK compatibility

CLI contains no Todo builtin or Todo help/completion record. Its generic extra
definition input receives the installed Product compatibility descriptor; this
adds display/completion data and never execution authority. Product's explicit
alias routes the installed command or the existing independent resource Roots.

Opening an editor executes the selected Native view and may require its actual
ContextRead and parent approvals. Ordinary display refresh is readonly and never
changes this editor snapshot. Save/import use the Native parser and CAS. During
review the TUI preserves the draft and shows the existing approval surface; it
does not report a save until the original invocation and cleanup acknowledge.
Completion is published together with retirement of that exact pending slot;
cancel, rejection, changed session and revoked selection publish no completion.

The removed Domain Todo DTOs and Product setter/static Todo registration are an
intentional SDK break. Product presentation clients use ProductTodoPhase,
ProductTodoItem and ProductTodoStatus; ApplicationSession.setTodoPhases is the
actual document operation and exposes a pending review. The repository exposes
only legacyTodoBytes for cold history; its former todoPhases/setTodoPhases
current-state contract is retired. Historical algorithms and writers exist only
in the isolated workspace_legacy_oracle support package. There is one production
writer: the installed Native document CAS path.

Candidate108 is source only. Its authored CLI/RPC/Product/TUI/Native contracts
have not been compiled or executed on the current graph. It is not final A5-03,
Full/Minimal distribution or cross-platform acceptance. The independent107
recovery component shares Application/Product files and must be composed by
its exact context-boundary hunks, not whole-file replacement.
