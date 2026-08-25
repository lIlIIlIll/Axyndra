package product_continuation_contract

import agent_core.*
import agent_domain.*
import agent_product.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        Directory.create(root + "/workspace", recursive: true)
        let config = ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/state",
            workspaceRoot: root + "/workspace",
            fixture: true,
            asyncEnabled: false
        )
        let product = openProduct(config: config).value().getOrThrow()
        let runId = RunId("product-restart-run")
        let sessionId = SessionId("product-restart-session")
        let approval = ApprovalRequest(
            OperationId("product-restart-operation"),
            "product-restart-call",
            "write",
            Capability(CapabilityKind.WorkspaceWrite, resource: "result.txt"),
            sessionId: sessionId.value,
            argumentHash: "product-restart-arguments"
        )
        let schema = StructuredOutputSpec(
            "restart_result",
            objectValue([
                ValueField("type", textValue("object")),
                ValueField("properties", objectValue([
                    ValueField("answer", objectValue([
                        ValueField("type", textValue("string"))
                    ]))
                ]))
            ])
        )
        let request = AgentRunRequest(
            runId,
            sessionId,
            "fixture",
            "continue after restart",
            system: "stable system",
            capabilities: CapabilitySet(values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite),
                Capability(CapabilityKind.PeerMessage)
            ]),
            imageInputs: [ModelImage(
                ModelImageSourceKind.Url,
                "https://example.invalid/restart.png",
                detail: ModelImageDetail.High
            )],
            structuredOutput: Some(schema),
            cachePolicy: ModelCachePolicy.StablePrefix,
            cacheKey: "product-stable-prefix",
            parallelToolCalls: true
        )
        let database = SqliteDatabase(root + "/state/state.db")
        database.execute(
            "INSERT INTO threads VALUES ('product-restart-session',0,'workspace','open',1,'product-restart-turn')"
        )
        database.execute(
            "INSERT INTO turns VALUES ('product-restart-turn','product-restart-session',1,'active','pending','product-restart-run')"
        )
        database.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES(" +
                "'product-restart-run','product-restart-session','product-restart-turn',1,'waiting_approval'," +
                "'{}','{}','{}','{}',0,NULL,NULL)"
        )
        let continuationRepository = SqliteRunRepository(database)
        continuationRepository.save(RunSnapshot(
            runId,
            sessionId,
            RunState.WaitingApproval
        )).value().getOrThrow()
        product.persistPendingApproval(request, approval).value().getOrThrow()
        let encodedDurableContinuation = database.query(
            "SELECT payload FROM run_continuations WHERE run_id='product-restart-run'"
        )[0].required(0)
        let encodedContinuation = optionalLegacyPayloadFromDurableContinuation(
            decodeDurableRunContinuation(encodedDurableContinuation)
        ).getOrThrow()
        expect(database.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('runs') WHERE name='continuation'"
        ) == 0 && database.scalarInt(
            "SELECT COUNT(*) FROM legacy_run_continuation_imports"
        ) == 0, "new continuation writes use only the canonical vNext register")
        database.execute(
            "INSERT INTO legacy_run_continuation_imports(run_id,payload) VALUES(" +
                "'product-restart-run'," + sqliteText(encodedContinuation) + ")"
        )
        database.execute(
            "UPDATE legacy_run_continuation_imports SET " +
                "payload=json_set(payload,'$.requested_policy',json('null')) " +
                "WHERE run_id='product-restart-run'"
        )
        expect(continuationRepository.continuation(runId).isError(),
            "legacy migration source rejects divergence from the canonical projection")
        database.execute(
            "UPDATE legacy_run_continuation_imports SET payload=" +
                sqliteText(encodedContinuation) + " WHERE run_id='product-restart-run'"
        )
        expect(continuationRepository.continuation(runId).isOk() && database.scalarInt(
            "SELECT COUNT(*) FROM legacy_run_continuation_imports " +
                "WHERE run_id='product-restart-run'"
        ) == 0, "matching legacy migration source is consumed and cleared atomically")

        database.execute(
            "DELETE FROM run_continuations WHERE run_id='product-restart-run'"
        )
        database.execute(
            "INSERT INTO legacy_run_continuation_imports(run_id,payload) VALUES(" +
                "'product-restart-run'," + sqliteText(encodedContinuation) + ")"
        )
        expect(continuationRepository.continuation(runId).isOk() && database.scalarInt(
            "SELECT COUNT(*) FROM run_continuations WHERE run_id='product-restart-run'"
        ) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM legacy_run_continuation_imports " +
                "WHERE run_id='product-restart-run'"
        ) == 0, "legacy-only database fixture migrates into the canonical register")
        let migratedDurableContinuation = database.query(
            "SELECT payload FROM run_continuations WHERE run_id='product-restart-run'"
        )[0].required(0)
        database.execute(
            "UPDATE run_continuations SET payload='corrupt' " +
                "WHERE run_id='product-restart-run'"
        )
        expect(continuationRepository.continuation(runId).isError(),
            "corrupt preferred vNext continuation fails recovery")
        database.execute(
            "UPDATE run_continuations SET payload=" + sqliteText(migratedDurableContinuation) +
                " WHERE run_id='product-restart-run'"
        )
        database.close()
        product.closeMcp().value().getOrThrow()

        let rebuilt = openProduct(config: config).value().getOrThrow()
        let continuation = rebuilt.pendingContinuation(sessionId)
            .value().getOrThrow().getOrThrow()
        let restored = rebuilt.continuationRequest(continuation, None)
        expect(
            restored.runId.value == runId.value &&
                restored.sessionId.value == sessionId.value &&
                restored.system == "stable system" &&
                restored.imageInputs.size == 1 &&
                restored.imageInputs[0].data == "https://example.invalid/restart.png" &&
                restored.imageInputs[0].detail == ModelImageDetail.High &&
                restored.structuredOutput.isSome() &&
                restored.structuredOutput.getOrThrow().name == "restart_result" &&
                restored.cachePolicy == ModelCachePolicy.StablePrefix &&
                restored.cacheKey == "product-stable-prefix" &&
                restored.capabilities.allows(CapabilityKind.PeerMessage) &&
                restored.parallelToolCalls &&
                restored.toolContext.workspaceRoot == root + "/workspace",
            "product restart restores image, structured output, cache, parallel calls, and fresh ToolContext"
        )
        rebuilt.closeMcp().value().getOrThrow()
        startupRecoveryNeverFallsBackToStartContract(root)
        println("product continuation contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func startupRecoveryNeverFallsBackToStartContract(root: String): Unit {
    let stateRoot = root + "/startup-recovery-state"
    let config = ProductConfig(
        settingsRoot: root + "/startup-recovery-config",
        stateRoot: stateRoot,
        workspaceRoot: root + "/workspace",
        fixture: true,
        asyncEnabled: false
    )
    let initialized = openProduct(config: config).value().getOrThrow()
    initialized.closeMcp().value().getOrThrow()

    let runId = RunId("startup-recovery-run")
    let sessionId = SessionId("startup-recovery-session")
    let attemptId = ModelAttemptId("startup-recovery-attempt-1")
    let semanticId = SemanticModelRequestId("startup-recovery-semantic")
    let database = SqliteDatabase(stateRoot + "/state.db")
    database.execute(
        "INSERT INTO threads VALUES ('startup-recovery-session',0,'workspace','open',1," +
            "'startup-recovery-turn')"
    )
    database.execute(
        "INSERT INTO turns VALUES ('startup-recovery-turn','startup-recovery-session',1," +
            "'active','pending','startup-recovery-run')"
    )
    database.execute(
        "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
            "started_at_millis,finished_at_millis,cancellation_reason) VALUES(" +
            "'startup-recovery-run','startup-recovery-session','startup-recovery-turn',1,'running'," +
            "'{}','{}','{}','{}',0,NULL,NULL)"
    )
    let repository = SqliteRunRepository(database)
    repository.save(RunSnapshot(
        runId, sessionId, RunState.Running, summary: "startup recovery"
    )).value().getOrThrow()
    let requested = RequestedModelPolicy(
        ThinkingLevel.Medium,
        RequestOutputBudget(16384, minVisibleResponseTokens: 1024)
    )
    let capabilities = ModelExecutionCapabilitiesSnapshot(
        "fixture",
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: canonicalNonOffThinkingLevels()
        ),
        200000
    )
    let checkpoint = RunningModelCheckpoint(
        semanticId,
        objectValue([ValueField("model", textValue("fixture"))]),
        "intentionally-tampered-semantic-digest",
        "startup-recovery-wire-digest",
        attemptId,
        attemptId,
        "startup-recovery-turn",
        "startup-recovery-request",
        0
    )
    repository.saveContinuation(RunContinuation(
        RunContinuationKind.RunningModel,
        runId,
        sessionId,
        "fixture",
        "resume instead of starting a replacement run",
        checkpoint,
        requested,
        capabilities,
        thinking: ThinkingLevel.Medium,
        budget: ResourceBudget(maxOutputTokens: 16384),
        contextWindow: 1000000
    )).value().getOrThrow()
    database.close()

    let recovered = openProduct(config: config).value().getOrThrow()
    let application = recovered.applicationSession(sessionId: Some(sessionId))
    let startupResult = application.submit("must not become a replacement start")
    expect(match (startupResult) {
        case Result.Err(error) => error.kind == AgentErrorKind.RecoveryRequired &&
            error.code == "model.checkpoint_digest_mismatch"
        case Result.Ok(_) => false
    } && recovered.fixtureProbe.getOrThrow().lastRequest.isNone(),
        "startup recovery traverses resume and never falls back to start or provider I/O")
    let repeated = application.resumeStartup()
    expect(match (repeated) {
        case Result.Err(error) => error.code == "model.checkpoint_digest_mismatch"
        case Result.Ok(_) => false
    } && recovered.fixtureProbe.getOrThrow().lastRequest.isNone(),
        "failed startup recovery remains fail-closed without a later start fallback")
    recovered.closeMcp().value().getOrThrow()
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}
