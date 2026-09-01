package goal_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        verifyRegisteredSchema(root)
        verifyDurableLifecycle(root)
        println("goal contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func verifyRegisteredSchema(root: String): Unit {
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/settings",
        stateRoot: root + "/product-state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    var found = false
    for (definition in product.tools() where definition.name == "goal") {
        found = true
        let schema = definition.inputSchema
        expect(
            schema.field("type").getOrThrow().text == "object" &&
            sameStringSet(propertyNames(schema),
                ["op", "objective", "token_budget"]) &&
            sameStringSet(requiredNames(schema), ["op"]) &&
            sameStringSet(enumNames(
                schema.field("properties").getOrThrow()
                    .field("op").getOrThrow()
            ), ["create", "get", "complete", "resume", "drop"]),
            "goal exposes the reviewed operation schema"
        )
    }
    expect(found, "goal is registered as a real product tool")
    let application = product.applicationSession()
    let empty = application.handle("/goal show").value().getOrThrow()
    let created = application.handle(
        "/goal set Ship through the local command"
    ).value().getOrThrow()
    let budgeted = application.handle(
        "/goal budget 25"
    ).value().getOrThrow()
    let paused = application.handle(
        "/goal pause"
    ).value().getOrThrow()
    let resumed = application.handle(
        "/goal resume"
    ).value().getOrThrow()
    let dropped = application.handle(
        "/goal drop"
    ).value().getOrThrow()
    expect(
        !empty.agentInvoked && empty.text == "No goal set." &&
        !created.agentInvoked &&
        created.text.contains("Goal mode enabled.") &&
        !budgeted.agentInvoked &&
        budgeted.text.contains("Goal budget set to 25.") &&
        paused.text == "Goal mode paused." &&
        resumed.text.contains("Goal mode resumed.") &&
        dropped.text.contains("Goal dropped."),
        "/goal set/show/pause/resume/drop/budget stay local"
    )
    let autonomous = application.handle(
        "/goal set Finish autonomously"
    ).value().getOrThrow()
    let request = product.request(
        "visible user request",
        sessionId: Some(application.id())
    )
    expect(
        autonomous.text.contains("Goal mode enabled.") &&
        request.prompt == "visible user request" &&
        request.system.contains("Finish autonomously") &&
        !request.prompt.contains("<goal-mode>"),
        "active goal context is injected as system context, not user text"
    )
    let finished = application.submit("begin autonomous work")
        .value().getOrThrow()
    let finalGoal = product.goalState(application.id())
        .value().getOrThrow().getOrThrow()
    expect(
        finished.agentInvoked &&
        finalGoal.status == "complete" &&
        finalGoal.tokensUsed > 0,
        "an active goal schedules continuation until the goal tool completes"
    )
}

func verifyDurableLifecycle(root: String): Unit {
    let stateRoot = root + "/goal-state"
    let database = SqliteDatabase(stateRoot + "/state.db")
    let repository = SqliteSessionMetadataRepository(database)
    let runs = SqliteRunRepository(database)
    let runtime = ProductGoalRuntime(repository, runs)
    let session = SessionId("goal-contract")
    let context = ToolInvocationContext(
        RunId("goal-tool-run"),
        session,
        CapabilitySet(values: [
            Capability(CapabilityKind.WorkspaceRead)
        ])
    )

    let empty = invoke(runtime, context, call("empty", "get"))
    expect(
        empty.output.field("goal").getOrThrow().unifiedKind ==
            ValueKind.Null &&
        empty.output.field("content").getOrThrow().text ==
            "No active goal.",
        "get reports an actually empty goal state"
    )

    let created = invoke(
        runtime,
        context,
        call(
            "create",
            "create",
            fields: [
                ValueField(
                    "objective",
                    textValue("Ship the compatible product")
                ),
                ValueField("token_budget", integerValue(10))
            ]
        )
    )
    let createdGoal = created.output.field("goal").getOrThrow()
    expect(
        createdGoal.field("status").getOrThrow().text == "active" &&
        createdGoal.field("tokensUsed").getOrThrow().number == "0" &&
        created.output.field("remainingTokens")
            .getOrThrow().number == "10",
        "create persists an active budgeted goal"
    )
    expect(
        runtime.activePrompt(session).value().getOrThrow()
            .contains("Ship the compatible product"),
        "active goals contribute a continuation prompt"
    )
    expect(
        runtime.execute(
            context,
            call(
                "duplicate",
                "create",
                fields: [
                    ValueField("objective", textValue("replace silently"))
                ]
            )
        ).isError(),
        "create refuses to replace an unfinished goal"
    )

    database.execute(
        "INSERT INTO threads VALUES ('goal-contract',0,'workspace','open',1,NULL)"
    )
    database.execute(
        "INSERT INTO turns VALUES ('goal-turn','goal-contract',1,'completed','goal-user',NULL)"
    )
    database.execute(
        "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
            "started_at_millis,finished_at_millis,cancellation_reason) VALUES(" +
            "'accounted-run','goal-contract','goal-turn',1,'completed','{}','{}','{}','{}',0,1,NULL)"
    )
    expect(
        runs.save(RunSnapshot(
            RunId("accounted-run"),
            session,
            RunState.Completed,
            inputTokens: 7,
            outputTokens: 5
        )).isOk(),
        "run usage fixture is durable"
    )
    let budgetLimited = invoke(
        runtime,
        context,
        call("budget", "get")
    )
    expect(
        budgetLimited.output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "budget-limited" &&
        budgetLimited.output.field("goal").getOrThrow()
            .field("tokensUsed").getOrThrow().number == "12" &&
        budgetLimited.output.field("remainingTokens")
            .getOrThrow().number == "0",
        "real run usage transitions the goal to budget-limited"
    )

    let completed = invoke(
        runtime,
        context,
        call("complete", "complete")
    )
    expect(
        completed.output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "complete" &&
        completed.output.field("completionBudgetReport")
            .getOrThrow().text.contains("tokens used: 12 of 10"),
        "complete returns the final budget report"
    )
    let restarted = ProductGoalRuntime(
        SqliteSessionMetadataRepository(database),
        SqliteRunRepository(database)
    )
    expect(
        invoke(restarted, context, call("restored", "get"))
            .output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "complete",
        "completed goal state survives a runtime restart"
    )

    let replacement = invoke(
        restarted,
        context,
        call(
            "replacement",
            "create",
            fields: [
                ValueField(
                    "objective",
                    textValue("Validate pause and resume")
                )
            ]
        )
    )
    expect(
        replacement.output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "active",
        "a completed goal may be replaced explicitly"
    )
    expect(
        restarted.pause(session).isOk() &&
        invoke(restarted, context, call("paused", "get"))
            .output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "paused",
        "interrupt pause is durable"
    )
    expect(
        invoke(restarted, context, call("resume", "resume"))
            .output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "active",
        "resume reactivates the same goal"
    )
    expect(
        restarted.pauseRestoredActive(session).isOk() &&
        invoke(restarted, context, call("restored-pause", "get"))
            .output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "paused",
        "restoring an active thread pauses it rather than pretending it runs"
    )

    let target = SessionId("goal-copy")
    expect(
        repository.copy(session, target).isOk() &&
        invoke(
            ProductGoalRuntime(repository, runs),
            ToolInvocationContext(
                RunId("copy-run"),
                target,
                CapabilitySet(values: [
                    Capability(CapabilityKind.WorkspaceRead)
                ])
            ),
            call("copy", "get")
        ).output.field("goal").getOrThrow()
            .field("objective").getOrThrow().text ==
                "Validate pause and resume",
        "session forks copy durable goal metadata"
    )

    let dropped = invoke(
        restarted,
        context,
        call("drop", "drop")
    )
    expect(
        dropped.output.field("goal").getOrThrow()
            .field("status").getOrThrow().text == "dropped" &&
        invoke(restarted, context, call("after-drop", "get"))
            .output.field("goal").getOrThrow().unifiedKind == ValueKind.Null,
        "drop returns the terminal goal and clears active persistence"
    )

    expect(
        runtime.execute(
            context,
            call(
                "bad-budget",
                "create",
                fields: [
                    ValueField("objective", textValue("invalid")),
                    ValueField("token_budget", integerValue(0))
                ]
            )
        ).isError() &&
        runtime.execute(
            context,
            call("bad-op", "pause")
        ).isError(),
        "goal rejects invalid budgets and unknown operations"
    )
    database.close()
}

func invoke(
    runtime: ProductGoalRuntime,
    context: ToolInvocationContext,
    value: ToolCall
): ToolResult {
    match (runtime.execute(context, value)) {
        case Result.Ok(result) => result
        case Result.Err(error) =>
            throw IllegalStateException(
                error.code + ": " + error.message
            )
    }
}

func call(
    id: String,
    op: String,
    fields!: Array<ValueField> = []
): ToolCall {
    let values = ArrayList<ValueField>()
    values.add(ValueField("op", textValue(op)))
    for (field in fields) { values.add(field) }
    ToolCall(id, "goal", objectValue(values.toArray()))
}

func propertyNames(schema: AgentValue): Array<String> {
    let properties = schema.field("properties").getOrThrow()
    let result = ArrayList<String>()
    for (field in properties.fields) { result.add(field.name) }
    result.toArray()
}

func requiredNames(schema: AgentValue): Array<String> {
    let result = ArrayList<String>()
    for (value in schema.field("required").getOrThrow().items) {
        result.add(value.text)
    }
    result.toArray()
}

func enumNames(schema: AgentValue): Array<String> {
    let result = ArrayList<String>()
    for (value in schema.field("enum").getOrThrow().items) {
        result.add(value.text)
    }
    result.toArray()
}

func sameStringSet(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (candidate in left) {
        var found = false
        for (expected in right) {
            if (candidate == expected) {
                found = true
                break
            }
        }
        if (!found) { return false }
    }
    true
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
