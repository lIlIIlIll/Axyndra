# agent_domain

`agent_domain` contains the protocol-neutral values shared by the product
core, ports, adapters, and clients.

This package deliberately does not depend on JSON, environment variables,
filesystem, process, network, RPC, or terminal libraries. Expected failures
use `Result<T>` and `AgentError`; invariant violations may still throw.

The v3 control-plane contract adds:

- strong correlation IDs and `EventMeta` plus exhaustively matchable
  `AgentEventPayload` variants;
- cooperative parent/child `CancellationSource` and `CancellationToken` values
  with deadlines and callback registration;
- `ExecutionBudget`, cumulative `ExecutionUsage`, and typed budget violations;
- provider-neutral `ModelCapabilities` validation before transport execution.

`AgentEvent` exposes both the typed metadata/payload and the coarse
`kind`/`detail` projection needed by adapters while they migrate to the v3
event vocabulary.
