# Independent LSP service candidate

Native channel reads explicitly request `encoding: "base64"` from the existing
controlled Host service. Each result is exact `bytes_base64`/`eof`, canonical
RFC 4648, and at most 32 KiB decoded (43,692 encoded bytes), below the existing
64 KiB IPC ceiling. It is binary until Content-Length framing finishes, so
split UTF-8 characters remain valid. The Host's omitted/explicit hex default
continues to use exact `bytes_hex`/`eof` and 16 KiB. This representation selects
no new read authority, process, Root, quota or deadline and never falls back
from a malformed Base64 result. The original channel window, 4,096-request
ceiling, write identity and approval remain unchanged.

The source candidate requires a fresh package: all original eight unit and
sixteen process protocol cases plus three codec and three compact protocol
controls. Existing package passes do not cover these new bytes; real Product
large-document completion still requires the complete current six-case gate.


SEALED_UNCOMPILED. Issue #45 A3-03 remains open; old LSP/DAP production paths remain. No compiler/native tests have run for this candidate. Apply after language7, ownership7, frame-lifetime5, payload44/publication3 and the managed-file-plan overlay, using exact base hashes and three-way rebasing as needed.

This standalone package requests the generic process.channel Service route. Product owns executable/argv/mounts/environment/network, real HostService startup, approvals, lease, unique catalog and exact channel-write child Operations. Plugin configuration supplies only nonsecret LSP initialization options/settings, root URI, language ID and bounded timeout. Protocol algorithms use the existing lsp4cj parser/read pump/correlation and prepared request API; wire helpers reuse payload44 with source hashes in reuse.json.

Implemented protocol actions: definition, type_definition, implementation, references, hover, symbols, diagnostics, rename, code_actions, rename_file, request and notify. Preparation freezes explicit document content/version, didOpen/didChange notifications and request into one exact byte batch without I/O. Execution dispatches that batch once. Dispatch tombstones and document revisions reject consumed/stale preparations. Notifications/diagnostics return bounded data plus omitted count. Cancellation closes the owned session and emits no unapproved cancel bytes. Known server error remains distinct from transport Unknown.

Rename WorkspaceEdit.changes can produce a read-only host file plan from exact frozen document text. UTF-16 positions, overlap and workspace-relative URI checks run in memory. The plugin does not write files or supply source authority. Product binds the actual owned parent and proposal Receipt; apply_file_plan remains a separate reviewed operation, including after Product restart.

The native endpoint uses the full payload44 profile rather than a small-only transport. The same 128 MiB pool charges physical/logical input before decoding, prepared cached bytes, actual Content-Length body and token/DOM lifetimes, capabilities/notices and final serialization. Conservatively charged memory is not an RSS measurement. The actual 3 MiB document/result fixture exercises repeated consumers and durable results rather than only large protocol acknowledgments.

Authored validation, all unexecuted: four pure UTF-16/edit/path cases; nine actual packaged endpoint/Python backend protocol cases; five original public Product/SQLite cases plus five ContextRead integration cases. Product cases cover startup rejection before I/O, Direct exact physical frame versus canonical child, actual Committed approval, full 3 MiB input/output persistence, written-request cancellation Unknown, and proposal followed by independent apply approval after reopening Product. The protocol harness's Receipt-shaped responses are explicitly fixtures, not Product authorization evidence.

Run after integration using the repository's pinned SDK: `cjpm test` in plugins/lsp (four pure cases), build-package.sh --output NEW_DIRECTORY, then `python3 plugins/lsp/check.py --package NEW_DIRECTORY` (nine actual process cases). Product tests require AXYNDRA_LSP_PLUGIN_PACKAGE=NEW_DIRECTORY and AXYNDRA_LSP_TEST_SERVER=<absolute plugins/lsp/tests/lsp_peer.py>; use the isolated unit gate for PluginLspServiceTests (five cases) and PluginContextReadTests (five cases). Existing process and LSP library suites must include frame-lifetime's eight new cases. Compiler/gate inventory wiring is not silently treated as already applied.

Committed ApplicationSession calls can now supply documents as relative path/version. Pure prepare requests a bounded resource read; the same Run commits a separate ReadOnly/Denied/NeverReplay ContextRead Operation using host metadata, exact capability and approval policy, then freezes the observed text into the original language request. The ordinary workspace capability creates no additional confirmation; sensitive classification uses the existing policy and respects effective Yolo. Facts retain exact parent/Run/projection links and are rechecked on admission and execution. The installed endpoint never reads host files. Direct implicit filepath preparation is still open and fails without a fabricated fact; explicit uri/version/text remains supported. The new read result is UTF-8 and limited by the 4 MiB canonical context snapshot including JSON encoding. Open compatibility work: WorkspaceEdit.documentChanges/create/delete/rename, active workspace/applyEdit callbacks and arbitrary reverse replies need canonical continuation/effect admission; they currently reject rather than write. Code actions are returned as data, not implicitly applied. Cached diagnostic/snippet/workspace-scope/reload behavior and the old 300-second timeout need parity work. Generic status works; refresh returns a typed not-implemented result. DAP's independent package and action/event/runInTerminal matrix are not implemented by this LSP candidate. The existing 64 KiB file-proposal limit is separate from native payload capacity.

The deadline/poll follow-up keeps the original admission deadline through backend
service emission and both small and chunked result publication, checking again
under the output lock after serialization. Idle stdout backs off to 1 second;
stderr polls without blocking the synchronous Host broker and waits locally.
Refresh windows retain the Host's separate 25 ms limit. The explicit profile
accepts the original 300-second configuration ceiling; the default 10-second
profile stays unchanged. Twelve native protocol cases are authored, including
a quick real request configured for 300 seconds (not a 300-second endurance
measurement), a hanging request with no replay, and incomplete-call expiry.
This follow-up is not LSP behavior parity or authorization for old-path removal.

Versioned text-edit follow-up (authored, not yet executed): WorkspaceEdit
documentChanges now accepts TextDocumentEdit with an exact frozen version or a
null version, preferring that field when both edit representations are present.
Each target still needs frozen content; aliased or repeated targets, stale
versions, annotations and resource create/rename/delete operations reject.
Null, empty and identity edits return no application plan. Equal-position
inserts preserve protocol array order. Initialization advertises versioned text
edits and explicitly declines workspace/applyEdit reverse execution. Changed
text still produces the same immutable file proposal and separate Host approval.
Eight pure and sixteen process cases are authored in this source graph.
Resource operations, reverse effects and the remaining behavior matrix remain
open; this change does not authorize removing the old LSP implementation.
Semantics reference: https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/workspaceEdit.md
