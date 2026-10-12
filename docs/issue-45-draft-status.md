# Issue #45 draft status — 2026-10-12

This branch collects the existing plugin-first migration and subsequent fixes
for [issue #45](https://github.com/lIlIIlIll/Axyndra/issues/45). It is a review
draft. The Epic's 30 A0–A7 items and six completion criteria remain open.
Source checks and earlier test runs do not establish acceptance of this combined tree.

## Changes available for review

| Scope | Source and review entry points |
| --- | --- |
| A0: architecture and migration | [ADR 0004](adr/0004-plugin-first-host-boundary.md), [migration baseline](plugin-first-migration.md), dependency and retired-business-source gates |
| A1: common plugin boundary | `agent_sdk`, `agent_extension_runtime`, `agent_plugin_registry`, `agent_host_runtime`; versioned contributions, native/JS processes, controlled services, bounded payloads and lifecycle management |
| A2: MCP | Independent `plugins/mcp_client` and `plugins/mcp_server`; [MCP migration](mcp-plugin-migration.md); old product MCP packages and command branches removed from the candidate |
| A3: external capabilities | Independent AST, web-search, GitHub, LSP, DAP and eval packages, with host-controlled file/process/network services |
| A4: default coding tools | Independent Workspace, Shell, Shell Readonly and Program packages; file plans and derived-call authority remain with the host |
| A5: context and workflow | Skills, Memory, Compaction and Workflow packages; [workflow migration](workflow-migration-remaining.md), context versioning and historical compatibility boundaries |
| A6: model providers | Independent model-provider package and [provider contract](model-provider-plugin-contract.md); common Attempt, budget and terminal handling remain with the host |
| A7: distributions and retirement | [Minimal/Coding/Full recipes](distribution-profiles.md), native SDK examples, CLI/RPC/TUI diagnostics, compatibility oracles confined to Support |

The recipes contain no bundled Minimal plugins, nine Coding plugins and seventeen
Full plugins. These are source/packaging declarations, not clean-environment runtime results.

The latest fixes include optional compaction policy handling, workflow installation
cleanup, cold-history lookup, Product test imports, RPC failure reporting, Linux
dead-process observation, content-receiver capacity, fixture prerequisites and a
paid buffered IPC reader. Catalog/Prepared-plan copies now include concrete Store,
Registry, SQLite audit and permission receivers. The last Catalog/SQLite candidate
completed author checks; its complete independent review and Cangjie runtime checks
have not completed. Unknown custom consumers, public raw metadata, exceptional
copies and asynchronous aliases retain their real outstanding memory charges.

## Actual validation and its limits

| Executed source and scope | Observed result |
| --- | --- |
| Draft Windows source/packaging checks | Fifty existing Python tests executed with six error records, including missing fixture prerequisites and POSIX-only process cleanup. Minimal source dependency and tracked-artifact gates passed. After moving the retired `agent_extensions` from required hosts to forbidden optional capabilities, the general source dependency gate also passed: 61 packages, zero remaining baseline violations. |
| Earlier full source snapshot 135, 18 modules plus Product test compilation | Fifteen modules passed all 857 cases; Workflow passed all 169 cases. RPC, App and Host still failed, and Product test compilation failed. Subsequent fixes are included here, but that full gate has not been rerun on this draft. |
| Cold Extension runtime variant with Host compiler support and fixes through buffered-reader 214 | Compiler enumerated all 84 cases; runtime had 83 passes and one `extension.invocation_timeout`. Both added reader cases and both corrected fixture cases passed. All nine final guards passed. This variant does not contain every change in this draft. |
| Diagnostic 215 of the same original large-request case | Complete 84-case enumeration, then one selected case failed; summary was 84 total / 83 skipped / one error. The original 32 × 1 MiB load and 10-second deadline were retained. All nine final guards passed. This diagnostic overlay is not included in production source. |

The remaining Extension failure is
`OrdinaryServiceRequestPayloadTests.sameTwoSlotsAcceptMixedRawAndLogicalRequestsThenReleaseOnlyAtResultConsumer`.
The diagnostic shows expensive lexical node counting/prepayment. It does not prove
a performance fix. Unsealed performance experiments are excluded from this draft.

## Work required before ready for review or merge

- Complete independent review and real SQLite/Host execution of the latest Catalog/Prepared-plan candidate.
- Repair or correctly run the remaining auxiliary fixture/platform checks; added-line whitespace warnings also remain to be tidied.
- Resolve the original large-request timeout without reducing its load or increasing its deadline.
- Rerun all 18 modules and the complete Product compiler/runtime on this exact combined source.
- Run all seventeen native-plugin cases and real clean-environment Minimal/Coding/Full workflows.
- Complete authority, cancellation, recovery, data protection and process-custody acceptance across real entry points.
- Record comparable P50/P95, memory, IPC, activation and cancellation/reclamation measurements, and actual platform CI results.
- Audit all 30 issue items and six completion criteria against final-source evidence; keep historical results scoped to their original source.

No issue checklist is marked complete by creating this draft. This PR does not
close issue #45 and must not be merged based on the earlier partial results.
