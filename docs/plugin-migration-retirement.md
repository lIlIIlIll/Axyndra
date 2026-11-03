# Legacy path retirement inventory (issue #48 T0-02)

Enumerated, checkable list of the pre-migration and compatibility paths that the
plugin-first migration is expected to retire, with measured usage for each. This
is an **inventory of candidates with evidence**, not an approved retirement
plan: issue #48 T0-02 asks for the list, and removal scope is the maintainer's
decision.

Regenerate with `python3 scripts/plugin_retirement_inventory.py` (`--json` for
the machine form). On the current tree: **21 candidates, 19 live, 2 test-only, 0 dead.**

## How a row qualifies and how usage is measured

- **Name marker** — the file name carries `legacy`, `compatibility`, or
  `bridge`, i.e. it preserves an older form or adapts between two shapes.
- **`exports`** — the file's *distinctive* declared names: exported symbols at
  least 12 characters long that are not generic words. Short/generic names
  (`main`, `parse`, `find`, `values`, ...) are excluded because they match
  unrelated code; an early revision counted them and reported ~1,800 spurious
  references per file.
- **`refs`** — external source files referencing any distinctive name. Because
  the filter is conservative, this is a **lower bound**: a file may still be
  live through an identifier this script refuses to follow.
- **Verdict** — `live` (referenced outside itself), `test-only` (only its own
  test), `dead` (no references found).

A `dead` verdict would be evidence for retirement; it is still **not**
authorisation to delete, because a file that only *reads* older data may remain
required for rows written by earlier versions (issue #45 §7 forbids lowering
data-compatibility guarantees to simplify a migration).

## Findings

| Group | Count | Verdict | Note |
|-------|-------|---------|------|
| `agent_store/src/legacy_continuation_bridge.cj` | 1 | **live** (186 refs) | Pre-v21 continuation reader; see below |
| `agent_store/src/plugin_document_latest_journal_compatibility.cj` | 1 | **live** (4 refs) | latest-journal window adapter |
| `plugins/workflow/src/goal_legacy_migration.cj` | 1 | **live** (3 refs) | goal-form migration reader |
| `plugins/workflow/src/goal_legacy_migration_test.cj` | 1 | test-only | its own oracle |
| the ten `agent_product` legacy memory oracles | 10 | 9 live / 1 test-only | legacy memory-behaviour oracles |
| the six `support_tests` packaged-contract legacy oracles | 6 | live | packaged-contract legacy oracles |
| the three `workspace_legacy_oracle` todo oracles | 3 | live | todo/workspace legacy oracles |

## Why nothing is scheduled for deletion here

Two reasons, both measured.

1. **The adapters are load-bearing.** `legacy_continuation_bridge.cj` states its
   own contract — *"New writes keep the complete request snapshot as a
   structured canonical value; the opaque legacy JSON form remains readable
   only for pre-v21 migration input"* — and its read side is called from
   production code: `persistence_runtime/src/sqlite_run_repository.cj` invokes
   `consumeLegacyRunContinuationSource` (`:131`) and
   `optionalLegacyPayloadFromDurableContinuation` (`:1660`). Deleting it would
   drop the ability to read runs persisted before v21.
2. **The remaining rows are `live` only because they are test oracles.** They
   are referenced from their own suites, which is why the script's conservative
   filter still finds external mentions; retiring them means retiring the
   legacy *behaviour contract* they pin, which is the same maintainer decision
   as the adapters.

## Relation to the other gates

Host-to-business, component-to-component and library boundaries are already
enforced (`scripts/plugin_boundary_gate.py`, `check_library_boundaries.py`,
`dependency_pin_gate.py`), and the plugin fleet has **no** plugin-to-plugin
dependencies. This file supplies the T0-02 element that was missing before: the
enumeration itself, as a diffable artifact.
