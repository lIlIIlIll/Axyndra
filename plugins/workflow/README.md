# Workflow policy candidate

This independently packaged native executable owns the Todo validation,
mutation, Markdown and Goal state policy algorithms. Its only currently
implemented contribution is a pure data provider. It cannot read a database,
admit a Run, approve an Operation or commit a document.

The complete tool, command, role and routing migration is still in progress.
This package alone does not complete A5-03. Source-digest echoes are data and
are not grants. Host integration must bind the actual package generation,
configuration, canonical source, cancellation and expected document revision.

The 24 black-box cases in check.py must be run against the packaged binary.
They are authored, not executed. Build with build-package.sh, then invoke
check.py --package <output-directory>. Pure policy state is query-local.
Large documents exceeding the existing generic content profile remain open.

Packaging uses the explicitly selected SDK and StdX roots. Dependency lookup
starts with the repository Native library directory, then the selected SDK
`runtime/lib/linux_x86_64_cjnative`, its `tools/lib`, and the resolved StdX
directory. Ambient `LD_LIBRARY_PATH` entries are not appended to these inputs;
the existing relocated-package check still uses the packaged libraries.


The optional `plan_write` Tool owns the original complete-plan schema, ASCII
trim validation and review response. Its inspected contribution and native
`ready` descriptor both declare `"execution_profile":"data_only"`. This is a
Host-enforced reduction of the ordinary Tool route: WorkspaceRead remains
required, every Host service request is rejected, network stays Denied, and the
actual canonical call, Root Receipt, package snapshot and generation remain
checked. The package's separate document-store Tools keep their original
positive read-intent/CAS requirements. The execution profile does not grant
capabilities or authorize a user plan.

Product Plan/Vibe presentation must explicitly select the installed contribution
in `settings/plugins/policies.json`: the existing `workflow` binding contains
`namespace`, `provider`, `package_digest` and `plan_tool` (the local name,
`plan_write`). The actual mounted namespace determines the qualified catalog
name. Missing or stale selection fails before enabling Plan/Vibe. Plan Review,
edits and human approval remain Application controls; new plans are displayed
and counted only through their actual completed canonical Receipt/result.
Legacy plan text remains descriptive history.

Execution-profile negotiation is experimental within the existing v2 protocol.
An omitted field preserves the original Brokered behavior. A new Host rejects
unknown profile strings, non-Tool uses and manifest/ready disagreement; an older
Host rejects the unknown manifest field rather than silently granting an effect.
`check_plan_tool.py` separately checks the actual native pure prepare/execute
route with the original fixed five-second peer deadline. Host service rejection
and canonical/UI behavior are exercised by `InstalledPlanToolTests`.


## Explicit Hub service families

The installed package exposes `hub_peers` (`list`, `inbox`), `hub_messages`
(`send`, peer `wait`), `hub_jobs` (`jobs`, job `wait`), `hub_cancel` (`cancel`),
and `hub_process` (the eight process operations). Each description names its
accepted operations. The full original schemas, parser, frozen-plan comparison
and result renderers are shared inside Native. A request for a different
family is rejected before a Host service request. The optional original `hub`
contribution remains selectable for existing narrowly configured installations;
Product does not register a bare Hub executor or route a name to an alias.

Select these contributions in the ordinary `plugins/primitives.json` document,
using the actual installed namespace and content digest. The selected services
are respectively `peer.list`/`peer.receive`, `peer.send`/`peer.wait`,
`job.list`/`job.wait`, `job.cancel`, and the exclusive `process.service`.
Each uses `frozen-primitives-v1` and `prepare_child`. The Host enforces the
closed twelve-service inventory, unique selections and the existing child/process
mutual exclusion. Exact per-service capability selection, canonical
Source/Run/Receipt checks, budget, cancellation and physical process ownership
remain enforced. Installing a family gives no capability or approval.

The TUI orchestration fixture now requires an actual built package supplied as
`AXYNDRA_WORKFLOW_PLUGIN_PACKAGE`. It records that package's complete files,
imports/updates it through the real maintenance CLI, writes the exact operator
selection and verifies the enabled Registry record before launching the TUI.
Its original HTTP model, assertions and timeouts are retained. These source
controls do not claim a successful build, UI run, or process cleanup.

`hub_process_read` selects the trusted `process.observe` primitive for ps,
logs, describe and wait. The Host independently admits only normalized read
operations; write capability/effect are never accepted from a Native claim.
This separate family preserves the original read-only approval contract.
