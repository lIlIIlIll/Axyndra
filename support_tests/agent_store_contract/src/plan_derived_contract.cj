package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

func planDerivedAdmissionContract(): Unit {
    beginPlanTestReadFrame204()
    try { planDerivedAdmissionFrame204() } finally { finishPlanTestReadFrame204() }
}
func planDerivedAdmissionFrame204(): Unit {
    println("Plan derived contract phase: canonical pre-effect scope")
    let root = Directory.createTemp(getVariable("TMPDIR").getOrDefault({ => "/tmp" })).toString()
    let database = SqliteDatabase(root + "/plan-derived.db")
    try {
        planPendingPrerequisiteContract(root)
        let threadId = ThreadId("plan-derived-thread")
        let turnId = SemanticTurnId("plan-derived-turn")
        let runId = RunId("plan-derived-run")
        let sink = paidPlanSink204(database)
        let coordinator = ThreadCoordinator(sink.createThread(threadId, "workspace"), sink)
        let active = coordinator.startTurn(turnId, runId, ItemId("plan-derived-user"),
            ThreadItemContent.UserMessage(textMessageParts("read-only program")), createdAtMillis: 1).value().getOrThrow()
        let arguments = objectValue([ValueField("program", textValue("read file"))])
        let rootCall = commitDurableToolCall(database, coordinator, threadId, turnId, runId,
            active.activeEpoch, 1, ItemId("plan-derived-call"), "plan-derived-call", "run_program", arguments, 2)
        let rootPlan = NormalizedOperationPlan("run_program", arguments, [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "plan-derived-root")
        let operations = paidPlanOperationStore204(database)
        let rootId = OperationId("plan-derived-root")
        expect(operations.prepare(rootId, runId, rootCall, rootPlan).isOk() &&
            operations.markExecuting(rootId, runId, rootPlan, 3, false).isOk() &&
            operations.markExecutionHandoff(rootId, runId, threadId, 4).isOk(),
            "ordinary unsupervised root reaches its canonical handoff")
        let contract = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("source"), [], true,
            [planStoreAction("read-source", "read")])])
        let supervisor = paidPlanTestStore204(database)
        expect(supervisor.bind("plan-derived-execution", threadId.value, runId, contract).isOk(),
            "existing canonical Run is bound to its approved contract")
        let childPlan = NormalizedOperationPlan("read", objectValue([]), [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "plan-derived-child", cwd: "/workspace",
            toolVersion: "1", implementationFingerprint: "implementation", schemaDigest: "schema")
        let childId = OperationId("plan-derived-child")
        expect(operations.prepareDerivedOperation(childId, rootId, runId, rootCall,
            "plan-derived-read", childPlan).isOk(), "derived read retains its canonical parent admission")
        expect(operations.markExecuting(childId, runId, childPlan, 5, false).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='plan-derived-child' " +
                "AND kind='operation_execution_handoff'") == 0,
            "derived parent admission cannot replace the approved plan action reservation")
        expect(supervisor.admit(runId, childId, "source", "read-source", childPlan).isOk() &&
            operations.markExecuting(childId, runId, childPlan, 5, false).isOk(),
            "derived operation may proceed only with its own exact approved action admission")
        // Superseding the owner approval invalidates an already executing child
        // before the final handoff, even if its old reservation still exists.
        expect(supervisor.activate("plan-derived-replacement", threadId.value, contract).isOk(),
            "owner may explicitly approve a replacement execution")
        expect(operations.markExecutionHandoff(childId, runId, threadId, 6).isError(),
            "superseded approved execution cannot hand off its derived child")
    } finally {
        database.close()
        let _ = removeIfExists(root, recursive: true)
    }
}

func planPendingPrerequisiteContract(root: String): Unit {
    println("Plan derived contract phase: pending prerequisite freshness")
    let database = SqliteDatabase(root + "/pending-prerequisite.db")
    try {
        let thread = ThreadId("pending-plan-thread")
        let turn = SemanticTurnId("pending-plan-turn")
        let run = RunId("pending-plan-run")
        let sink = paidPlanSink204(database)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let active = coordinator.startTurn(turn, run, ItemId("pending-plan-user"),
            ThreadItemContent.UserMessage(textMessageParts("verify before dependent effects")), createdAtMillis: 1).value().getOrThrow()
        let verify = planPendingFixture(database, coordinator, thread, turn, run, active.activeEpoch,
            1, "verify", "command_probe", OperationEffectClass.ReadOnly)
        let waiting = planPendingFixture(database, coordinator, thread, turn, run, active.activeEpoch,
            2, "waiting", "read", OperationEffectClass.ReadOnly)
        let handoff = planPendingFixture(database, coordinator, thread, turn, run, active.activeEpoch,
            3, "handoff", "read", OperationEffectClass.ReadOnly)
        let mutation = planPendingFixture(database, coordinator, thread, turn, run, active.activeEpoch,
            4, "mutation", "write", OperationEffectClass.WorkspaceMutation)
        let pins = planStoreAction("pins", "command_probe").toolIdentities
        let contract = PlanContract(["/workspace"], [
            PlanExecutionStep(PlanStepId("verify"), [], true, [PlanAction("verify", ["command_probe"],
                ["denied"], OperationEffectClass.ReadOnly, objectValue([]), 1,
                evidence: "exit_zero", toolIdentities: pins)]),
            PlanExecutionStep(PlanStepId("waiting"), ["verify"], true, [planStoreAction("waiting", "read")]),
            PlanExecutionStep(PlanStepId("handoff"), ["verify"], true, [planStoreAction("handoff", "read")]),
            PlanExecutionStep(PlanStepId("mutation"), [], false, [PlanAction("mutation", ["write"],
                ["denied"], OperationEffectClass.WorkspaceMutation, objectValue([]), 1,
                toolIdentities: planStoreAction("write-pin", "write").toolIdentities)])])
        let supervisor = paidPlanTestStore204(database)
        let operations = paidPlanOperationStore204(database)
        requirePendingPlanResult(supervisor.bind("pending-execution", thread.value, run, contract),
            "pending prerequisite contract binds its canonical Run")
        requirePendingPlanResult(supervisor.admit(run, verify.operationId, "verify", "verify", verify.plan),
            "pending prerequisite contract admits canonical verification")
        planStoreSettle(database, verify, OperationOutcome.Completed,
            objectValue([ValueField("exit_code", integerValue(0)), ValueField("timed_out", boolValue(false))]))
        expect(supervisor.admit(run, waiting.operationId, "waiting", "waiting", waiting.plan).isOk() &&
            operations.waitForApproval(waiting.operationId, run).isOk() &&
            supervisor.admit(run, handoff.operationId, "handoff", "handoff", handoff.plan).isOk() &&
            operations.markExecuting(handoff.operationId, run, handoff.plan, 8, false).isOk(),
            "dependent work waits for approval or executor handoff after valid initial evidence")
        expect(supervisor.admit(run, mutation.operationId, "mutation", "mutation", mutation.plan).isOk(),
            "independent approved source mutation reserves its action")
        planStoreSettle(database, mutation, OperationOutcome.Completed, objectValue([]))
        expect(operations.recordApproval("pending-approved", waiting.operationId, run, waiting.plan,
            CapabilitySet(values: waiting.plan.requiredCapabilities), true, "user", None).isOk(),
            "exact approval can settle while prerequisite evidence becomes stale")
        expect(operations.markExecuting(waiting.operationId, run, waiting.plan, 9, true).isError() &&
            operations.markExecutionHandoff(handoff.operationId, run, thread, 9).isError(),
            "fresh prerequisite validation blocks both post-approval execution and final handoff")
        expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id IN " +
            "('pending-operation-waiting','pending-operation-handoff') AND kind='operation_execution_handoff'") == 0,
            "stale dependency evidence never reaches either dependent executor")
    } finally { database.close() }
}

func planPendingFixture(database: SqliteDatabase, coordinator: ThreadCoordinator,
    thread: ThreadId, turn: SemanticTurnId, run: RunId, epoch: Int64, sequence: Int64,
    name: String, tool: String, effect: OperationEffectClass): PlanStoreFixture {
    let callId = "pending-call-" + name
    let call = commitDurableToolCall(database, coordinator, thread, turn, run, epoch, sequence,
        ItemId("pending-item-" + name), callId, tool, objectValue([]), 2)
    let plan = NormalizedOperationPlan(tool, objectValue([]), [Capability(if (effect == OperationEffectClass.ReadOnly) {
        CapabilityKind.WorkspaceRead } else { CapabilityKind.WorkspaceWrite })], effect,
        OperationRetryDisposition.Safe, "pending-binding-" + name, cwd: "/workspace",
        resolvedPaths: if (effect == OperationEffectClass.ReadOnly) { [] } else { ["/workspace/source"] },
        approvedWriteRoots: if (tool == "command_probe") { ["/workspace"] } else { [] },
        toolVersion: "1", implementationFingerprint: "implementation", schemaDigest: "schema")
    let operation = OperationId("pending-operation-" + name)
    expect(paidPlanOperationStore204(database).prepare(operation, run, call, plan).isOk(),
        "pending fixture prepares canonical Operation")
    PlanStoreFixture(run, operation, plan, thread, turn, callId)
}

func requirePendingPlanResult(result: Result<Unit>, message: String): Unit {
    match (result) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException("contract failed: " + message + ": " + error.describe())
    }
}
