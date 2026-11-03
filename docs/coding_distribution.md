# Coding distribution defaults

The explicitly selected Coding package bundles nine independent native packages:
Workspace, Shell, Shell Readonly, model providers, Program, Workflow, Skills, Memory
and Compaction.
Its Skills context provider participates in the following default assembly. On
normal App startup, its adjacent `share/axyndra/distribution.json` selects the
bundled package and the initial context recipe. The App uses its own executable
location, not the current directory, to find this manifest.

The host checks the complete package digest, version and recipe digest before
using the existing local import and enable APIs. It does not add capabilities,
approve a read, start a service, or register a second package inventory. Package
code remains an independent artifact; bundling and default enablement do not
make it a Core build dependency.

The first successful installation writes `plugins/context.json` only when that
file is absent. Existing operator configuration, installed packages and explicit
disable choices are preserved. If the user already installed the selected
namespace, fresh context configuration binds that effective record's actual
package digest. Its version and digest need not equal the bundled release.
Disabled providers keep the host and its management APIs usable; inference
returns a typed provider-unavailable diagnostic until the operator enables or
repairs the selected provider. A compatible independently updated provider can
serve that selection, subject to the normal exact contribution and native
protocol checks. Existing context configuration remains pinned until the user
explicitly changes it. A failed new import, activation, bundle identity check or
default configuration returns a diagnostic rather than silently falling back.

Version 4 context configuration freezes `${settings_root}/...` and
`${workspace_root}/...` against the actual Product roots for each Run. Only those
two exact source-path prefixes are interpreted. Unknown variables, malformed
variables and traversal fail. The configuration file itself remains bound by its
original SHA, while each expanded read plan passes normal capabilities and
approval policy. Earlier absolute-path configuration versions keep their meaning.

Metadata headers, selected Skill bodies and reference declarations flow through
the existing canonical ContextRead sequence before the model. An AlwaysAsk
configuration still requires approval; installing a default provider is not a
read grant. A disabled selected provider or invalid explicit configuration does
not fall back to legacy Skill discovery for that request.

Build a fresh Coding package with `AXYNDRA_DISTRIBUTION=coding scripts/package_candidate.sh`.
The packager defaults to Minimal; `AXYNDRA_DISTRIBUTION=full` selects the seventeen-package
Full recipe. Minimal uses the independently built `agent_minimal` host and publishes
an empty adjacent distribution manifest. See [distribution profiles](distribution-profiles.md).
Explicit Coding/Full recipes and existing operator settings keep their original policy.

The recipes and metadata checks establish package assembly, not the entire Coding
acceptance matrix. The current source has removed the legacy Shell, Eval and Program
tool implementations. Task, Hub and Yield argument parsing, policy and result
assembly now belong to the installed Workflow native package, including its explicit
Hub service families. The Host retains actual child Run admission, frozen plans,
approval, shared budgets, cancellation, canonical messages and Operation/Receipt
settlement; plugin data cannot grant that authority.
Disabling packages must still be verified through the actual installed contribution
path. Source retirement does not establish current compiled or installed runtime
acceptance. Clean relocated App workflows for files, Shell, model, approval,
cancellation, history and recovery remain separate acceptance gates.
No package/default flag grants a capability or establishes an issue completion claim.
