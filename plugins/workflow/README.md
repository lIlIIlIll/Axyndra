# Native Workflow

This independently packaged native executable implements workflow policy,
declared Tools and Commands, and the `plan_review` View. Policy queries return
data. Tools use the Host's canonical preparation, execution and service
boundaries; the package cannot mint a Run, approve an Operation or replace
the Host's document commit authority.

Source-digest echoes are data, not grants. Host integration binds the actual
package generation, configuration, canonical source, cancellation and expected
document revision. Package checks alone do not establish complete Product or
release acceptance; see the [acceptance ledger](../../docs/issue-45-draft-status.md).

From the repository root, build and run the complete 172-case packaged-protocol
gate against a new output directory:

```sh
python3 scripts/prepare_workflow_plugin.py --output <new-package-directory>
```

The gate uses `build-package.sh` and `check.py --package` with the selected SDK.
Policy state is query-local. The Host still enforces configured content and
protocol limits; large primary documents remain Host-owned rather than being
duplicated inside the bounded View model.

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

## First-party plan review

After `/plan <request>` records a plan through the actual selected `plan_write`
Tool, Product opens the installed `plan_review` View. `/plan-review` reopens the
current recorded plan. The View declares its inputs and actions; the Host does
not infer business decisions from labels or widget positions.

Edits stage locally. Selecting an action invokes the declared local Command,
which returns a typed control request, not an execution grant. The Host
revalidates the displayed plan and asks for separate confirmation, initially
**No**, before applying that request.

| Action | Host control after explicit confirmation |
| --- | --- |
| `approve_fresh` | Start execution in a fresh session. |
| `approve_compact` | Request context compaction, then start execution. |
| `approve_keep` | Start execution with the current context. |
| `save` | Record the user edit without executing the plan. |
| `refine` | Submit feedback and request a revised plan without execution. |
| `continue` | Continue planning without execution. |
| `reject` | Preserve plan history and request revision before execution. |

Compact mode needs the actual installed Compaction policy selection. A plan
decision never approves a Tool operation; ordinary capabilities, approval,
budget and cancellation rules still apply. A stale package, replaced View or
disabled generation cannot consume an old event or confirmation.

The `plan_review` Command requires an actual frontend View event. Calling it
directly cannot manufacture user scope. Plaintext/JSON headless presentation
does not submit actions and returns `input_required` with exit code 3 when
supported interaction is required. See the [SDK View contract](../../agent_sdk/README.md#bounded-view-documents)
for generic TUI/RPC input and framing.



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
