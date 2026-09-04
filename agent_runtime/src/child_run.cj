package agent_runtime

import std.collection.*
import std.deriving.*
import std.sync.*
import agent_domain.*

@Derive[Equatable]
public enum ChildWorkspaceMode {
    SharedReadOnly | IsolatedWorktree
}

public class ChildWorkspaceView {
    public let workspaceId: String
    public let root: String
    public let mode: ChildWorkspaceMode

    public init(workspaceId: String, root: String, mode: ChildWorkspaceMode) {
        if (workspaceId.trimAscii() == "" || root.trimAscii() == "") {
            throw IllegalArgumentException("child workspace identity must not be empty")
        }
        this.workspaceId = workspaceId.trimAscii()
        this.root = root.trimAscii()
        this.mode = mode
    }
}

public class ChildRunSpec {
    public let runId: RunId
    public let objective: String
    public let contextProjection: ModelContextProjection
    public let workspace: ChildWorkspaceView
    public let toolSet: ToolSetSnapshot
    public let skillIds: Array<String>
    public let budget: ExecutionBudget
    public let capabilityCeiling: CapabilitySet
    public let cancellation: CancellationToken

    public init(
        runId: RunId,
        objective: String,
        contextProjection: ModelContextProjection,
        workspace: ChildWorkspaceView,
        toolSet: ToolSetSnapshot,
        skillIds: Array<String>,
        budget: ExecutionBudget,
        capabilityCeiling: CapabilitySet,
        cancellation: CancellationToken
    ) {
        if (objective.trimAscii() == "") {
            throw IllegalArgumentException("child run objective must not be empty")
        }
        if (workspace.mode == ChildWorkspaceMode.SharedReadOnly &&
            capabilityCeiling.allows(CapabilityKind.WorkspaceWrite)) {
            throw IllegalArgumentException(
                "read-only child workspace cannot carry workspace-write capability"
            )
        }
        this.runId = runId
        this.objective = objective.trimAscii()
        this.contextProjection = contextProjection
        this.workspace = workspace
        this.toolSet = toolSet
        this.skillIds = skillIds
        this.budget = budget
        this.capabilityCeiling = capabilityCeiling
        this.cancellation = cancellation
    }
}

// Parent receives a bounded product, never the child transcript or mutable
// runtime. Evidence and changes are durable references.
public class ChildRunResult {
    public let summary: String
    public let artifactReferences: Array<String>
    public let evidence: Array<String>
    public let changeSetReference: String
    public let usage: ExecutionUsage

    public init(
        summary: String,
        artifactReferences!: Array<String> = [],
        evidence!: Array<String> = [],
        changeSetReference!: String = "",
        usage!: ExecutionUsage = ExecutionUsage()
    ) {
        if (summary.trimAscii() == "") {
            throw IllegalArgumentException("child run result summary must not be empty")
        }
        this.summary = summary.trimAscii()
        this.artifactReferences = artifactReferences
        this.evidence = evidence
        this.changeSetReference = changeSetReference
        this.usage = usage
    }
}

public func effectiveChildCapabilities(
    parent: CapabilitySet,
    roleCeiling: CapabilitySet,
    sandboxCeiling: CapabilitySet
): CapabilitySet {
    let output = ArrayList<Capability>()
    for (parentValue in parent.values) {
        for (roleValue in roleCeiling.values where roleValue.kind == parentValue.kind) {
            match (intersectCapability(parentValue, roleValue)) {
                case Some(first) =>
                    for (sandboxValue in sandboxCeiling.values where sandboxValue.kind == first.kind) {
                        match (intersectCapability(first, sandboxValue)) {
                            case Some(value) => if (!containsCapability(output, value)) {
                                output.add(value)
                            }
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
    }
    CapabilitySet(values: output.toArray())
}

func intersectCapability(left: Capability, right: Capability): ?Capability {
    if (left.kind != right.kind) { return None }
    if (left.resource == "") { return Some(Capability(left.kind, resource: right.resource)) }
    if (right.resource == "") { return Some(Capability(left.kind, resource: left.resource)) }
    if (left.resource == right.resource) { return Some(left) }
    None
}

func containsCapability(values: ArrayList<Capability>, candidate: Capability): Bool {
    for (value in values where value.kind == candidate.kind &&
        value.resource == candidate.resource) { return true }
    false
}

public class ChildBudgetPoolSnapshot {
    public let totalChildrenStarted: Int64
    public let activeReservations: Int64
    public let reserved: ExecutionUsage
    public let consumed: ExecutionUsage

    public init(
        totalChildrenStarted: Int64,
        activeReservations: Int64,
        reserved: ExecutionUsage,
        consumed: ExecutionUsage
    ) {
        this.totalChildrenStarted = totalChildrenStarted
        this.activeReservations = activeReservations
        this.reserved = reserved
        this.consumed = consumed
    }
}

class ChildBudgetReservationRecord {
    let id: String
    let budget: ExecutionBudget
    init(id: String, budget: ExecutionBudget) { this.id = id; this.budget = budget }
}

public class ChildBudgetLease {
    public let id: String
    public let budget: ExecutionBudget
    private let settleFn: (String, ExecutionUsage) -> Result<ChildBudgetPoolSnapshot>
    private let lock = Mutex()
    private var settled: Bool = false

    public init(
        id: String,
        budget: ExecutionBudget,
        settleFn: (String, ExecutionUsage) -> Result<ChildBudgetPoolSnapshot>
    ) {
        this.id = id
        this.budget = budget
        this.settleFn = settleFn
    }

    public func settle(actual: ExecutionUsage): Result<ChildBudgetPoolSnapshot> {
        lock.lock()
        try {
            if (settled) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "child.budget_lease_settled",
                    "child budget lease was already settled"
                ))
            }
            let result = settleFn(id, actual)
            if (result.isOk()) { settled = true }
            result
        } finally {
            lock.unlock()
        }
    }
}

// Per-parent-run child budget authority. Two ledgers exist by contract and
// MUST NOT be merged:
//
//   1. The parent Run's own ExecutionBudget charges the parent's own turns,
//      tool calls, model requests, cumulative tokens, and cost.
//   2. This pool charges the AGGREGATE of children only: each child reserves
//      its cumulative-token/cost limits up front, settles actual usage on
//      completion, and the pool checks reserved+consumed against the parent's
//      cumulative limits.
//
// `maxCostMicros` / `maxTotalInputTokens` / `maxTotalOutputTokens` are
// therefore Run-local hard limits (see ResourceBudget: "the cumulative Run
// budget"): the parent's own spend does NOT subtract from what children may
// reserve, and children together are capped by the same limits without
// counting the parent's own spend. The theoretical subtree total is up to
// 2x one limit; that is the documented contract, not a leak. Turns, tool
// calls, and model requests are per-Run budgets and never aggregate here.
//
public class ChildBudgetPool {
    private let lock = Mutex()
    private let parent: ExecutionBudget
    private let maxChildren: Int64
    private let maxConcurrentChildren: Int64
    private let reservations = ArrayList<ChildBudgetReservationRecord>()
    private var consumed = ExecutionUsage()
    private var totalChildrenStarted: Int64 = 0

    public init(
        parent: ExecutionBudget,
        maxChildren: Int64,
        maxConcurrentChildren!: Int64 = 4
    ) {
        if (maxChildren < 0 || maxConcurrentChildren < 1) {
            throw IllegalArgumentException("maximum child count must not be negative")
        }
        this.parent = parent
        this.maxChildren = maxChildren
        this.maxConcurrentChildren = maxConcurrentChildren
    }

    public func reserve(id: String, budget: ExecutionBudget): Result<ChildBudgetLease> {
        if (id.trimAscii() == "") {
            return childBudgetError("child.budget_id_empty", "child budget id must not be empty")
        }
        lock.lock()
        try {
            if (totalChildrenStarted >= maxChildren) {
                return childBudgetError(
                    "child.max_children_exceeded", "parent total child budget is exhausted"
                )
            }
            if (reservations.size >= maxConcurrentChildren) {
                return childBudgetError(
                    "child.max_concurrent_children_exceeded",
                    "parent concurrent child budget is exhausted"
                )
            }
            for (item in reservations where item.id == id) {
                return childBudgetError(
                    "child.duplicate_budget_id", "child budget id is already reserved"
                )
            }
            if (parent.maxCostMicros > 0 && budget.maxCostMicros == 0) {
                return childBudgetError(
                    "child.unbounded_cost_reservation",
                    "unbounded child cost cannot be reserved from a bounded parent"
                )
            }
            let reserved = reservedUsageLocked()
            let requested = budgetUsage(budget)
            if (!aggregateUsageFits(parent, addUsage(addUsage(consumed, reserved), requested))) {
                return childBudgetError(
                    "child.parent_budget_exceeded",
                    "child budget reservation exceeds remaining parent budget"
                )
            }
            reservations.add(ChildBudgetReservationRecord(id.trimAscii(), budget))
            totalChildrenStarted += 1
            Result.Ok(ChildBudgetLease(
                id.trimAscii(), budget,
                { leaseId, actual => settleReservation(leaseId, actual) }
            ))
        } finally {
            lock.unlock()
        }
    }

    public func snapshot(): ChildBudgetPoolSnapshot {
        lock.lock()
        try {
            ChildBudgetPoolSnapshot(
                totalChildrenStarted, reservations.size, reservedUsageLocked(), consumed
            )
        } finally {
            lock.unlock()
        }
    }

    private func settleReservation(
        id: String,
        actual: ExecutionUsage
    ): Result<ChildBudgetPoolSnapshot> {
        lock.lock()
        try {
            var index: Int64 = -1
            for (candidate in 0..reservations.size where reservations[candidate].id == id) {
                index = candidate
                break
            }
            if (index < 0) {
                return childBudgetError(
                    "child.budget_reservation_missing", "child budget reservation is missing"
                )
            }
            let reservation = reservations[index]
            if (!usageFits(reservation.budget, actual)) {
                return childBudgetError(
                    "child.actual_usage_exceeds_reservation",
                    "child actual usage exceeds its reserved budget"
                )
            }
            let nextConsumed = addConsumedUsage(consumed, actual)
            if (!aggregateUsageFits(parent, nextConsumed)) {
                return childBudgetError(
                    "child.parent_actual_usage_exceeded",
                    "settling child usage would exceed the parent budget"
                )
            }
            reservations.remove(at: index)
            consumed = nextConsumed
            Result.Ok(ChildBudgetPoolSnapshot(
                totalChildrenStarted, reservations.size, reservedUsageLocked(), consumed
            ))
        } finally {
            lock.unlock()
        }
    }

    private func reservedUsageLocked(): ExecutionUsage {
        var usage = ExecutionUsage()
        for (item in reservations) { usage = addUsage(usage, budgetUsage(item.budget)) }
        usage
    }
}

func budgetUsage(value: ExecutionBudget): ExecutionUsage {
    ExecutionUsage(
        // Parent Run turn/tool ceilings do not imply an aggregate child pool.
        // Reserve only explicitly cumulative dimensions and live concurrency.
        turns: 0,
        toolCalls: 0,
        activeTools: value.maxConcurrentTools,
        inputTokens: value.maxTotalInputTokens,
        outputTokens: value.maxTotalOutputTokens,
        costMicros: value.maxCostMicros
    )
}

func addConsumedUsage(left: ExecutionUsage, right: ExecutionUsage): ExecutionUsage {
    ExecutionUsage(
        turns: saturatedUsageAdd(left.turns, right.turns),
        toolCalls: saturatedUsageAdd(left.toolCalls, right.toolCalls),
        // activeTools is a concurrency peak, not a lifetime charge. Finished
        // child leases release it instead of accumulating it forever.
        activeTools: 0,
        inputTokens: saturatedUsageAdd(left.inputTokens, right.inputTokens),
        outputTokens: saturatedUsageAdd(left.outputTokens, right.outputTokens),
        costMicros: saturatedUsageAdd(left.costMicros, right.costMicros)
    )
}

func addUsage(left: ExecutionUsage, right: ExecutionUsage): ExecutionUsage {
    ExecutionUsage(
        turns: saturatedUsageAdd(left.turns, right.turns),
        toolCalls: saturatedUsageAdd(left.toolCalls, right.toolCalls),
        activeTools: saturatedUsageAdd(left.activeTools, right.activeTools),
        inputTokens: saturatedUsageAdd(left.inputTokens, right.inputTokens),
        outputTokens: saturatedUsageAdd(left.outputTokens, right.outputTokens),
        costMicros: saturatedUsageAdd(left.costMicros, right.costMicros)
    )
}

func saturatedUsageAdd(left: Int64, right: Int64): Int64 {
    if (right > Int64.Max - left) { Int64.Max } else { left + right }
}

func usageFits(budget: ExecutionBudget, usage: ExecutionUsage): Bool {
    usage.turns <= budget.maxTurns && usage.toolCalls <= budget.maxToolCalls &&
        usage.activeTools <= budget.maxConcurrentTools &&
        (budget.maxTotalInputTokens == 0 || usage.inputTokens <= budget.maxTotalInputTokens) &&
        (budget.maxTotalOutputTokens == 0 || usage.outputTokens <= budget.maxTotalOutputTokens) &&
        (budget.maxCostMicros == 0 || usage.costMicros <= budget.maxCostMicros)
}

// A Run's turns, tool-call count, request token ceiling and live tool slots
// belong to that Run. They are not silently reinterpreted as an aggregate
// budget for descendants. Only explicitly cumulative totals roll up.
func aggregateUsageFits(budget: ExecutionBudget, usage: ExecutionUsage): Bool {
    (budget.maxTotalInputTokens == 0 || usage.inputTokens <= budget.maxTotalInputTokens) &&
        (budget.maxTotalOutputTokens == 0 || usage.outputTokens <= budget.maxTotalOutputTokens) &&
        (budget.maxCostMicros == 0 || usage.costMicros <= budget.maxCostMicros)
}

func childBudgetError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
