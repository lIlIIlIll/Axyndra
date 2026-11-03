package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*

// Real Core/startTurn controls with the existing in-memory repository fixtures.
// These prove Core call ordering, not installed-plugin or SQLite authority.
class ChildStartSeen111 {
    var active = false
    var released: Int64 = 0
    var acquisitions: Int64 = 0
    var checks: Int64 = 0
    var models: Int64 = 0
}
class ChildStartLease111 <: ToolExecutionHandoffLease {
    private let seen: ChildStartSeen111
    init(seen: ChildStartSeen111) { this.seen = seen; seen.active = true }
    public func close(): Unit { if (seen.active) { seen.active = false; seen.released++ } }
}
class ChildStartRestriction111 <: AgentRunStartRestriction111 {
    private let expected: AgentRunRequest
    private let seen: ChildStartSeen111
    private let source = CancellationSource()
    private let mode: String
    init(expected: AgentRunRequest, seen: ChildStartSeen111, mode: String) {
        this.expected = expected; this.seen = seen; this.mode = mode
        if (mode == "cancelled") { let _ = source.cancel() }
    }
    public prop cancellation: CancellationToken { get() { source.token } }
    public func acquire(request: AgentRunRequest): Result<ToolExecutionHandoffLease> {
        expect(refEq(request, expected), "actual frozen request reaches the restriction")
        seen.acquisitions++
        if (mode == "before") { return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.child_revoked", "revoked before start")) }
        Result<ToolExecutionHandoffLease>.Ok(ChildStartLease111(seen))
    }
    public func check(request: AgentRunRequest): Result<Unit> {
        expect(refEq(request, expected) && seen.active, "both checks run inside the same short admission lease")
        seen.checks++
        if (mode == "after" && seen.checks == 2) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.child_revoked", "revoked after actual start")) }
        Result.Ok(())
    }
    func close(): Unit { source.close() }
}
class ChildStartModel111 <: ModelPort {
    private let seen: ChildStartSeen111
    init(seen: ChildStartSeen111) { this.seen = seen }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        expect(!seen.active && seen.released == 1, "Registry admission lease is released before actual model dispatch")
        seen.models++
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "child finished")],
            stopReason: "end_turn", responseId: "child-start-answer"))
    }
}
func coreStartRestrictionContract111(): Unit {
    for (mode in ["before", "accepted", "after", "cancelled"]) {
        let seen = ChildStartSeen111(); let runs = MemoryRuns(); let catalog = ToolCatalog()
        let threads = resumeThreadRegistry("child-start-" + mode)
        let core = AgentCore(ChildStartModel111(seen), runs,
            ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog,
            threadRuntimes: Some(threads), modelDecisionRuntime: Some(RecordingModelDecisionPort()))
        let request = AgentRunRequest(RunId("child-start-" + mode), SessionId("child-thread-" + mode), "fixture", "exact child prompt")
        let guard = ChildStartRestriction111(request, seen, mode)
        try {
            let result = core.startRestricted111(request, guard, { _ => () })
            let snapshot = threads.acquire(ThreadId(request.sessionId.value), "agent-core").value().getOrThrow().threadSnapshot()
            expect(seen.acquisitions == (if (mode == "cancelled") { 0 } else { 1 }) && !seen.active, "one actual launch restriction releases its short lease")
            if (mode == "cancelled") {
                expect(result.isError() && result.error().getOrThrow().kind == AgentErrorKind.Cancelled &&
                    runs.find(request.runId).isError() && snapshot.items.isEmpty() && seen.models == 0 &&
                    seen.checks == 0 && seen.released == 0, "actual cancelled parent token admits no canonical child")
            } else if (mode == "before") {
                expect(result.isError() && result.error().getOrThrow().code == "fixture.child_revoked" &&
                    runs.find(request.runId).isError() && snapshot.items.isEmpty() && seen.models == 0 &&
                    seen.checks == 0 && seen.released == 0, "pre-start refusal creates no Run, canonical user Item or provider call")
            } else if (mode == "accepted") {
                expect(result.isOk() && runs.find(request.runId).value().getOrThrow().status == RunState.Completed &&
                    seen.models == 1 && seen.checks == 2 && seen.released == 1,
                    "accepted restriction reaches the original Core/runtime/model completion chain")
            } else {
                expect(result.isError() && result.error().getOrThrow().code == "fixture.child_revoked" &&
                    runs.find(request.runId).value().getOrThrow().status == RunState.Failed &&
                    !snapshot.items.isEmpty() && seen.models == 0 && seen.checks == 2 && seen.released == 1,
                    "post-start refusal retains and settles the actual Run without invoking a provider")
            }
        } finally { guard.close() }
    }
    println("child-start-restriction-contract-111: 4 actual Core order controls PASS")
}
