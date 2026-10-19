# Bounded readonly contribution delegation

The native Program package owns the existing restricted language compiler and
interpreter. The host accepts `tool.readonly` as a generic service and resolves an
operator-selected alias to a frozen installed Tool contribution. It does not
interpret Program code or accept an arbitrary tool name from the worker.

The first supported graph is a canonical Direct or Committed root, one installed
readonly Workspace contribution, and that contribution's exact read-view worker.
The read-view worker still sees only the host-built, approved snapshot. This does
not enable deeper HTTP, process channels, file proposals, writes, arbitrary
recursive tools, or wider sensitive/outside-workspace access.

Use the existing `settingsRoot/plugins/services.json`, with the exact installed
package digest and a separate ordinary-read grant for each target contribution:

```json
{
  "version": 1,
  "plugins": [{
    "namespace": "axyndra:program",
    "package_digest": "sha256:<installed-package-digest>",
    "configuration": {},
    "requests": [],
    "credentials": [],
    "tool_delegations": [{
      "contribution": "run",
      "tools": [{"alias": "read", "plugin": "axyndra:workspace", "contribution": "read"}],
      "max_calls": 32,
      "max_depth": 2
    }]
  }]
}
```

The example shows only the Program entry; retain the Workspace entry and its
existing `tool_read_grants`. Configuration adds no Run capabilities and does not
waive the normal root approval. In particular, Write mode still prompts for
ExtensionInvoke. Preparation freezes the actual Thread catalog, target descriptor
version/fingerprint/schema, package digest, generation and configuration digest.
Execution and every actual child check those bindings again.

All levels use the same Run, Thread, epoch, cancellation, budget and existing
Tool-slot reservation. Store schema 27 records the host-minted child call ID,
canonical root ID and depth in the existing derived-admission rows. It checks
every ancestor's full plan, source, actual handoff and exact ParentIntent evidence
in the same transaction. Legacy rows with no child identity cannot acquire deep
authority. Hard bounds are depth 8, width 32 and 256 total child admissions; the
initial allowed graph is only two edges deep.

A parent may return Unknown before its descendant finishes. Its reservation
remains held until the deepest actual callback returns. A late Unknown, or a
Rejected child which never executed, may settle only with the same active Run
enclosure and the ancestor's original handoff plus unique reserved Unknown
Receipt. This exception never permits a new admission, execution or handoff.
After the Run has ended, the candidate does not reconstruct execution authority
to perform cleanup settlement. Recovery remains required if facts are unresolved.

The host observes actual child Receipts before publishing a readonly parent's
result. A pending callback, missing Receipt or Unknown child produces
RecoveryRequired even if the plugin reports success. Known readonly failures keep
their existing classification. Plugin result strings are not outcome authority.

Build and verify the fresh native package through
`scripts/prepare_program_plugin.py`. Product tests use that exact package and the
independently packaged Workspace plugin. The authored matrix includes Store
Direct/Committed ancestry and late settlement, single-slot lifetime tests, native
protocol tests, actual Product execution/approval/revocation, and worker output
failure. These new tests have not yet been compiled or run.

Legacy Program remains available pending validation and parity. Ordinary native
Tools still use a 256 KiB physical frame; a full 256 KiB source and 1 MiB result
need the existing logical-payload machinery wired to this contribution type.
Old worker output/artifact behavior and an in-flight OS cancellation matrix also
remain open. The language's default 128-call limit and Product's actual 32-call
limit remain distinct; this package preserves the latter.
