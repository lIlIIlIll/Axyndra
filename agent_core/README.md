# agent_core

The only product-level agent loop. It coordinates canonical conversation
history, one model execution primitive, capability-gated tools, approval
pause/resume, run state, bounded events, and resource budgets.

It contains no provider JSON, terminal UI, or RPC framing.
