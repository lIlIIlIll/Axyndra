# Plugin capability ownership ledger (issue #48 T0-01)

Machine-checkable inventory of where each capability of
[issue #48](https://github.com/lIlIIlIll/Axyndra/issues/48) currently lives.
This is an **inventory of actual state**, not a claim that any row is accepted.
The plugin ecosystem itself is delivered by PR #49 (issue #45).

Rebuild the machine-checkable form with `python3 scripts/plugin_capability_ledger.py`.

## How this ledger is kept honest

- `plugin` — a package under `plugins/` that builds on its own.
- `host` — the capability lives in the host (`agent_product` and friends).
- A row is **externalized** only when a plugin package exists; existing host
  code is not evidence that migration happened.
- `tests` counts `plugins/<name>/src/*_test.cj`. Zero is a real gap, not a
  neutral value: the capability has no in-package contract suite.

## Capability rows

| ID | Capability | Target plugin package | State | Tests |
| --- | --- | --- | --- | --- |
| F01 | MCP client/server | `plugins/mcp`, `plugins/mcp_server` | externalized | 1 + 1 |
| F02 | Workspace read/search/glob/edit | `plugins/workspace` | externalized | 0 |
| F03 | Shell / PTY | `plugins/shell`, `plugins/shell_readonly` | externalized | 2 + 2 |
| F04 | AST | `plugins/ast` | externalized | 0 |
| F05 | Web search / content | `plugins/web_search` | externalized | 1 |
| F06 | GitHub | `plugins/github` | externalized | 0 |
| F07 | LSP | `plugins/lsp` | externalized | 2 |
| F08 | DAP | `plugins/dap` | externalized | 5 |
| F09 | Eval runners | `plugins/eval`, `plugins/program` | externalized | 0 + 0 |
| F10 | PTC / file-plan | `plugins/program` | externalized (shared with F09) | 0 |
| F11 | Skills / project rules | `plugins/skills` | externalized | 2 |
| F12 | Memory / retrieval | `plugins/memory` | externalized | 33 |
| F13 | Compaction / selection | `plugins/compaction` | externalized | 5 |
| F14 | Planning / Todo / Goal | `plugins/workflow` | externalized | 8 |
| F15 | Subagent / review policy | — | **host only** | — |
| F16 | Model providers | `plugins/model_providers` | externalized | 0 |
| F17 | Model selection policy | — | **host only** | — |
| F18 | Ask / forms | — | **host only** | — |
| F19 | Result / diff / workflow views | — | **host only** | — |
| F20 | Run insights / status | — | **host only** | — |
| F21 | Checkpoint / undo entry | — | **host only** | — |
| F22 | Extra guard / transform / observer | — | **host only** | — |

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

## Open gaps (not achievements)

1. **F15, F17–F22 have no plugin package.** Subagent/review policy, model
   selection policy, ask/forms, views, insights, checkpoint-undo entry and
   guard/transform/observer contributions remain in `agent_product`
   (`approval_reviewer.cj`, `config.cj`, `application.cj`). Issue #48's
   completion definition requires all of F01–F22 to have an owner and target
   component, so these rows are the outstanding work.
2. **Eight externalized capabilities have no in-package contract suite:**
   workspace, ast, github, eval, program, model_providers, web_search, mcp
   (one case). Externalization without a suite is not accepted coverage.
3. **No plugin provides a Tool-free contribution.** Issue #48 §3.1 requires at
   least one UI/command plugin with no Tool to prove the host protocol is not
   simply "an MCP wrapper" (T1-03).
4. This ledger records **ownership and packaging state only**. It is not
   evidence for the enforcement, lifecycle, recovery or fault-matrix rows of
   issue #48 §9, none of which are claimed here.
