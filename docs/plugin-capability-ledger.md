# Plugin capability ownership ledger (issue #48 T0-01)

Machine-checkable inventory of where each capability of
[issue #48](https://github.com/lIlIIlIll/Axyndra/issues/48) currently lives.
This is an **inventory of actual state**, not a claim that any row is accepted.
The plugin ecosystem itself is delivered by PR #49 (issue #45).

Rebuild the machine-checkable form with `python3 scripts/plugin_capability_ledger.py`.

## How this ledger is kept honest

- `plugin` — a package under `plugins/` that builds on its own.
- `host` — the capability lives in the host (`agent_product` and friends).
- `externalized` records the presence of a mapped plugin package. It does not
  prove that every entrypoint or lifecycle requirement is accepted. F19 maps
  the shipped `workflow.plan_review` component, not every UI feature.
- Coverage is counted from **both** suites a plugin may own: Cangjie unit tests
  (`src/*_test.cj`) and/or the black-box Python harness (`check.py`). Several
  plugins carry only the harness, so counting one form alone reports false gaps.

## Capability rows

| ID | Capability | Target plugin package | State | Cangjie tests | Python harness |
| --- | --- | --- | --- | --- | --- |
| F01 | MCP client/server | `plugins/mcp`, `plugins/mcp_server` | externalized | 1 + 1 | 2 |
| F02 | Workspace read/search/glob/edit | `plugins/workspace` | externalized | 0 | 1 |
| F03 | Shell / PTY | `plugins/shell`, `plugins/shell_readonly` | externalized | 2 + 2 | 2 |
| F04 | AST | `plugins/ast` | externalized | 0 | 1 |
| F05 | Web search / content | `plugins/web_search` | externalized | 1 | 1 |
| F06 | GitHub | `plugins/github` | externalized | 0 | 1 |
| F07 | LSP | `plugins/lsp` | externalized | 2 | 1 |
| F08 | DAP | `plugins/dap` | externalized | 5 | 1 |
| F09 | Eval runners | `plugins/eval`, `plugins/program` | externalized | 0 + 0 | 2 |
| F10 | PTC / file-plan | `plugins/program` | externalized (shared with F09) | 0 | 1 |
| F11 | Skills / project rules | `plugins/skills` | externalized | 2 | 1 |
| F12 | Memory / retrieval | `plugins/memory` | externalized | 33 | 0 |
| F13 | Compaction / selection | `plugins/compaction` | externalized | 5 | 1 |
| F14 | Planning / Todo / Goal | `plugins/workflow` | externalized | 8 | 1 |
| F15 | Subagent / review policy | — | **host only** | — | — |
| F16 | Model providers | `plugins/model_providers` | externalized | 0 | 1 |
| F17 | Model selection policy | — | **host only** | — | — |
| F18 | Ask / forms | — | **host only** | — | — |
| F19 | Result, diff and workflow views | `plugins/workflow` | externalized plan-review component | 8 | 1 |
| F20 | Run insights / status | — | **host only** | — | — |
| F21 | Checkpoint / undo entry | — | **host only** | — | — |
| F22 | Extra guard / transform / observer | — | **host only** | — | — |

## Dependency externalization (F01 exit condition)

`agent_product/cjpm.toml` declares **no** static dependency on any business
plugin package. The host therefore does not link MCP, LSP, DAP, workspace, AST,
web-search or GitHub implementations, which is issue #48's F01 exit condition
("移除 MCP 产物与专属依赖后 Minimal 可构建启动").

Shared general-purpose libraries remain host dependencies by design
(issue #48 §4.6): `logical_json_payload`, `agent_host_runtime`,
`agent_plugin_registry`, `agent_history`, `model_provider_runtime`,
`model_fixture_runtime`, `agent_cli`, `agent_app_protocol`, `agent_client`,
`agent_core`, `agent_domain`.

## Distribution profiles

`packaging/distributions.json` is assembly data, not a hard-coded factory:

| Profile | Bundled plugins |
| --- | --- |
| `minimal` | 0 |
| `coding` | 9 |
| `full` | 17 |

## Inventory limits and remaining gaps

1. **F15, F17, F18 and F20–F22 have no mapped plugin package.** Subagent and
   review policy, model selection policy, ask/forms, insights, checkpoint-undo
   entry and guard/transform/observer contributions remain in the host.
   F19 now has the declared Native `plan_review` View and Command in
   `plugins/workflow/axyndra.plugin.json`. Its business logic lives in
   `plugins/workflow/src/plan_view.cj`. This component does not establish that
   all result, diff and workflow surfaces have migrated.
2. Every mapped package carries a Cangjie unit file, a Python harness, or both.
   These counts measure file presence, not scenario coverage or passing tests.
   A shared package's suite counts appear in each mapped row. Do not sum the
   rows to count distinct tests.
3. **Tool-free View and Command fixtures now execute through the real host.**
   `support_tests/view_form_fixture` declares no Tool. The permanent public
   and authenticated-input matrices and the actual PTY lifecycle checks
   preserve zero execution and model facts. The shipped Workflow package
   separately provides plan review alongside its Tools. Artifact-specific
   results and remaining acceptance work are recorded only in the
   [Issue #45 acceptance ledger](issue-45-draft-status.md).
4. This ledger records **ownership and packaging state only**. It is not
   evidence for the enforcement, lifecycle, recovery or fault-matrix rows of
   issue #48 §9, none of which are claimed here.
5. **Declared input bounds are reported per package, not per row.**
   `plugin_packages_without_declared_input_bound` reports the absence of this
   probe's recognized API tokens. The current result is 14 of 17 packages.
   This legacy declaration heuristic does not prove that input is unbounded.
   For example, MCP's current `Limits` class handles `payload_limits` and bounds
   HTTP reads separately. The report remains outside `--check`. Current protocol
   and consumer-boundary verification remains required.
