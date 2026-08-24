# agent_client

Stable typed boundary for every frontend.

- `InProcessAgentClient` is the default embedding path.
- `RpcAgentClient` uses a typed transport adapter.
- CLI, CI, and the future `cjtui` integration depend on `AgentClient`, never
  `AgentCore`, provider JSON, or persistence internals.
