# run_control

Application-level run facade. It owns run lookup and event paging while
delegating all agent behavior to the unique `AgentRunner`/`AgentCore`.

`RunStateMachine` is the centralized authority for v3 lifecycle transitions;
illegal, stale, and sequence-exhausted transitions return typed errors instead
of mutating state. `ExecutionBudgetLedger` atomically reserves cumulative
turn/tool/token/cost usage and live tool concurrency, and rejected reservations
never partially consume the budget.
