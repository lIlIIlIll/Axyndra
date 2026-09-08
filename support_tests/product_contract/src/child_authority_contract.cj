package product_contract

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_core.*
import agent_product.*
import agent_store.*
import model_adapters.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import tool_runtime.*

func runChildAuthorityContracts(root: String): Unit {
    let workspace = root + "/child-authority"
    Directory.create(workspace, recursive: true)
    let product = openProduct(config: ProductConfig(
        settingsRoot: workspace + "/settings", stateRoot: workspace + "/state",
        workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false, unsafeDirectLaunchForTests: true
    )).value().getOrThrow()
    let session = SessionId("child-authority-parent")
    let launched = product.invokeLocalTool(session, "task", childAuthorityTask("review-child", "reviewer", "review only"))
    expect(launched.isOk(), "reviewer delegation completes")
    expectChildReadOnly(product, "initial reviewer tools respect role ceiling")
    var previous = childAuthorityState(product, session, "review-child")
    for (round in 1..8) {
        product.messageSubagent(session, "review-child", "follow up " + round.toString()).value().getOrThrow()
        previous = waitChildAuthority(product, session, "review-child", previous.runId)
        expect(previous.status == "completed", "admitted wakeup completes under original parent pool")
        expectChildReadOnly(product, "revived reviewer tools never gain write/bash/task")
    }
    let beforeDenied = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().requestId
    product.messageSubagent(session, "review-child", "over original child count").value().getOrThrow()
    previous = waitChildAuthority(product, session, "review-child", previous.runId)
    expect(previous.status == "failed" && previous.error.contains("child.max_children_exceeded") &&
        product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().requestId == beforeDenied,
        "repeat TUI wakeups exhaust the same finite parent pool before a provider call")
    // A real new Hub invocation has its own explicit parent ToolInvocationContext.
    product.invokeLocalTool(session, "hub", objectValue([
        ValueField("op", textValue("send")), ValueField("to", textValue("review-child")),
        ValueField("message", textValue("new parent authority"))
    ])).value().getOrThrow()
    previous = waitChildAuthority(product, session, "review-child", previous.runId)
    expect(previous.status == "completed", "new Hub parent admits its own child execution")
    expectChildReadOnly(product, "new parent cannot widen the retained child role")
    product.close().value().getOrThrow()
    let restored = openProduct(config: ProductConfig(
        settingsRoot: workspace + "/settings", stateRoot: workspace + "/state",
        workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false, unsafeDirectLaunchForTests: true
    )).value().getOrThrow()
    let denied = restored.messageSubagent(session, "review-child", "no invented recovered budget")
    expect(denied.isError() && denied.error().getOrThrow().code == "child.redelegation_required",
        "restored terminal child requires a fresh delegation authority for TUI wakeup")
    restored.invokeLocalTool(session, "hub", objectValue([
        ValueField("op", textValue("send")), ValueField("to", textValue("review-child")),
        ValueField("message", textValue("explicit restored parent"))
    ])).value().getOrThrow()
    expect(waitChildAuthority(restored, session, "review-child", previous.runId).status == "completed",
        "a recovered child can execute under an explicit new Hub parent")
    expectChildReadOnly(restored, "persisted child authority is still role bounded")
    restored.close().value().getOrThrow()
    let database = SqliteDatabase(workspace + "/state/state.db")
    let payload = decodeAgentValue(database.query("SELECT payload FROM task_snapshots WHERE root_thread_id=" +
        sqliteText(session.value))[0].required(0)).value().getOrThrow()
    let rootFields = ArrayList<ValueField>()
    for (field in payload.fields) {
        if (field.name != "subagents") { rootFields.add(field); continue }
        let children = ArrayList<AgentValue>()
        for (child in field.value.items) {
            let fields = ArrayList<ValueField>()
            for (entry in child.fields where entry.name != "capabilities") { fields.add(entry) }
            children.add(objectValue(fields.toArray()))
        }
        rootFields.add(ValueField("subagents", listValue(children.toArray())))
    }
    database.execute("UPDATE task_snapshots SET payload=" +
        sqliteText(encodeAgentValue(objectValue(rootFields.toArray()))) + " WHERE root_thread_id=" + sqliteText(session.value))
    database.close()
    for (_ in 0..2) {
        let legacy = openProduct(config: ProductConfig(
            settingsRoot: workspace + "/settings", stateRoot: workspace + "/state",
            workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false, unsafeDirectLaunchForTests: true
        )).value().getOrThrow()
        expect(legacy.invokeLocalTool(session, "hub", objectValue([
            ValueField("op", textValue("send")), ValueField("to", textValue("review-child")),
            ValueField("message", textValue("unknown old ceiling"))
        ])).isError() && legacy.fixtureProbe.getOrThrow().lastRequest.isNone(),
            "legacy missing ceiling remains unknown across normalization and cannot launch")
        legacy.close().value().getOrThrow()
    }
    runChildFailureAndCancellationContract(root)
    runChildApprovalOutputContract(root)
    runChildApprovalCancellationContracts(root)
    println("child authority, recovery, budget, failure, cancellation and approval contracts passed")
}

func childAuthorityTask(name: String, agent: String, prompt: String): AgentValue {
    objectValue([
        ValueField("context", textValue("child authority contract")),
        ValueField("tasks", listValue([objectValue([
            ValueField("name", textValue(name)), ValueField("agent", textValue(agent)),
            ValueField("task", textValue(prompt))
        ])]))
    ])
}

func childAuthorityState(product: ProductRuntime, session: SessionId, id: String): ProductSubagentSnapshot {
    for (state in product.allSubagents(session) where state.id == id) { return state }
    throw IllegalStateException("missing child " + id)
}

func waitChildAuthority(product: ProductRuntime, session: SessionId, id: String, previous: RunId): ProductSubagentSnapshot {
    for (_ in 0..1000) {
        let state = childAuthorityState(product, session, id)
        if (state.runId.value != previous.value && state.status != "running" && state.status != "blocked") {
            return state
        }
        sleep(Duration.millisecond * 5)
    }
    throw IllegalStateException("child did not settle: " + childAuthorityState(product, session, id).status)
}

func expectChildReadOnly(product: ProductRuntime, message: String): Unit {
    let request = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
    var hasRead = false
    var hasPeer = false
    for (tool in request.tools) {
        if (tool.name == "read") { hasRead = true }
        if (tool.name == "hub") { hasPeer = true }
        expect(tool.name != "write" && tool.name != "bash" && tool.name != "task", message + ": " + tool.name)
    }
    expect(hasRead && hasPeer, message + ": read and peer tools remain usable")
}

func childAuthorityParent(base: AgentRunRequest): AgentRunRequest {
    AgentRunRequest(base.runId, base.sessionId, base.model, base.prompt,
        system: base.system, capabilities: base.capabilities, budget: base.budget,
        approvalModeOverride: Some(ApprovalMode.Yolo), toolContext: base.toolContext)
}

func runChildApprovalOutputContract(root: String): Unit {
    let workspace = root + "/child-approval-output"
    Directory.create(workspace + "/settings", recursive: true)
    File.writeTo(workspace + "/settings/config.yml",
        "approval:\n  mode: ai\n  policy:\n    allow_workspace_writes: true\n".toArray())
    let product = openProduct(config: ProductConfig(
        settingsRoot: workspace + "/settings", stateRoot: workspace + "/state",
        workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.AlwaysAsk,
        approvalRoutingModeOverride: Some(ApprovalRoutingMode.Ai),
        asyncEnabled: false, unsafeDirectLaunchForTests: true
    )).value().getOrThrow()
    File.writeTo(workspace + "/child-approved.txt", "before approval\n".toArray())
    let parent = childAuthorityParent(product.request("fixture task write"))
    expect(product.client.start(parent, { _ => () }).isOk(), "parent delegates approval-controlled child")
    let result = toolResultValue(product.messages(parent.sessionId).value().getOrThrow(),
        "fixture-task-write-call").getOrThrow()
    let output = result.field("results").getOrThrow().items[0].field("output").getOrThrow()
    expect(output.unifiedKind == ValueKind.Text && output.text.startsWith("fixture response for ") &&
        String.fromUtf8(File.readFrom(workspace + "/child-approved.txt")) == "written by child\n",
        "task returns the final assistant text produced after automatic approval continuation; result=" +
            encodeAgentValue(result) + "; file=" + exists(Path(workspace + "/child-approved.txt")).toString())
    product.close().value().getOrThrow()
}

func runChildFailureAndCancellationContract(root: String): Unit {
    let workspace = root + "/child-cancel"
    Directory.create(workspace, recursive: true)
    let product = openProduct(config: ProductConfig(
        settingsRoot: workspace + "/settings", stateRoot: workspace + "/state",
        workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false, unsafeDirectLaunchForTests: true
    )).value().getOrThrow()
    let session = SessionId("child-cancel-parent")
    expect(product.invokeLocalTool(session, "task", childAuthorityTask("failed-child", "reviewer",
        "[plan-review approved fixture] FIXTURE-APPROVED-PLAN-EXECUTION-FAILURE")).isError(),
        "provider failure terminates the child")
    var previous = childAuthorityState(product, session, "failed-child")
    product.messageSubagent(session, "failed-child", "retry after failure").value().getOrThrow()
    previous = waitChildAuthority(product, session, "failed-child", previous.runId)
    expect(previous.status == "completed", "failure settles its reservation before a fresh wakeup")

    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    let enabled = AtomicBool(true)
    product.subscribeSubagents({ event =>
        if (event.kind == "lifecycle" && event.snapshot.id == "cancel-child" &&
            event.snapshot.status == "running" && enabled.load()) {
            enabled.store(false)
            entered.store(true)
            while (!release.load()) { sleep(Duration.millisecond) }
        }
    })
    let beforeCancel = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().requestId
    let launch = spawn { => product.invokeLocalTool(session, "task",
        childAuthorityTask("cancel-child", "reviewer", "cancel before provider")) }
    waitChildGate(entered)
    let cancellation = spawn { => product.cancelSubagent(session, "cancel-child") }
    for (_ in 0..1000) {
        if (childAuthorityState(product, session, "cancel-child").status == "cancelled") { break }
        sleep(Duration.millisecond)
    }
    release.store(true)
    let _ = launch.get()
    cancellation.get().value().getOrThrow()
    let cancelled = childAuthorityState(product, session, "cancel-child")
    expect(cancelled.status == "cancelled" &&
        product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().requestId == beforeCancel,
        "cancellation between generation claim and admission starts no model")
    product.messageSubagent(session, "cancel-child", "fresh execution after cancellation").value().getOrThrow()
    expect(waitChildAuthority(product, session, "cancel-child", cancelled.runId).status == "completed",
        "cancelled prelaunch work does not strand a lease")
    let base = product.request("fixture task batch")
    let parent = AgentRunRequest(base.runId, base.sessionId, base.model, base.prompt,
        system: base.system, capabilities: base.capabilities,
        budget: ResourceBudget(maxChildren: 2, maxConcurrentChildren: 1),
        approvalModeOverride: Some(ApprovalMode.Yolo), toolContext: base.toolContext)
    expect(product.client.start(parent, { _ => () }).isOk() &&
        product.allSubagents(parent.sessionId).size == 2 && product.subagents(parent.sessionId).isEmpty(),
        "parallel task callers serialize through a one-slot parent budget and both settle")
    let sibling = childAuthorityState(product, parent.sessionId, "fixture-batch-a")
    product.messageSubagent(parent.sessionId, sibling.id, "same parent is exhausted").value().getOrThrow()
    expect(waitChildAuthority(product, parent.sessionId, sibling.id, sibling.runId).error.contains("child.max_children_exceeded"),
        "completed sibling leases do not reset the parent's total child count")
    product.close().value().getOrThrow()
}

func waitChildGate(gate: AtomicBool): Unit {
    for (_ in 0..2000) {
        if (gate.load()) { return }
        sleep(Duration.millisecond)
    }
    throw IllegalStateException("child execution gate was not reached")
}

func runChildApprovalCancellationContracts(root: String): Unit {
    for (automatic in [true, false]) {
        let workspace = root + "/child-approval-cancel-" + automatic.toString()
        Directory.create(workspace + "/settings", recursive: true)
        File.writeTo(workspace + "/settings/config.yml",
            "approval:\n  policy:\n    allow_workspace_writes: true\n".toArray())
        let product = openProduct(config: ProductConfig(
            settingsRoot: workspace + "/settings", stateRoot: workspace + "/state",
            workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.AlwaysAsk,
            approvalRoutingModeOverride: Some(if (automatic) { ApprovalRoutingMode.Ai } else { ApprovalRoutingMode.Manual }),
            asyncEnabled: false, unsafeDirectLaunchForTests: true
        )).value().getOrThrow()
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let enabled = AtomicBool(true)
        product.subscribeSubagents({ event =>
            if (event.snapshot.id != "fixture-write-child" || !enabled.load()) { return }
            match (event.event) {
                case Some(value) => match (value.payload) {
                    case AgentEventPayload.TextDelta(_) =>
                        enabled.store(false)
                        entered.store(true)
                        while (!release.load()) { sleep(Duration.millisecond) }
                    case _ => ()
                }
                case None => ()
            }
        })
        File.writeTo(workspace + "/child-approved.txt", "before approval\n".toArray())
        let parent = childAuthorityParent(product.request("fixture task write"))
        let worker = spawn { =>
            let initial = product.client.start(parent, { _ => () })
            if (!automatic && initial.isOk()) {
                product.decideSubagentApproval(parent.sessionId, "fixture-write-child", ApprovalDecision.Approve)
            } else { Result.Ok(()) }
        }
        try {
            waitChildGate(entered)
            let cancellation = spawn { => product.cancelSubagent(parent.sessionId, "fixture-write-child") }
            for (_ in 0..1000) {
                if (childAuthorityState(product, parent.sessionId, "fixture-write-child").status == "cancelled") { break }
                sleep(Duration.millisecond)
            }
            release.store(true)
            let _ = cancellation.get()
        } finally { release.store(true) }
        let _ = worker.get()
        let cancelled = childAuthorityState(product, parent.sessionId, "fixture-write-child")
        expect(cancelled.status == "cancelled", "approval continuation cancellation remains terminal: " + automatic.toString())
        let taskResult = toolResultValue(product.messages(parent.sessionId).value().getOrThrow(),
            "fixture-task-write-call").getOrThrow()
        expect(taskResult.field("results").getOrThrow().items[0].field("exitCode").getOrThrow().number != "0",
            "a cancelled child is not returned as a successful task")
        expect(taskResult.field("results").getOrThrow().items[0].field("stderr").getOrThrow().text != "",
            "unsuccessful child task explains its final state")
        product.messageSubagent(parent.sessionId, "fixture-write-child", "continue after settled cancellation").value().getOrThrow()
        let next = waitChildAuthority(product, parent.sessionId, "fixture-write-child", cancelled.runId)
        expect(next.status == "completed" && next.requests > 0 && next.tokens > 0,
            "automatic/manual continuation cancellation settles its lease before the next execution")
        product.close().value().getOrThrow()
    }
}
