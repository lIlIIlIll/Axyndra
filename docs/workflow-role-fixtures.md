# Installed workflow roles

The Coding policy recipe selects the independently packaged `workflow` provider
`propose`. The generic distribution installer imports its exact package digest
through the normal registry. Existing operator selections and disabled records
keep their normal precedence. Minimal does not bundle or select this provider.
This selection contains no execution grant: Task admission still intersects the
actual parent capabilities and budget with the role proposal.

`scripts/prepare_workflow_plugin.py` builds a fresh native package and runs all
24 independent protocol cases before returning its path. The Product unit gate
sets that path for the installed-role tests. The release gate exports a separately
verified package for the standalone Product, child-authority, Subagent and RPC
contracts. Their fixtures import and enable the ordinary package and write the
operator's exact policy binding; no Host role factory or fixture executor is used.
Restarts use the persisted registry and policy file.

Relevant validation after integration:

- `python3 scripts/prepare_workflow_plugin.py`
- `python3 scripts/product_unit_gate.py`
- Standalone `product_contract`, `subagent_product_contract` and
  `product_rpc_contract` with `AXYNDRA_WORKFLOW_PLUGIN_PACKAGE` set to the freshly
  verified package, including child authority, guarded approval, cancellation,
  asynchronous tasks, and recovery.
- Packaged Coding execution without checkout or SDK, plus missing/disabled
  Workflow provider diagnostics and preservation of operator configuration.

Source and fixture wiring alone are not runtime evidence. These changes do not
complete migration of Task/Hub tools, Planning/Todo/Goal commands, document
storage, or automatic continuation authority. Those require their separate
implementation, removal of old business paths, and actual integration gates.
