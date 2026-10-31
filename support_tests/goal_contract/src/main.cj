package goal_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*

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
    let product = openGoalContractProduct(root + "/registered")
    let namespace = installGoalContractWorkflow(product)
    try {
    var found = false
    for (definition in product.tools() where definition.name == "plugin." + namespace + ".goal") {
        found = true
        let schema = definition.inputSchema
        expect(
            schema.field("type").getOrThrow().text == "object" &&
            sameStringSet(propertyNames(schema),
                ["command_args", "op", "legacy_document", "legacy_sha256",
                    "objective", "token_budget", "method"]) &&
            schema.field("required").isNone() &&
            sameStringSet(enumNames(
                schema.field("properties").getOrThrow()
                    .field("op").getOrThrow()
            ), ["create", "get", "complete", "resume", "drop", "migrate_legacy"]),
            "goal exposes the reviewed operation schema"
        )
    }
    expect(found, "goal is registered as a real product tool")
    let application = product.applicationSession()
    let empty = requireGoalContractResult(application.handle("/goal show"))
    let created = requireGoalContractResult(application.handle(
        "/goal set Ship through the local command"))
    let budgeted = requireGoalContractResult(application.handle("/goal budget 25"))
    let paused = requireGoalContractResult(application.handle("/goal pause"))
    let resumed = requireGoalContractResult(application.handle("/goal resume"))
    let dropped = requireGoalContractResult(application.handle("/goal drop"))
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
    let autonomous = requireGoalContractResult(application.handle(
        "/goal set Finish autonomously"))
    let request = product.request(
        "visible user request",
        sessionId: Some(application.id())
    )
    match (product.client.start(request, { _ => () })) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException(error.describe())
    }
    let observed = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
    expect(
        autonomous.text.contains("Goal mode enabled.") &&
        request.prompt == "visible user request" &&
        observed.system.contains("Finish autonomously") &&
        !request.prompt.contains("<goal-mode>"),
        "active goal context is injected as system context, not user text"
    )
    // Complete only in the continuation Run, not the first model reply.
    let queuedCompletion = AtomicBool(false)
    application.subscribe({ event =>
        if (event.kind == AgentEventKind.Completed && !queuedCompletion.load()) {
            queuedCompletion.store(true)
            product.fixtureProbe.getOrThrow().enqueueToolCallReply(
                "autonomous-complete", "plugin." + namespace + ".goal",
                objectValue([ValueField("op", textValue("complete"))]))
        }
    })
    let finished = requireGoalContractResult(application.submit("begin autonomous work"))
    let finalGoal = product.goalState(application.id())
        .value().getOrThrow().getOrThrow()
    expect(
        finished.agentInvoked && queuedCompletion.load() &&
        finalGoal.status == "complete" &&
        finalGoal.tokensUsed > 0,
        "an active goal schedules continuation until the goal tool completes"
    )
    } finally { let _ = product.close() }
}

func verifyDurableLifecycle(root: String): Unit {
    let durableRoot = root + "/durable"
    var product = openGoalContractProduct(durableRoot)
    let namespace = installGoalContractWorkflow(product)
    let database = SqliteDatabase(product.stateRoot + "/state.db")
    let repository = SqliteSessionMetadataRepository(database)
    let runs = SqliteRunRepository(database)
    let session = SessionId("goal-contract")
    let results = ArrayList<ToolResult>()
    try {
        let empty = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "empty", "get"))
        results.add(empty)
        expect(
            empty.output.field("goal").getOrThrow().unifiedKind == ValueKind.Null &&
            empty.output.field("content").getOrThrow().text == "No active goal.",
            "get reports an actually empty goal state"
        )

        let created = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "create", "create", fields: [
                ValueField("objective", textValue("Ship the compatible product")),
                ValueField("token_budget", integerValue(10))
            ]))
        results.add(created)
        let createdGoal = created.output.field("goal").getOrThrow()
        expect(
            createdGoal.field("status").getOrThrow().text == "active" &&
            createdGoal.field("tokensUsed").getOrThrow().asNumberText() == "0" &&
            created.output.field("remainingTokens").getOrThrow().asNumberText() == "10" &&
            product.goalState(session).value().getOrThrow().getOrThrow().objective ==
                "Ship the compatible product",
            "create persists an active budgeted goal"
        )
        let prompt = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "prompt", "get",
                fields: [ValueField("method", textValue("prompt"))]))
        results.add(prompt)
        expect(
            prompt.output.text.contains("Ship the compatible product"),
            "active goals contribute a continuation prompt"
        )
        expect(
            rejectedGoalOperation(product, namespace, session,
                goalContractToolCall(namespace, "duplicate", "create", fields: [
                    ValueField("objective", textValue("replace silently"))
                ])) &&
            product.goalState(session).value().getOrThrow().getOrThrow().objective ==
                "Ship the compatible product",
            "create refuses to replace an unfinished goal"
        )

        // Canonical calls already created the Thread/Turn/Run. Populate the
        // same durable usage repository without fabricating another Turn.
        let usageRun = RunId(database.query(
            "SELECT id FROM runs WHERE thread_id=? AND state='completed' " +
                "ORDER BY started_at_millis DESC,id DESC LIMIT 1",
            [SqlParameter.Text(session.value)]
        )[0].required(0))
        expect(
            runs.save(RunSnapshot(
                usageRun, session, RunState.Completed,
                inputTokens: 7, outputTokens: 5
            )).isOk(),
            "run usage fixture is durable"
        )
        let budgetLimited = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "budget", "get"))
        results.add(budgetLimited)
        expect(
            budgetLimited.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "budget-limited" &&
            budgetLimited.output.field("goal").getOrThrow()
                .field("tokensUsed").getOrThrow().asNumberText() == "12" &&
            budgetLimited.output.field("remainingTokens").getOrThrow().asNumberText() == "0",
            "real run usage transitions the goal to budget-limited"
        )
        let completed = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "complete", "complete"))
        results.add(completed)
        expect(
            completed.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "complete" &&
            completed.output.field("completionBudgetReport").getOrThrow()
                .text.contains("tokens used: 12 of 10"),
            "complete returns the final budget report"
        )

        let _ = product.close()
        product = openGoalContractProduct(durableRoot)
        let restored = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "restored", "get"))
        results.add(restored)
        expect(
            restored.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "complete" &&
            product.goalState(session).value().getOrThrow().getOrThrow().status == "complete",
            "completed goal state survives a runtime restart"
        )
        let replacement = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "replacement", "create", fields: [
                ValueField("objective", textValue("Validate pause and resume"))
            ]))
        results.add(replacement)
        expect(
            replacement.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "active",
            "a completed goal may be replaced explicitly"
        )
        let paused = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "pause", "get",
                fields: [ValueField("method", textValue("pause"))]))
        results.add(paused)
        let pausedGoal = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "paused", "get"))
        results.add(pausedGoal)
        expect(
            pausedGoal.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "paused" &&
            !product.goalState(session).value().getOrThrow().getOrThrow().enabled,
            "interrupt pause is durable"
        )
        let resumed = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "resume", "resume"))
        results.add(resumed)
        expect(
            resumed.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "active" &&
            resumed.output.field("goal").getOrThrow().field("id").getOrThrow().text ==
                replacement.output.field("goal").getOrThrow().field("id").getOrThrow().text,
            "resume reactivates the same goal"
        )

        let _ = product.close()
        product = openGoalContractProduct(durableRoot)
        // The former pauseRestoredActive call was explicit too. The selected
        // tool's restore method runs that same policy after a real restart.
        let restoredPause = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "restore", "get",
                fields: [ValueField("method", textValue("restore"))]))
        results.add(restoredPause)
        let afterRestore = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "restored-pause", "get"))
        results.add(afterRestore)
        expect(
            afterRestore.output.field("goal").getOrThrow()
                .field("status").getOrThrow().text == "paused" &&
            !product.goalState(session).value().getOrThrow().getOrThrow().enabled,
            "restoring an active thread pauses it rather than pretending it runs"
        )

        let target = SessionId("goal-copy")
        let copied = repository.copy(session, target)
        let copy = completedGoalOperation(product, namespace, target,
            goalContractToolCall(namespace, "copy", "get"))
        results.add(copy)
        expect(
            copied.isOk() &&
            copy.output.field("goal").getOrThrow().field("objective").getOrThrow().text ==
                "Validate pause and resume",
            "session forks copy durable goal metadata"
        )
        let dropped = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "drop", "drop"))
        results.add(dropped)
        let afterDrop = completedGoalOperation(product, namespace, session,
            goalContractToolCall(namespace, "after-drop", "get"))
        results.add(afterDrop)
        expect(
            dropped.output.field("goal").getOrThrow().field("status").getOrThrow().text == "dropped" &&
            afterDrop.output.field("goal").getOrThrow().unifiedKind == ValueKind.Null &&
            product.goalState(session).value().getOrThrow().isNone(),
            "drop returns the terminal goal and clears active persistence"
        )
        expect(
            rejectedGoalOperation(product, namespace, session,
                goalContractToolCall(namespace, "bad-budget", "create", fields: [
                    ValueField("objective", textValue("invalid")),
                    ValueField("token_budget", integerValue(0))
                ])) &&
            rejectedGoalOperation(product, namespace, session,
                goalContractToolCall(namespace, "bad-op", "pause")),
            "goal rejects invalid budgets and unknown operations"
        )
    } finally {
        for (result in results) { result.releasePayload() }
        let _ = product.close()
        database.close()
    }
}

func propertyNames(schema: AgentValue): Array<String> {
    let properties = schema.field("properties").getOrThrow()
    let result = ArrayList<String>()
    for (field in properties.fields) { result.add(field.name) }
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
