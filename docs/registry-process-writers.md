# Registry management writers (API 2.0)

The supported execution platform for this guard is Linux x86_64. Other targets
must fail with `plugin.registry_platform_unsupported`; there is no directory
token fallback. The existing native library supplies the small filesystem
primitive, without a Registry dependency on Store or Host.

Every actual import, acquired import, update, acquired update, rollback,
uninstall, enable/disable, restoration and garbage collection starts with the
existing object mutex and nonblocking OS locks. Both settings/plugins and the
identified workspace/.axyndra/plugins participate, in stable path order. The
same workspace remains serialized when callers use different settings roots.
Paths are opened one component at a time without following symbolic links;
directory and lock-file inode identities are checked while the fence is held.
Concurrent acquisition reports `plugin.registry_busy`; callers may retry their
original management operation after reopening/refreshing state. There is no
automatic retry or hidden duplicate action.

The persistent `.registry-writer.lock` files are never removed by publishers.
Descriptors are close-on-exec, and the kernel releases ownership when a process
exits or is killed. A stale file does not mean a stale lock. Under the lock,
Registry reloads both scopes, their rollback history and effective workspace
grants before checking or changing state. A reload invalidates prior local
context snapshots. Lock parsing, identity and installed snapshot integrity
errors prevent destructive writes; doctor/runtime availability diagnostics are
not a maintenance gate. Normal management never executes a plugin.

Restoration is also a compensating-operation boundary: its original local
namespace/scope record must still equal the reloaded record. A competing newer
generation yields `plugin.registry_stale` instead of being overwritten by old
rollback data. Explicit rollback uses the newly loaded actual history.

Workspace lock.jsonl and the host-owned grant file still use the original
transactional publisher and rollback. Before any destructive rename, the same
verified directory descriptor creates and syncs `.registry-publication.pending`.
Only proven successful publication or completed rollback removes that marker.
An interrupted marker or legacy workspace `lock.jsonl.txn-*` artifact returns
`plugin.registry_recovery_required`; the workspace scope is withheld from a
new reader and original lock/grant/backup bytes are retained. Unaffected user
records remain inspectable. No recovery procedure infers completion, deletes
backups, or silently authorizes a grant. Recovery requires operator review of
the complete matching lock/grant pair and retained backups. This guard does not
claim an all-files, power-failure-durable transaction.

API compatibility: regular PluginRegistry management signatures remain. The
previous public `writeWorkspacePluginState` raw-record helper now explicitly
rejects with `plugin.registry_unscoped_publication`; it cannot prove a caller's
records are current. The real publisher is internal and requires the actual
mutation's nonserializable fence. This intentional breaking behavior is recorded
by agent_plugin_registry version 2.0.0. Persistent lock/history formats, package
identities, capability policy and workspace-grant content are unchanged.

This block establishes writer serialization, not instant cross-process runtime
revocation. An already-running host's cached read state still needs a separate
disk freshness boundary before a new native/network/approval effect. No claim
of full issue completion or real multi-platform support follows from this work.

Validation entry points (authored, not executed in the source-only candidate):

- Run all registry units: original 3 plus 8 new tests, keeping strong historical
  and tamper assertions.
- Build `support_tests/registry_process_contract` with the normal native library,
  then run its `check.py --library <libprocess4cj_native.so> --worker <executable>`.
  Its 8 tests use real OS processes, kernel locks and persistent Cangjie Registry
  objects. It requires prerequisites and Linux x86_64; unsupported is not a skip.
- Re-run actual Minimal and Product management/import/disable/rollback/GC gates.
  Do not replace these with the source-only Python AST or patch checks.
