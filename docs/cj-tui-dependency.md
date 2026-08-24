# cj_tui development dependency

`agent_tui/cjpm.toml` currently consumes `core` and `markdown` through relative
path dependencies rooted at `../../cj_tui`. No absolute developer path is stored
in production configuration.

For this workspace, use the sibling checkout at `../cj_tui` and select:

```text
repository: cj_tui
base branch: feat/tui-foundation-performance
required commit: 848ef9fc7b181b5c2210def9eeb88ca67e7f5d35
root tree: a8b1fd2cbc24378eb11a02c68e0146e6b86e1a7d
API generator blob: 5a8f445424fed0f91513ef1ed4c817ca47d2db10
```

Another developer must clone or update `cj_tui` beside `learn_agent_cj` and use
the required stacked commit as the historical baseline. The actual integration
boundary is also recorded by `agent_tui/cjtui-contract.json`: it pins the
`core`/`markdown` package versions (`0.1.0` for both) and the SHA-256 of the
current cj_tui candidate's line-number-free `docs/api-contract-v1.txt` public
inventory. The current 5Q-I/5R candidate generates exactly 2,449 lines and
188,134 bytes with SHA-256
`ac19052c705ca0460d7f39e8f48e876a146014c6e0bd5e91a4a01812d5630494`.

The commit identifies the clean closure provenance; the contract hash identifies
the consumer-visible API boundary. A live sibling checkout is transport only and
is not an input to contract reconstruction or verification.

`scripts/architecture_gate.sh` runs `scripts/check_cjtui_contract.py`, so a
different sibling checkout cannot silently pass. `CJ_TUI_ROOT` may explicitly
select another development checkout, but it must satisfy the same contract.
When either repository intentionally changes the public boundary, regenerate
the cj_tui contract, review compatibility, and update the consumer digest and
package versions together. A future registry dependency can replace the path
transport without changing this verification model.
