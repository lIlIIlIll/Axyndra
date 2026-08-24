# agent_ports

`agent_ports` declares replaceable boundaries used by `agent_core`.
Implementations belong to adapters. Interfaces return domain `Result<T>` and
must not expose provider, persistence, RPC, or terminal serialization types.
