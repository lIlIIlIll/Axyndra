# TUI card inventory and ownership

The ordinary assistant/user transcript remains plain text. Structured events use
the card registry in `agent_tui/src/event_cards.cj`; layout, wrapping, Unicode
width, borders, virtual scrolling and terminal frame output remain owned by
`cj_tui`.

| Card | Product summary/body | Important states | Fold behavior |
| --- | --- | --- | --- |
| Shell | command, cwd, stdout/stderr, exit/line footer | pending, running, completed, failed, cancelled, timed out | long output folds; expanded body has local scroll; timeout is not rendered as generic failure |
| Read | path and numbered content | running, completed, failed | long content folds |
| Write/Create | path, action, before/after bytes, type and line count | waiting, running, completed, failed | completed detail folds |
| Edit | per-file diff and added/removed counts | waiting, running, completed, failed | diff folds and expands |
| Search | pattern, directory and grouped matches | running, completed, failed | matches fold and expand |
| List | directory and normalized entries | running, completed, failed | entries fold and expand |
| HTTP | method, redacted URL, status and bounded response | running, completed, failed | response folds and expands |
| Git | operation, repository, branch, remote and result | running, completed, failed | result folds and expands |
| MCP | server, tool, resource and bounded result | running, completed, failed | result folds and expands |
| Approval/Permission | risk, capability, exact target, reason, bounded preview and exact session scope | reviewing, awaiting user, approved, denied, timed out, expired, cancelled | waiting card stays open; settled card folds |
| Ask | question, choices, recommendation and preview | awaiting, completed, rejected | interactive while awaiting |
| Plan | step status and details | pending, running, completed, failed | retained as structured progress |
| Subagent | identity/current action/result | pending, running, completed, failed | completed detail may fold |
| Advisor | concern and recommendation | running, completed, failed | bounded detail |
| Approval Reviewer | reviewer model, structured decision, bounded reason | reviewing, approved, denied, timed out, failed | settled detail folds; never exposes hidden reasoning |
| Background job | current status/result | queued, running, completed, failed, cancelled | bounded detail |
| Warning/Error | actionable diagnostic text | warning, failed | bounded detail |
| Retry | attempt number, retry cause and next action | queued, running, failed, cancelled | compact status record |
| Model switch | previous and selected model role | completed, failed | compact structured record |
| Compaction/Summary | before/after/saved context or summary | completed | compact structured record |
| User confirmation | question, exact choices and optional note | awaiting user, completed, cancelled | interactive while awaiting |
| Unknown tool | field count plus bounded, redacted arguments/result | all canonical states | safe fallback; never unbounded raw JSON |

## Approval and write classification

- `workspace.write`: the canonical target resolves under the workspace root.
- `temp.write`: the canonical target is in a system temporary directory but
  outside the workspace.
- `outside-workspace.write`: any other non-sensitive external target.
- `sensitive-path.write`: credential or system-sensitive paths; this remains
  critical and narrowly scoped.

Write approval cards never receive the complete `content` argument. They show a
summary with canonical path, create/overwrite action, exact byte and line counts,
language, a six-line redacted preview, truncation marker and content hash. The
session option names the exact `ApprovalGrantScope.pathPrefix` or host.

## Before and after

| Concern | Before | After |
| --- | --- | --- |
| Approval content | raw or JSON-shaped payload could dominate the card | bounded human summary; complete content is kept out of the card |
| Write location | lexical/prefix checks could mislabel an escape | canonical existing-ancestor resolution distinguishes workspace, temp, outside and sensitive paths |
| Session grant | generic session wording | exact path prefix or network host |
| Tool presentation | generic raw arguments/results | Shell, Write, Edit, Read, Search, Git, HTTP and MCP summaries |
| Lifecycle | separate reducer paths could restore `running` after settlement | one transition rule protects terminal states from late chunks/upserts |
| Secrets | fallback-only redaction left specialized fields inconsistent | titles, specialized fields, bodies and fallback payloads use the shared card redactor |
| Long cards | transcript-sized detail | per-card collapse/expand plus local body scrolling |
| Narrow/Unicode output | limited fixtures | 40/60/80/100/120/160-column core gallery coverage with Chinese, Emoji and combining characters |

## Focused validation

```bash
cd agent_tui
DISABLE_ZOXIDE=1 zsh -lc 'source ~/.codex/zshrc; source "$CANGJIE_HOME/envsetup.sh"; cjpm test --no-color'

cd ../agent_app
DISABLE_ZOXIDE=1 zsh -lc 'source ~/.codex/zshrc; source "$CANGJIE_HOME/envsetup.sh"; cjpm test --no-color'
```

The repository contract suite additionally exercises canonical write
classification, bounded write previews, approval policy and restored session
grants.

The Reviewer response schema requires `approvedCapabilities` even though the
model prompt already advertised it. An approval is accepted only when that list
contains exactly the deterministic capability on the pending request; missing,
replacement, or additional capabilities follow `failurePolicy`. The tool
pipeline also binds a pending operation to its originating run before terminal
receipt replay or execution.

## Final acceptance fixtures

The six-width unit fixture renders Approval, Write, Shell, Edit, Search, MCP,
Error and Subagent cards at 40, 60, 80, 100, 120 and 160 columns. It checks
grapheme-visible width for every serialized line and keeps secret assertions in
the same matrix.

The golden driver accepts repeatable `--scenario cards|todo|ask|default`, gives
each selected scenario its own timeout, and prints `scenario_started`,
`fixture_ready`, `process_started`, `input_sent`, `snapshot_started`,
`snapshot_completed`, `process_stopped`, `expected_state_reached` and
`scenario_completed` records. A timeout stores terminal bytes, trace events
and `/proc` process diagnostics. The final run completed cards/todo/ask/default
in 1.195/0.558/0.685/0.213 seconds; a deliberate 1 ms timeout produced all
three diagnostic files instead of hanging silently.

The reserved `reviewer-dry-run` command invokes the configured Reviewer on
three approval fixtures without entering the tool pipeline. With
`DEEPSEEK/deepseek-v4-flash` through the `anthropic` adapter, the final run
returned workspace create=approve (low, `workspace.write`, 5612 ms), SSH-key
upload=deny (critical, 1587 ms), and insufficiently authorized force-push
main=ask_user (high, 3732 ms), followed by `tools_executed=0`. Provider
reasoning blocks are ignored rather than logged or interpreted; the final text
must still be one complete strict JSON object. Contract fixtures separately
verify invalid JSON/model, timeout, extra capability and missing
`approvedCapabilities` failure-policy behavior.
