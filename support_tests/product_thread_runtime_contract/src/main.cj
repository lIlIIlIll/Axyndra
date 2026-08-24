package product_thread_runtime_contract

import std.fs.*
import agent_app_protocol.*
import agent_domain.*
import agent_product.*
import agent_skills.*
import agent_store.*

main(): Int64 {
    let root = Directory.createTemp("/tmp").toString()
    try {
        let workspace = root + "/workspace"
        Directory.create(workspace, recursive: true)
        File.writeTo(workspace + "/input.txt", "durable tool input\n".toArray())
        let stateRoot = root + "/state"
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: stateRoot,
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false,
            compactionOverride: Some(ProductCompactionSettings(
                keepRecentMessages: 2
            ))
        )).value().getOrThrow()
        let sessionId = SessionId("durable-product-thread")
        let result = product.applicationSession(sessionId: Some(sessionId))
            .submit("persist the canonical owner")
        let firstRunState = match (result) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) => runStateName(snapshot.status)
                case None => "missing_snapshot"
            }
            case Result.Err(error) => "error:" + error.code + ":" + error.message
        }
        expect(result.isOk() && result.value().getOrThrow().snapshot.isSome() &&
            result.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "fixture product completes its Run; actual=" + firstRunState)
        let toolSessionId = SessionId("durable-product-tool-thread")
        let toolResult = product.applicationSession(sessionId: Some(toolSessionId))
            .submit("fixture vnext read")
        expect(toolResult.isOk() && toolResult.value().getOrThrow().snapshot.isSome() &&
            toolResult.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "fixture product completes a canonical Tool trajectory")
        expect(product.compactSession(toolSessionId).value().getOrThrow() > 0,
            "product compaction creates a disposable canonical checkpoint")
        let resumed = product.applicationSession(sessionId: Some(toolSessionId))
            .submit("continue after checkpoint")
        expect(resumed.isOk() && match (product.fixtureProbe.getOrThrow().lastRequest) {
            case Some(request) => !request.messages.isEmpty() &&
                request.messages[0].blocks[0].text.startsWith(
                    "[Compacted canonical Thread through Item"
                )
            case None => false
        }, "next Turn projects checkpoint plus high-fidelity suffix")
        let productSkill = SkillActivation(
            SkillDescriptor(
                "product-review", "product-review", "Product review skill", ["review"],
                "skill://product-review"
            ),
            "Use the Product SkillStack contract."
        )
        let skillResult = product.client.start(
            product.request(
                "run active skill",
                sessionId: Some(SessionId("durable-product-skill-thread")),
                skillStack: SkillStackSnapshot([productSkill], [])
            ),
            {_ => ()}
        )
        expect(skillResult.isOk() && match (product.fixtureProbe.getOrThrow().lastRequest) {
            case Some(request) => request.system.contains("<active_skills ") &&
                request.system.contains("Use the Product SkillStack contract.")
            case None => false
        }, "Product freezes an explicit active SkillStack into the Run")
        let pageEvent = product.appCommand(AppCommand(
            AppCommandMeta(AppCommandId("contract-page"), 1),
            AppCommandPayload.LoadItemsPage(ThreadId(sessionId.value), 0, 16)
        ))
        expect(match (pageEvent) {
            case Result.Ok(event) => match (event.payload) {
                case AppEventPayload.ItemsPage(page) =>
                    page.threadId.value == sessionId.value && page.items.size == 2 &&
                    event.meta.threadRevision == page.threadRevision
                case _ => false
            }
            case Result.Err(_) => false
        }, "Product serves canonical Thread pages through the typed App Protocol")
        expect(!product.appCommand(AppCommand(
            AppCommandMeta(
                AppCommandId("stale-page"),
                2,
                expectedThreadRevision: Some(0)
            ),
            AppCommandPayload.LoadItemsPage(ThreadId(sessionId.value), 0, 16)
        )).isOk(), "App Protocol rejects a stale expected Thread revision")
        let seededSession = SessionId("durable-product-seed-thread")
        expect(product.replaceMessages(seededSession, [
            ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "seeded user history")
            ]),
            ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Unknown, text: "durable system note")
            ])
        ]).isOk(), "Product creates offline canonical history through the seed boundary")
        expect(product.replaceMessages(seededSession, [
            ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "must not overwrite")
            ])
        ]).isError(), "Product cannot replace an existing canonical Thread")
        let forkedSession = SessionId("durable-product-fork-thread")
        expect(product.forkSession(seededSession, forkedSession).isOk(),
            "Product fork clones canonical Items without a provider DTO round trip")
        expect(product.replaceMessages(
            SessionId("durable-product-invalid-seed"),
            [ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Text, text: "assistant first")
            ])]
        ).isError(), "Product rejects invalid offline transcript ownership")
        product.close().value().getOrThrow()

        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let thread = database.query(
                "SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id='" +
                    sessionId.value + "'"
            )
            expect(thread.size == 1 && thread[0].required(0) == "3" &&
                thread[0].required(1) == "",
                "completed product Turn releases the durable Thread owner")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM turns WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM runs WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'"
            ) == 1,
                "product composition persists matching completed Turn and Run records")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + sessionId.value + "'"
            ) == 2,
                "product composition persists canonical user and assistant Items")
            let toolThread = database.query(
                "SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id='" +
                    toolSessionId.value + "'"
            )
            expect(toolThread.size == 1 && toolThread[0].required(0) == "8" &&
                toolThread[0].required(1) == "",
                "Tool trajectory and resumed Turn settle under one Thread owner")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + toolSessionId.value + "'"
            ) == 6 && database.scalarInt(
                "SELECT COUNT(*) FROM operations JOIN runs ON runs.id=operations.run_id " +
                    "WHERE runs.thread_id='" + toolSessionId.value + "' AND operations.state='committed'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts JOIN operations " +
                    "ON operations.id=operation_receipts.operation_id JOIN runs " +
                    "ON runs.id=operations.run_id WHERE runs.thread_id='" + toolSessionId.value +
                    "' AND operation_receipts.outcome='completed'"
            ) == 1,
                "Product ToolCall commits one Operation, Receipt and paired ToolResult")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM context_checkpoints WHERE thread_id='" +
                    toolSessionId.value + "'"
            ) == 1,
                "checkpoint is durable while canonical Items remain unmodified")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + seededSession.value + "'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + forkedSession.value + "'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + forkedSession.value +
                    "' AND kind='system_note'"
            ) == 1,
                "canonical fork preserves non-provider semantic Items exactly")
        } finally {
            database.close()
        }
        println("product Thread Runtime contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}
