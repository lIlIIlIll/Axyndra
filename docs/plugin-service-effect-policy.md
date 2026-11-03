# Operator-declared read-only service tools

Managed services default to mutating, never-replayed tool calls. An operator can
declare exact local contribution IDs read-only in the service's existing host
configuration. Remote tool annotations, plugin configuration, manifests and
directory responses cannot make this declaration.

For a channel service, put `"read_only_tools": ["local-tool-id"]` on the selected
service in `plugins/lifecycle.json`. For an HTTP service, put the same field on
the selected plugin in `plugins/services.json`, alongside `requests` and
`credentials`. The field is optional; an empty or absent list preserves the
default. Values must be unique local identifiers, at most 128 bytes each and
64 entries. Wildcards, namespace paths and unknown fields are rejected.

The assertion is part of the immutable operator configuration and actual
approved startup plan. It does not grant process, network, workspace or secret
access, remove startup approval, or expand a capability ceiling. Altering the
configuration invalidates the retained grant; start a new service under the
changed configuration. A prepared call keeps its bound directory, schema,
implementation and grant rather than acquiring newer permissions.

For the MCP client plugin, a remote name maps to `t_` followed by its UTF-8
SHA-256 hex digest. Migrate an old `trusted_read_only_tools` entry only after
reviewing that exact remote operation. Do not copy `readOnlyHint` annotations
into operator grants automatically. The host uses the same local-identity
mechanism for every service plugin and does not interpret MCP names.

The canonical root is `ReadOnly` with `NeverReplay`; channel writes and HTTP
POST children retain `ExternalMutation` and `NeverReplay`. Durable admission
proves the actual completed startup, exact owner/service/tool, current parent,
and unchanged grant again through execution and settlement. This does not
admit a service call from a Program/derived root or enable automatic retries.
After actual transport I/O, a cancellation or incomplete result stays unknown,
including for a declared read-only root. A cancellation before I/O keeps the
ordinary runtime semantics.

Read-only effects do not preapprove network access. With the default
`approval.ask_on_network: true`, an HTTP root still requires confirmation even
when its exact local tool is declared read-only. An operator may explicitly set
`approval.ask_on_network: false` in host configuration; capability ceilings,
startup approval and exact child authorization still apply. The actual POST
child remains mutating and never replayed.

Validation passed two configuration cases, six actual Product transport cases
and 84 durable Store scenarios. The HTTP cases verify both the default network
confirmation with zero `tools/call` frames and the explicit operator policy used
for execution, cancellation and annotation rejection. They are covered by the
complete 291-case Product run in [the migration record](plugin-first-migration.md).
This does not establish remote semantic truth or authorize automatic retry.
