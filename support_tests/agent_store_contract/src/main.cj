package agent_store_contract

import std.fs.*
import std.env.*
import std.process.*
import std.convert.*
import std.collection.*
import std.time.*
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_store.*
import agent_skills.*

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size == 5 && arguments[1] == "--crash-recovery-transaction") {
        return crashRecoveryTransactionWorker(
            arguments[2], arguments[3], arguments[4]
        )
    }
    threadCodecContract()
    runRequestSnapshotProjectionContract()
    v19ToV20ContinuationColumnContract()
    let root = Directory.createTemp("/tmp").toString()
    let path = root + "/state.db"
    let database = SqliteDatabase(path)
    try {
        expect(database.scalarInt("PRAGMA user_version") == 21, "schema is migrated")
        expect(database.query("PRAGMA journal_mode")[0].required(0).toAsciiLower() == "wal",
            "WAL mode is durable configuration")
        expect(database.scalarInt("PRAGMA foreign_keys") == 1, "foreign keys are enabled")
        expect(database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN (" +
                "'threads','turns','items','runs','run_journal','operations'," +
                "'operation_receipts','approvals','capability_grants','audit_events'," +
                "'context_checkpoints','memories','artifacts')"
        ) == 13 && database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='run_model_usage'"
        ) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN (" +
                "'model_attempts','model_decisions','model_decision_blocks'," +
                "'model_decision_usage','canonical_decision_items','decision_operations')"
        ) == 6, "all vNext durable record families exist")

        database.execute(
            "INSERT INTO threads VALUES ('thread',0,'workspace','open',1,NULL)"
        )
        var rolledBack = false
        try {
            database.transaction { transaction =>
                transaction.execute(
                    "INSERT INTO capability_grants VALUES ('grant','thread','{}',NULL)"
                )
                throw IllegalStateException("fault injection")
            }
        } catch (_: Exception) { rolledBack = true }
        expect(rolledBack, "fault injection escapes transaction")
        expect(database.scalarInt("SELECT COUNT(*) FROM capability_grants") == 0,
            "failed state transition rolls back atomically")

        database.transaction { transaction =>
            transaction.execute(
                "INSERT INTO capability_grants VALUES ('grant','thread','{}',NULL)"
            )
        }
        expect(database.scalarInt("SELECT COUNT(*) FROM capability_grants") == 1,
            "successful transaction commits atomically")
        expect(database.query("SELECT " + sqliteText("a'b"))[0].required(0) == "a'b",
            "SQLite text literals are escaped")
        typedParameterContract(database)
        operationCommitContract(database)
        durableThreadCoordinatorContract(database)
        recoveryPlannerContract(database)
        checkpointStoreContract(database)
        runtimeRecoveryContract(database)
        threadPagingContract(database)
        threadSeedContract(database)
        semanticStoreContract(database)
        inboxStepContract(database)
    } finally {
        database.close()
    }

    let reopened = SqliteDatabase(path)
    try {
        expect(reopened.scalarInt("SELECT COUNT(*) FROM capability_grants") == 1,
            "committed metadata survives reopen")
        expect(reopened.scalarInt("SELECT COUNT(*) FROM teams") == 1 &&
            reopened.scalarInt("SELECT COUNT(*) FROM team_members") == 2 &&
            reopened.scalarInt("SELECT COUNT(*) FROM team_messages") == 1,
            "Team roster, board and mailbox survive process reopen")
        expect(reopened.query("PRAGMA integrity_check")[0].required(0) == "ok",
            "SQLite integrity check passes")
        let recovered = SqliteThreadCommitSink(reopened).loadThread(ThreadId("durable-thread"))
        expect(recovered.thread.revision == 5 && recovered.items.size == 4 &&
            recovered.turns[0].state == TurnState.Failed && recovered.activeRunId.isNone() &&
            reopened.query(
                "SELECT outcome FROM operation_receipts WHERE id='durable-receipt'"
            )[0].required(0) == "completed",
            "process reopen reconstructs recovery terminal and preserves operation Receipts")
    } finally {
        reopened.close()
    }
    repeatedCrashRecoveryContract(root)
    modelDecisionDurabilityContract()
    totalContinuationCrashContract()
    v6ToV16MigrationContract()
    v7ToV16MigrationContract()
    sqliteAppendRestoreBenchmark()
    println("agent store contract passed")
    0
}

func runRequestSnapshotProjectionContract(): Unit {
    let base = sealDurableRunContinuation(DurableRunContinuationV1(
        RunId("snapshot-run"), LaneId("main"), SemanticTurnId("snapshot-turn"), 0,
        RunExecutionPhase.Accepted(DurablePhaseState(objectValue([]))),
        CompositionSnapshotId("snapshot-composition"),
        ModelLaneSnapshotId("snapshot-model-lane")
    ))
    let snapshot = objectValue([
        ValueField("version", integerValue(4)),
        ValueField("marker", textValue("stable"))
    ])
    let projected = withRunRequestSnapshotProjection(base, snapshot)
    expect(optionalRunRequestSnapshotFromDurableContinuation(projected).isSome() &&
        optionalLegacyPayloadFromDurableContinuation(projected).isNone(),
        "new Run continuation projections are structured canonical snapshots")
    snapshot.fields[1] = ValueField("marker", textValue("tampered"))
    var rejected = false
    try {
        let _ = optionalRunRequestSnapshotFromDurableContinuation(projected)
    } catch (_: Exception) { rejected = true }
    expect(rejected, "Run request snapshot digest rejects in-memory payload tampering")

    let largeSnapshot = objectValue([
        ValueField("version", integerValue(4)),
        ValueField("marker", textValue(String.fromUtf8(
            Array<Byte>(32768, repeat: b'x')
        )))
    ])
    let largeProjected = withRunRequestSnapshotProjection(base, largeSnapshot)
    let encodedLarge = encodeDurableRunContinuation(largeProjected)
    expect(decodeDurableRunContinuation(encodedLarge).digest == largeProjected.digest,
        "large structured Run snapshots preserve exact canonical decoding")
}

func typedParameterContract(database: SqliteDatabase): Unit {
    database.execute(
        "CREATE TABLE parameter_contract(" +
            "text_value TEXT NOT NULL, int_value INTEGER NOT NULL, " +
            "blob_value BLOB NOT NULL, null_value TEXT)"
    )
    let hostile = "quote ' and SQL ); DROP TABLE threads; --"
    database.execute(
        "INSERT INTO parameter_contract VALUES (?,?,?,?)",
        [
            SqlParameter.Text(hostile),
            SqlParameter.Int64Value(9223372036854775807),
            SqlParameter.Blob([0x00, 0x27, 0xFF]),
            SqlParameter.Null
        ]
    )
    let row = database.query(
        "SELECT text_value,int_value,hex(blob_value),null_value " +
            "FROM parameter_contract WHERE text_value=?",
        [SqlParameter.Text(hostile)]
    )[0]
    expect(row.required(0) == hostile, "bound text is not interpreted as SQL")
    expect(row.required(1) == "9223372036854775807", "bound Int64 preserves range")
    expect(row.required(2) == "0027FF", "bound Blob preserves exact bytes")
    expect(row[3].isNone(), "bound Null remains SQL null")
    expect(database.scalarInt("SELECT COUNT(*) FROM threads") == 1,
        "bound hostile text cannot mutate schema or prior rows")
}

func sqliteAppendRestoreBenchmark(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let path = root + "/benchmark.db"
    let database = SqliteDatabase(path)
    let sink = SqliteThreadCommitSink(database)
    let coordinator = ThreadCoordinator(
        sink.createThread(ThreadId("benchmark-thread"), "workspace"), sink
    )
    let started = coordinator.startTurn(
        SemanticTurnId("benchmark-turn"), RunId("benchmark-run"),
        ItemId("benchmark-item-0"),
        ThreadItemContent.UserMessage(textMessageParts("start"))
    ).value().getOrThrow()
    let appendStarted = MonoTime.now()
    for (sequence in 1..5000) {
        let decision = coordinator.commit(ResultEnvelope(
            ThreadId("benchmark-thread"), SemanticTurnId("benchmark-turn"),
            RunId("benchmark-run"), started.activeEpoch, sequence,
            ThreadItemDraft(
                ItemId("benchmark-item-" + sequence.toString()),
                ThreadItemContent.AssistantMessage(textMessageParts("x")),
                ItemProvenance("model", runId: Some(RunId("benchmark-run")))
            )
        ))
        expect(isStoreCommitted(decision), "SQLite benchmark append commits")
    }
    let appendMillis = (MonoTime.now() - appendStarted).toMilliseconds()
    database.close()

    let restoreDatabase = SqliteDatabase(path)
    let restoreStarted = MonoTime.now()
    let restored = SqliteThreadCommitSink(restoreDatabase).loadThread(
        ThreadId("benchmark-thread")
    )
    let restoreMillis = (MonoTime.now() - restoreStarted).toMilliseconds()
    expect(restored.items.size == 5000 && restored.thread.revision == 5000,
        "SQLite benchmark restore preserves all canonical Items")
    restoreDatabase.close()
    println("vNext SQLite benchmark items=5000 append_ms=" +
        appendMillis.toString() + " restore_ms=" + restoreMillis.toString())
}

func v19ToV20ContinuationColumnContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let path = root + "/v19.db"
    let seed = SqliteDatabase(path)
    try {
        seed.execute("ALTER TABLE runs ADD COLUMN continuation TEXT")
        seed.execute("ALTER TABLE run_continuations DROP COLUMN active_attempt_id")
        seed.execute("DROP TABLE legacy_run_continuation_imports")
        seed.execute(
            "INSERT INTO threads VALUES ('v19-thread',0,'workspace','open',1,'v19-turn')"
        )
        seed.execute(
            "INSERT INTO turns VALUES ('v19-turn','v19-thread',1,'active','v19-user','v19-run')"
        )
        seed.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot," +
                "budget,usage,started_at_millis,continuation) VALUES(" +
                "'v19-run','v19-thread','v19-turn',1,'waiting_approval','{}','{}','{}','{}'," +
                "1,'legacy-v19-payload')"
        )
        seed.execute("PRAGMA user_version=19")
    } finally { seed.close() }

    let migrated = SqliteDatabase(path)
    try {
        expect(migrated.scalarInt("PRAGMA user_version") == 21,
            "v19 database migrates through schema v21")
        expect(migrated.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('runs') WHERE name='continuation'"
        ) == 0, "v20 removes the legacy continuation column from canonical Runs")
        expect(migrated.query(
            "SELECT payload FROM legacy_run_continuation_imports WHERE run_id='v19-run'"
        )[0].required(0) == "legacy-v19-payload",
            "v20 preserves the legacy payload in its explicit one-shot import table")
        expect(migrated.query("PRAGMA foreign_key_check").isEmpty(),
            "v19 to v20 migration preserves foreign-key integrity")
    } finally { migrated.close() }
}

func v6ToV16MigrationContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let path = root + "/v6.db"
    let seed = SqliteDatabase(path)
    try {
        removeV10Schema(seed)
        // Build an exact pre-v7 shape from the preceding schema: the fresh
        // database already contains every v1-v6 object, so remove only v7's
        // additive tables and set the historical version marker.
        seed.execute("DROP TABLE decision_operations")
        seed.execute("DROP TABLE canonical_decision_items")
        seed.execute("DROP TABLE model_decision_usage")
        seed.execute("DROP TABLE model_decision_blocks")
        seed.execute("DROP TABLE model_decisions")
        seed.execute("DROP TABLE model_attempts")
        seed.execute("DROP TABLE app_run_event_heads")
        seed.execute("ALTER TABLE app_run_events RENAME TO app_run_events_v8")
        seed.execute(
            "CREATE TABLE app_run_events (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE," +
                "sequence INTEGER NOT NULL,payload TEXT NOT NULL,accounting INTEGER NOT NULL," +
                "created_at_millis INTEGER NOT NULL,PRIMARY KEY(run_id,sequence))"
        )
        seed.execute("DROP TABLE app_run_events_v8")
        seed.execute("PRAGMA user_version=6")
    } finally { seed.close() }

    let migrated = SqliteDatabase(path)
    try {
        expect(migrated.scalarInt("PRAGMA user_version") == 21,
            "v6 database migrates through schema v7 to v21")
        expect(migrated.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN (" +
                "'model_attempts','model_decisions','model_decision_blocks'," +
                "'model_decision_usage','canonical_decision_items','decision_operations')"
        ) == 6, "v6 to v8 creates every Model Attempt Runtime table")
        expect(migrated.query("PRAGMA foreign_key_check").isEmpty(),
            "v6 to v8 migration passes foreign-key validation")
    } finally { migrated.close() }
}

func v7ToV16MigrationContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let path = root + "/v7.db"
    let seed = SqliteDatabase(path)
    try {
        removeV10Schema(seed)
        seed.execute("DROP TABLE app_run_event_heads")
        seed.execute("ALTER TABLE app_run_events RENAME TO app_run_events_v8")
        seed.execute(
            "CREATE TABLE app_run_events (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE," +
                "sequence INTEGER NOT NULL,payload TEXT NOT NULL,accounting INTEGER NOT NULL," +
                "created_at_millis INTEGER NOT NULL,PRIMARY KEY(run_id,sequence))"
        )
        seed.execute("DROP TABLE app_run_events_v8")
        seed.execute("ALTER TABLE model_attempts DROP COLUMN provider_terminal_at_millis")
        seed.execute("ALTER TABLE model_attempts DROP COLUMN dispatch_started_at_millis")
        seed.execute("ALTER TABLE model_attempts DROP COLUMN replay_barrier")
        seed.execute("ALTER TABLE model_attempts DROP COLUMN dispatch_state")
        seed.execute("ALTER TABLE model_attempts DROP COLUMN wire_policy_digest")
        seed.execute("ALTER TABLE model_attempts DROP COLUMN semantic_request_digest")
        seed.execute("PRAGMA user_version=7")
    } finally { seed.close() }
    let migrated = SqliteDatabase(path)
    try {
        expect(migrated.scalarInt("PRAGMA user_version") == 21,
            "v7 database migrates through schema v8 to v21")
        expect(migrated.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('app_run_events') WHERE name IN (" +
                "'sequence_start','sequence_end','event_class','stream_key','delta_count','char_count')"
        ) == 6, "v7 to v8 adds stream retention metadata")
        expect(migrated.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('model_attempts') WHERE name IN (" +
                "'semantic_request_digest','wire_policy_digest','dispatch_state','replay_barrier'," +
                "'dispatch_started_at_millis','provider_terminal_at_millis')"
        ) == 6, "v7 to v9 adds model attempt dispatch and replay metadata")
        expect(migrated.query("PRAGMA foreign_key_check").isEmpty(),
            "v7 to v8 migration passes foreign-key validation")
    } finally { migrated.close() }
}

func modelDecisionDurabilityContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/decision.db")
    try {
        let sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(
            sink.createThread(ThreadId("decision-thread"), "workspace"), sink
        )
        let active = coordinator.startTurn(
            SemanticTurnId("decision-turn"),
            RunId("decision-run"),
            ItemId("decision-user"),
            ThreadItemContent.UserMessage(textMessageParts("decide")),
            createdAtMillis: 1
        ).value().getOrThrow()
        let store = SqliteModelDecisionStore(database)
        let attempt = DurableModelAttempt(
            ModelAttemptId("attempt-1"),
            SemanticModelRequestId("request-1"),
            RunId("decision-run"),
            1,
            ModelAttemptLifecycle.Streaming,
            objectValue([ValueField("thinking", textValue("low"))]),
            "initial",
            10,
            11,
            providerRequestId: "provider-request-1"
        )
        expect(store.createAttempt(attempt).isOk(), "Model Attempt persists")
        expect(store.createAttempt(attempt).isOk(), "Model Attempt persistence is idempotent")
        let decision = ModelDecision(
            ModelDecisionId("decision-1"),
            attempt.id,
            attempt.semanticRequestId,
            [DurableDecisionBlock(
                DecisionBlockId("decision-block-1"),
                0,
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "provider-call-1",
                    name: "read",
                    arguments: objectValue([ValueField("path", textValue("README.md"))])
                ),
                scopedToolCallId: Some(ScopedToolCallId("scoped-call-1"))
            )],
            TerminalEvidence(
                "messages",
                "message_stop",
                rawStopReason: "tool_use",
                messageTerminalObserved: true,
                streamEofObserved: true,
                adapterVersion: "llm4cj-wire-v2"
            ),
            DecisionValidationStatus.Validated,
            CompletionDisposition.ToolUse,
            DecisionOutcome.ToolCalls,
            "content-hash-1",
            "replay-hash-1",
            1,
            providerId: "provider-1",
            providerResponseId: "response-1",
            createdAtMillis: 12
        )
        expect(store.persistValidatedDecision(decision).isOk(), "validated Decision persists")
        expect(store.persistValidatedDecision(decision).isOk(), "Decision persistence is idempotent")
        expect(
            database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM model_decision_blocks") == 1,
            "Decision and stable blocks commit atomically"
        )
        expect(
            store.finalizeUsage(decision.id, ModelUsage(
                inputTokens: 5,
                outputTokens: 2,
                source: ModelUsageSource.ProviderStreamFinal,
                evidence: Some(ModelUsageEvidence(
                    "anthropic_messages", "message_stop", providerResponseId: "response-1"
                ))
            ), 13).isOk(),
            "late usage finalizes separately"
        )
        let recovered = store.loadDecision(decision.id)
        expect(
            recovered.decision.id.value == decision.id.value &&
                recovered.decision.blocks[0].id.value == "decision-block-1" &&
                recovered.decision.blocks[0].scopedToolCallId.getOrThrow().value ==
                    "scoped-call-1" &&
                recovered.usage.getOrThrow().outputTokens == 2 &&
                recovered.usage.getOrThrow().evidence.getOrThrow().eventKind == "message_stop" &&
                recovered.usage.getOrThrow().evidence.getOrThrow().providerResponseId == "response-1",
            "durable Decision, stable block identities and separate usage recover"
        )
        expect(
            store.uncommittedDecision(RunId("decision-run")).value().getOrThrow()
                .getOrThrow().id.value == decision.id.value,
            "durable Decision remains recoverable before canonical projection"
        )
        let projection = ResultBatchEnvelope(
            ThreadId("decision-thread"),
            SemanticTurnId("decision-turn"),
            RunId("decision-run"),
            active.activeEpoch,
            1,
            [ThreadItemDraft(
                ItemId("decision-tool-item"),
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId("provider-call-1"),
                    "read",
                    objectValue([ValueField("path", textValue("README.md"))])
                ),
                ItemProvenance("model", runId: Some(RunId("decision-run"))),
                createdAtMillis: 14,
                sourceDecisionId: Some(decision.id),
                sourceDecisionBlockId: Some(DecisionBlockId("decision-block-1"))
            )]
        )
        let projected = coordinator.commitBatch(projection)
        expect(
            match (projected) {
                case SemanticBatchCommitDecision.Committed(_, _) => true
                case _ => false
            } && database.scalarInt(
                "SELECT COUNT(*) FROM canonical_decision_items WHERE decision_id='decision-1'"
            ) == 1 && store.loadDecision(decision.id).canonicalCommittedAtMillis.getOrThrow() == 14,
            "complete Decision projects and binds canonically in one transaction"
        )
        expect(
            match (coordinator.commitBatch(projection)) {
                case SemanticBatchCommitDecision.Committed(_, _) => true
                case SemanticBatchCommitDecision.Stale(_) => true
                case SemanticBatchCommitDecision.Rejected(_) => false
            } && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE id='decision-tool-item'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM canonical_decision_items WHERE decision_id='decision-1'"
            ) == 1,
            "reprojecting one durable Decision preserves canonical IDs and bindings"
        )
        let sources = store.committedToolCallSources(RunId("decision-run"))
            .value().getOrThrow()
        let committed = coordinator.attestCommittedToolCalls(sources)
            .value().getOrThrow()[0]
        let operation = DurableOperationStore(database)
        let operationId = OperationId("decision-operation-1")
        let plan = NormalizedOperationPlan(
            "read", objectValue([ValueField("path", textValue("README.md"))]),
            [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe,
            "decision-operation-binding"
        )
        expect(operation.prepare(
            operationId, RunId("decision-run"), committed, plan
        ).isOk() && operation.prepare(
            operationId, RunId("decision-run"), committed, plan
        ).isOk() && database.scalarInt(
            "SELECT COUNT(*) FROM decision_operations WHERE decision_id='decision-1'"
        ) == 1, "committed ToolCall prepares exactly one source-bound Operation")
        let immutablePlan = database.query(
            "SELECT normalized_plan,implementation_fingerprint,replay_disposition," +
                "reserved_receipt_id,reserved_result_item_id FROM operation_effect_records " +
                "WHERE operation_id='decision-operation-1'"
        )[0]
        expect(immutablePlan.required(1) == "decision-operation-binding" &&
            immutablePlan.required(3) == "receipt-decision-operation-1" &&
            immutablePlan.required(4) == "result-decision-operation-1" &&
            database.query(
                "SELECT state,revision FROM operation_state_registers " +
                    "WHERE operation_id='decision-operation-1'"
            )[0].required(0) == "prepared",
            "Operation effect record freezes implementation and reserved result identities")
        expect(operation.waitForApproval(
            operationId, RunId("decision-run")
        ).isOk() && database.query(
            "SELECT state FROM operation_state_registers " +
                "WHERE operation_id='decision-operation-1'"
        )[0].required(0) == "waiting_approval" && database.query(
            "SELECT normalized_plan FROM operation_effect_records " +
                "WHERE operation_id='decision-operation-1'"
        )[0].required(0) == immutablePlan.required(0),
            "Operation state advances in a separate register without mutating its fact")

        let abandoned = DurableModelAttempt(
            ModelAttemptId("attempt-abandoned"), SemanticModelRequestId("request-abandoned"),
            RunId("decision-run"), 1, ModelAttemptLifecycle.Streaming,
            objectValue([]), "initial", 20, 21
        )
        expect(store.createAttempt(abandoned).isOk() &&
            store.abandonOpenAttempts(RunId("decision-run"), 22).isOk() &&
            database.query(
                "SELECT lifecycle FROM model_attempts WHERE id='attempt-abandoned'"
            )[0].required(0) == "abandoned",
            "open Attempt is durably abandoned after process/request loss")
        expect(store.createAttempt(DurableModelAttempt(
            ModelAttemptId("attempt-retry"), SemanticModelRequestId("request-abandoned"),
            RunId("decision-run"), 2, ModelAttemptLifecycle.Streaming,
            objectValue([]), "retry", 23, 23,
            parentAttemptId: Some(abandoned.id)
        )).isOk(), "an abandoned Attempt permits a new auditable child Attempt")
    } finally {
        database.close()
    }
}

// T014 runs the real test executable as a child, kills it after the recovery
// write has entered an IMMEDIATE SQLite transaction but before commit, then
// reopens WAL state. Repeating every C1-C7 boundary proves recovery attempts
// do not accumulate duplicate durable evidence when recovery itself crashes.
func repeatedCrashRecoveryContract(root: String): Unit {
    let executable = getCommandLine()[0]
    for (phase in 1..8) {
        let path = root + "/crash-c" + phase.toString() + ".db"
        let database = SqliteDatabase(path)
        prepareCrashBoundary(database, phase)
        database.close()
        for (attempt in 1..4) {
            let marker = root + "/crash-c" + phase.toString() + "-" +
                attempt.toString() + ".ready"
            let process = launch(
                executable,
                [
                    "--crash-recovery-transaction", path, marker,
                    phase.toString()
                ],
                workingDirectory: Path("."),
                stdIn: ProcessRedirect.Discard,
                stdOut: ProcessRedirect.Discard,
                stdErr: ProcessRedirect.Discard
            )
            waitForCrashMarker(marker, process)
            process.terminate(force: true)
            let _ = process.wait()
            let reopened = SqliteDatabase(path)
            try {
                expect(reopened.query("PRAGMA integrity_check")[0].required(0) == "ok",
                    "C" + phase.toString() + " WAL survives a killed recovery transaction")
                expect(
                    crashBoundaryCardinality(reopened, phase) ==
                        expectedCrashBoundaryCardinality(phase),
                    "C" + phase.toString() + " killed recovery preserves record cardinality"
                )
                expectRecovery(
                    OperationRecoveryPlanner(reopened).inspect(
                        ThreadId("crash-thread-" + phase.toString())
                    ),
                    crashBoundaryAction(phase),
                    "C" + phase.toString() + " recovery action is stable after repeated crash"
                )
            } finally {
                reopened.close()
            }
            let _ = removeIfExists(marker)
        }
    }
}

func prepareCrashBoundary(database: SqliteDatabase, phase: Int64): Unit {
    let suffix = phase.toString()
    let threadId = ThreadId("crash-thread-" + suffix)
    let turnId = SemanticTurnId("crash-turn-" + suffix)
    let runId = RunId("crash-run-" + suffix)
    let callItemId = ItemId("crash-call-" + suffix)
    let sink = SqliteThreadCommitSink(database)
    let coordinator = ThreadCoordinator(
        sink.createThread(threadId, "workspace"), sink
    )
    let active = coordinator.startTurn(
        turnId, runId, ItemId("crash-user-" + suffix),
        ThreadItemContent.UserMessage(textMessageParts("recover")),
        createdAtMillis: 1
    ).value().getOrThrow()
    let committed = commitDurableToolCall(
        database, coordinator, threadId, turnId, runId, active.activeEpoch, 1,
        callItemId, "crash-call-" + suffix, "mutate", objectValue([]), 2
    )
    if (phase == 1) { return }

    let operationId = OperationId("crash-operation-" + suffix)
    let plan = crashBoundaryPlan()
    let operations = DurableOperationStore(database)
    operations.prepare(operationId, runId, committed, plan).value().getOrThrow()
    if (phase == 2) {
        operations.waitForApproval(operationId, runId).value().getOrThrow()
        return
    }
    operations.markExecuting(
        operationId, runId, plan, 3, false
    ).value().getOrThrow()
    if (phase == 3) { return }
    operations.markExecutionHandoff(
        operationId, runId, threadId, 4
    ).value().getOrThrow()
    if (phase == 4) { return }
    database.execute(
        "INSERT INTO operation_receipts VALUES (" +
            sqliteText("crash-receipt-" + suffix) + "," +
            sqliteText(operationId.value) + ",'completed'," +
            sqliteText(encodeStoredValue(objectValue([
                ValueField("ok", boolValue(true))
            ]))) + "," + sqliteText(encodeStoredValue(objectValue([]))) + ",5)"
    )
    if (phase == 5) { return }
    database.execute(
        "UPDATE operations SET state='committed',revision=revision+1 WHERE id=" +
            sqliteText(operationId.value)
    )
    if (phase == 6) { return }
    let result = ThreadItemContent.ToolResult(
        CanonicalToolCallId("crash-call-" + suffix), operationId,
        "crash-receipt-" + suffix,
        objectValue([ValueField("ok", boolValue(true))]), false
    )
    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO items " +
                "(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (" +
                sqliteText("crash-result-" + suffix) + "," +
                sqliteText(threadId.value) + "," + sqliteText(turnId.value) +
                ",3,'tool_result'," + sqliteText(encodeStoredThreadContent(result)) + "," +
                sqliteText(encodeStoredProvenance(ItemProvenance(
                    "operation", runId: Some(runId), operationId: Some(operationId)
                ))) + ",6)"
        )
        transaction.execute(
            "UPDATE threads SET revision=revision+1,next_item_ordinal=4 WHERE id=" +
                sqliteText(threadId.value)
        )
        transaction.execute(
            "UPDATE runs SET state='waiting_external' WHERE id=" + sqliteText(runId.value)
        )
    }
}

func commitDurableToolCall(
    database: SqliteDatabase,
    coordinator: ThreadCoordinator,
    threadId: ThreadId,
    turnId: SemanticTurnId,
    runId: RunId,
    epoch: Int64,
    sequence: Int64,
    itemId: ItemId,
    providerCallId: String,
    name: String,
    arguments: AgentValue,
    createdAtMillis: Int64
): CommittedToolCallRef {
    let identity = itemId.value
    let attempt = DurableModelAttempt(
        ModelAttemptId("attempt-" + identity),
        SemanticModelRequestId("request-" + identity),
        runId, 1, ModelAttemptLifecycle.Streaming,
        objectValue([ValueField("reason", textValue("contract"))]),
        "contract", createdAtMillis, createdAtMillis,
        providerRequestId: "provider-request-" + identity
    )
    let store = SqliteModelDecisionStore(database)
    store.createAttempt(attempt).value().getOrThrow()
    let blockId = DecisionBlockId("block-" + identity)
    let scopedId = ScopedToolCallId("scoped-" + identity)
    let decision = ModelDecision(
        ModelDecisionId("decision-" + identity), attempt.id, attempt.semanticRequestId,
        [DurableDecisionBlock(
            blockId, 0,
            ModelBlock(
                ModelBlockKind.ToolCall, callId: providerCallId,
                name: name, arguments: arguments
            ),
            scopedToolCallId: Some(scopedId)
        )],
        TerminalEvidence(
            "contract", "message_stop", rawStopReason: "tool_use",
            messageTerminalObserved: true, streamEofObserved: true,
            adapterVersion: "contract-v1"
        ),
        DecisionValidationStatus.Validated, CompletionDisposition.ToolUse,
        DecisionOutcome.ToolCalls, "content-" + identity, "replay-" + identity, 1,
        providerId: "contract", providerResponseId: "response-" + identity,
        createdAtMillis: createdAtMillis
    )
    store.persistValidatedDecision(decision).value().getOrThrow()
    let projected = coordinator.commitBatch(ResultBatchEnvelope(
        threadId, turnId, runId, epoch, sequence,
        [ThreadItemDraft(
            itemId,
            ThreadItemContent.ToolCall(
                CanonicalToolCallId(providerCallId), name, arguments
            ),
            ItemProvenance("model", runId: Some(runId)),
            createdAtMillis: createdAtMillis,
            sourceDecisionId: Some(decision.id),
            sourceDecisionBlockId: Some(blockId)
        )]
    ))
    expect(match (projected) {
        case SemanticBatchCommitDecision.Committed(_, _) => true
        case _ => false
    }, "durable ToolCall fixture projects canonically")
    let sources = store.committedToolCallSources(runId).value().getOrThrow()
    let matching = ArrayList<CommittedToolCallSource>()
    for (source in sources where source.canonicalItemId.value == itemId.value) {
        matching.add(source)
    }
    coordinator.attestCommittedToolCalls(matching.toArray()).value().getOrThrow()[0]
}

func crashBoundaryPlan(): NormalizedOperationPlan {
    NormalizedOperationPlan(
        "mutate", objectValue([]), [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )],
        OperationEffectClass.WorkspaceMutation,
        OperationRetryDisposition.Never,
        "crash-binding", resolvedPaths: ["/workspace/file"]
    )
}

func crashRecoveryTransactionWorker(
    path: String,
    marker: String,
    phaseText: String
): Int64 {
    let phase = Int64.parse(phaseText)
    let suffix = phase.toString()
    let database = SqliteDatabase(path)
    database.transaction { transaction =>
        match (phase) {
            case 1 => transaction.execute(
                "INSERT INTO operations VALUES (" +
                    sqliteText("crash-operation-" + suffix) + "," +
                    sqliteText("crash-run-" + suffix) + "," +
                    sqliteText("crash-call-" + suffix) +
                    ",'plan','capability','resource','workspace_mutation','never',NULL,'prepared',1)"
            )
            case 2 => transaction.execute(
                "INSERT INTO approvals VALUES (" +
                    sqliteText("crash-approval-" + suffix) + "," +
                    sqliteText("crash-operation-" + suffix) +
                    ",'digest','ceiling','approved','recovery',NULL)"
            )
            case 3 => transaction.execute(
                "INSERT INTO audit_events " +
                    "(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (" +
                    sqliteText("crash-thread-" + suffix) + "," +
                    sqliteText("crash-run-" + suffix) + "," +
                    sqliteText("crash-operation-" + suffix) +
                    ",'operation_execution_handoff','{}',7)"
            )
            case 4 => transaction.execute(
                "INSERT INTO operation_receipts VALUES (" +
                    sqliteText("crash-receipt-" + suffix) + "," +
                    sqliteText("crash-operation-" + suffix) +
                    ",'unknown','detail','verification',7)"
            )
            case 5 => transaction.execute(
                "UPDATE operations SET state='committed',revision=revision+1 WHERE id=" +
                    sqliteText("crash-operation-" + suffix)
            )
            case 6 => crashWorkerAppendResult(transaction, suffix)
            case 7 => transaction.execute(
                "UPDATE runs SET state='running' WHERE id=" +
                    sqliteText("crash-run-" + suffix)
            )
            case _ => throw IllegalArgumentException("invalid crash boundary")
        }
        File.writeTo(marker, "transaction-open".toArray())
        sleep(Duration.second * 30)
    }
    database.close()
    0
}

func crashWorkerAppendResult(
    transaction: SqliteTransaction,
    suffix: String
): Unit {
    let operationId = OperationId("crash-operation-" + suffix)
    let result = ThreadItemContent.ToolResult(
        CanonicalToolCallId("crash-call-" + suffix), operationId,
        "crash-receipt-" + suffix,
        objectValue([ValueField("ok", boolValue(true))]), false
    )
    transaction.execute(
        "INSERT INTO items " +
            "(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (" +
            sqliteText("crash-result-" + suffix) + "," +
            sqliteText("crash-thread-" + suffix) + "," +
            sqliteText("crash-turn-" + suffix) +
            ",3,'tool_result'," + sqliteText(encodeStoredThreadContent(result)) + "," +
            sqliteText(encodeStoredProvenance(ItemProvenance(
                "operation", runId: Some(RunId("crash-run-" + suffix)),
                operationId: Some(operationId)
            ))) + ",7)"
    )
    transaction.execute(
        "UPDATE threads SET revision=revision+1,next_item_ordinal=4 WHERE id=" +
            sqliteText("crash-thread-" + suffix)
    )
    transaction.execute(
        "UPDATE runs SET state='waiting_external' WHERE id=" +
            sqliteText("crash-run-" + suffix)
    )
}

func waitForCrashMarker(marker: String, process: SubProcess): Unit {
    var attempts: Int64 = 0
    while (!exists(Path(marker)) && process.isAlive() && attempts < 500) {
        sleep(Duration.millisecond * 10)
        attempts += 1
    }
    expect(exists(Path(marker)) && process.isAlive(),
        "crash worker reaches its open transaction before termination")
}

func crashBoundaryCardinality(database: SqliteDatabase, phase: Int64): String {
    let suffix = phase.toString()
    database.scalarInt("SELECT COUNT(*) FROM operations WHERE run_id=" +
        sqliteText("crash-run-" + suffix)).toString() + ":" +
        database.scalarInt("SELECT COUNT(*) FROM approvals WHERE operation_id=" +
            sqliteText("crash-operation-" + suffix)).toString() + ":" +
        database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=" +
            sqliteText("crash-operation-" + suffix)).toString() + ":" +
        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id=" +
            sqliteText("crash-operation-" + suffix)).toString() + ":" +
        database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=" +
            sqliteText("crash-thread-" + suffix)).toString() + ":" +
        database.query("SELECT state FROM runs WHERE id=" +
            sqliteText("crash-run-" + suffix))[0].required(0)
}

func expectedCrashBoundaryCardinality(phase: Int64): String {
    match (phase) {
        case 1 => "0:0:0:0:2:running"
        case 2 => "1:0:0:0:2:running"
        case 3 => "1:0:0:0:2:running"
        case 4 => "1:0:0:1:2:running"
        case 5 => "1:0:1:1:2:running"
        case 6 => "1:0:1:1:2:running"
        case 7 => "1:0:1:1:3:waiting_external"
        case _ => throw IllegalArgumentException("invalid crash boundary")
    }
}

func crashBoundaryAction(phase: Int64): RecoveryActionKind {
    match (phase) {
        case 1 => RecoveryActionKind.CreateOrReconcileOperation
        case 2 => RecoveryActionKind.RequestApprovalOnce
        case 3 => RecoveryActionKind.ExecuteByRetryPolicy
        case 4 => RecoveryActionKind.RequireUnknownOutcomeReconciliation
        case 5 => RecoveryActionKind.FinalizeFromReceipt
        case 6 => RecoveryActionKind.AppendToolResultOnce
        case 7 => RecoveryActionKind.AdvanceRunWithoutDuplicate
        case _ => throw IllegalArgumentException("invalid crash boundary")
    }
}

func threadSeedContract(database: SqliteDatabase): Unit {
    let transcript = [
        ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "inspect")]),
        ModelMessage(ModelRole.Assistant, [
            ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "seed-call-a",
                name: "read",
                arguments: objectValue([])
            ),
            ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "seed-call-b",
                name: "list",
                arguments: objectValue([])
            )
        ]),
        ModelMessage(ModelRole.User, [
            ModelBlock(
                ModelBlockKind.ToolResult,
                callId: "seed-call-a",
                arguments: textValue("a")
            ),
            ModelBlock(
                ModelBlockKind.ToolResult,
                callId: "seed-call-b",
                arguments: textValue("b")
            )
        ]),
        ModelMessage(ModelRole.Assistant, [
            ModelBlock(ModelBlockKind.Text, text: "done")
        ])
    ]
    let snapshot = completedThreadSeedSnapshot(
        ThreadId("seed-thread"), "workspace", transcript, createdAtMillis: 100
    )
    expect(snapshot.turns.size == 1 && snapshot.items.size == 6 &&
        snapshot.activeRunId.isNone() && snapshot.thread.nextItemOrdinal == 7,
        "provider DTO seed is converted into one immutable completed semantic Turn")
    let store = SqliteThreadSeedStore(database)
    expect(store.createCompleted(snapshot).isOk(),
        "offline seed creates Thread, Turn, Run and Items in one boundary")
    let loaded = SqliteThreadCommitSink(database).loadThread(ThreadId("seed-thread"))
    expect(loaded.items.size == 6 && loaded.turns[0].state == TurnState.Completed &&
        database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='seed-thread'") == 1,
        "offline seed is durable and reconstructs as canonical Thread history")
    expect(store.createCompleted(snapshot).isError() &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='seed-thread'") == 6,
        "offline seed cannot overwrite an existing canonical Thread")

    var assistantFirstRejected = false
    try {
        let _ = completedThreadSeedSnapshot(
            ThreadId("invalid-assistant-first"),
            "workspace",
            [ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Text, text: "invalid")
            ])]
        )
    } catch (_: Exception) { assistantFirstRejected = true }
    expect(assistantFirstRejected,
        "offline seed rejects assistant content without a user-owned Turn")

    var incompleteToolRejected = false
    try {
        let _ = completedThreadSeedSnapshot(
            ThreadId("invalid-incomplete-tool"),
            "workspace",
            [
                ModelMessage(ModelRole.User, [
                    ModelBlock(ModelBlockKind.Text, text: "inspect")
                ]),
                ModelMessage(ModelRole.Assistant, [ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "pending",
                    name: "read",
                    arguments: objectValue([])
                )])
            ]
        )
    } catch (_: Exception) { incompleteToolRejected = true }
    expect(incompleteToolRejected,
        "offline seed rejects a completed Thread with an incomplete tool round")
}

func threadPagingContract(database: SqliteDatabase): Unit {
    let pageStore = SqliteThreadPageStore(database)
    let newest = pageStore.loadItemsPage(ThreadId("durable-thread"), 0, 2)
    expect(newest.items.size == 2 && newest.items[0].ordinal == 3 &&
        newest.items[1].ordinal == 4 && newest.hasMore && newest.nextBeforeOrdinal == 3,
        "Thread paging loads the newest bounded page in transcript order")
    let older = pageStore.loadItemsPage(
        ThreadId("durable-thread"), newest.nextBeforeOrdinal, 2
    )
    expect(older.items.size == 2 && older.items[0].ordinal == 1 &&
        older.items[1].ordinal == 2 && !older.hasMore && older.nextBeforeOrdinal == 1 &&
        older.threadRevision == newest.threadRevision,
        "Thread paging follows a stable before-ordinal cursor without retaining all Items")
}

func runtimeRecoveryContract(database: SqliteDatabase): Unit {
    let sink = SqliteThreadCommitSink(database)
    let coordinator = ThreadCoordinator(
        sink.createThread(ThreadId("runtime-recovery-thread"), "workspace"), sink
    )
    let runtime = AgentThreadRuntime(
        coordinator, ContextProjector("projector-v1", StoreEstimator()), { => 50 }
    )
    let started = runtime.startTurn(
        SemanticTurnId("runtime-recovery-turn"), RunId("runtime-recovery-run"),
        ItemId("runtime-recovery-user"),
        ThreadItemContent.UserMessage(textMessageParts("resume")),
        recoveryLane(), SkillStackSnapshot([], [])
    ).value().getOrThrow()
    // The old Runtime is intentionally abandoned here, simulating process loss
    // before any async worker is launched.
    let recovered = SqliteThreadRuntimeRecovery(database).resume(
        ThreadId("runtime-recovery-thread"),
        ContextProjector("projector-v1", StoreEstimator()), { => 60 }
    ).value().getOrThrow()
    expect(recovered.activeRun().getOrThrow().runId.value == "runtime-recovery-run" &&
        recovered.activeRun().getOrThrow().epoch == started.epoch &&
        recovered.activeRun().getOrThrow().lane.modelId == "recovery-model",
        "active Run resumes only from correlated immutable durable snapshots")
    expect(isStoreCommitted(recovered.commitResult(ResultEnvelope(
        ThreadId("runtime-recovery-thread"), SemanticTurnId("runtime-recovery-turn"),
        RunId("runtime-recovery-run"), started.epoch, 1,
        ThreadItemDraft(
            ItemId("runtime-recovery-assistant"),
            ThreadItemContent.AssistantMessage(textMessageParts("resumed")),
            ItemProvenance("model", runId: Some(RunId("runtime-recovery-run")))
        )
    ))), "recovered Runtime regains the sole semantic commit boundary")
    recovered.finish(RunState.Completed, 100).value().getOrThrow()
}

class StoreEstimator <: ThreadTokenEstimator {
    public init() {}
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}

func recoveryLane(): ModelLane {
    ModelLane(
        ModelLaneRole.Main, "provider", "recovery-model", "responses",
        ModelLaneCapabilitiesSnapshot(), 100, 10, 5,
        "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system-v1"
    )
}

func checkpointStoreContract(database: SqliteDatabase): Unit {
    let thread = SqliteThreadCommitSink(database).loadThread(ThreadId("durable-thread"))
    let checkpoint = ContextCheckpoint(
        "durable-checkpoint", thread.thread.id, 2,
        objectValue([ValueField("summary", textValue("stable"))]),
        contextSourceDigest(thread, 2), "projector-v1", "responses",
        activeState: objectValue([ValueField("mode", textValue("editing"))]),
        activeGoal: "finish", durableNotes: ["keep receipt"],
        artifactReferences: ["blob:sha256:abc"]
    )
    let store = SqliteContextCheckpointStore(database)
    store.save(checkpoint, thread, 40).value().getOrThrow()
    store.save(checkpoint, thread, 40).value().getOrThrow()
    let loaded = store.loadLatest(thread, "projector-v1", "responses").getOrThrow()
    expect(loaded.id == checkpoint.id && loaded.activeGoal == "finish" &&
        loaded.activeState.field("mode").getOrThrow().text == "editing" &&
        loaded.durableNotes == ["keep receipt"] &&
        loaded.artifactReferences == ["blob:sha256:abc"],
        "ContextCheckpoint persists idempotently and round-trips its projection payload")
    database.execute(
        "UPDATE context_checkpoints SET source_digest='stale' " +
            "WHERE id='durable-checkpoint'"
    )
    expect(store.loadLatest(thread, "projector-v1", "responses").isNone(),
        "stale durable checkpoint is discarded so canonical history can rebuild context")
}

func recoveryPlannerContract(database: SqliteDatabase): Unit {
    let sink = SqliteThreadCommitSink(database)
    let coordinator = ThreadCoordinator(
        sink.createThread(ThreadId("recovery-thread"), "workspace"), sink
    )
    let active = coordinator.startTurn(
        SemanticTurnId("recovery-turn"), RunId("recovery-run"), ItemId("recovery-user"),
        ThreadItemContent.UserMessage(textMessageParts("recover")), createdAtMillis: 20
    ).value().getOrThrow()
    let committed = commitDurableToolCall(
        database, coordinator, ThreadId("recovery-thread"),
        SemanticTurnId("recovery-turn"), RunId("recovery-run"), active.activeEpoch, 1,
        ItemId("recovery-call"), "recovery-call", "mutate", objectValue([]), 21
    )

    let planner = OperationRecoveryPlanner(database)
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.CreateOrReconcileOperation,
        "C1 ToolCall without Operation is recovered deterministically"
    )

    let operationStore = DurableOperationStore(database)
    let operationId = OperationId("recovery-operation")
    let plan = NormalizedOperationPlan(
        "mutate", objectValue([]), [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )],
        OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never,
        "exact-digest", resolvedPaths: ["/workspace/file"]
    )
    operationStore.prepare(
        operationId, RunId("recovery-run"), committed, plan
    ).value().getOrThrow()
    let loadedPlan = operationStore.loadPlan(
        operationId, RunId("recovery-run")
    ).value().getOrThrow()
    expect(loadedPlan.bindingDigest == plan.bindingDigest &&
        loadedPlan.requiredCapabilities.size == 1 &&
        loadedPlan.requiredCapabilities[0].kind == CapabilityKind.WorkspaceWrite &&
        loadedPlan.requiredCapabilities[0].resource == "/workspace",
        "durable Operation plan round-trips its exact capability requirements")
    // Preparation is idempotent only for the exact same ToolCall/Run/plan.
    operationStore.prepare(
        operationId, RunId("recovery-run"), committed, plan
    ).value().getOrThrow()
    operationStore.waitForApproval(operationId, RunId("recovery-run")).value().getOrThrow()
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.RequestApprovalOnce,
        "C2 prepared Operation requests approval exactly once"
    )
    let pendingApprovalId = ApprovalId("legacy-approval-recovery-operation")
    let approvalBoundary = withLegacyRunContinuationProjection(
        sealDurableRunContinuation(DurableRunContinuationV1(
            RunId("recovery-run"), LaneId("main"), SemanticTurnId("recovery-turn"), 1,
            RunExecutionPhase.WaitingApproval(DurablePhaseState(objectValue([]))),
            CompositionSnapshotId("recovery-composition"),
            ModelLaneSnapshotId("recovery-model-lane"),
            pendingOperationId: Some(operationId),
            pendingApprovalId: Some(pendingApprovalId),
            workDebt: WorkDebtSnapshot(
                unsettledOperations: [operationId],
                pendingApprovals: [pendingApprovalId]
            )
        )),
        "{\"fixture\":\"waiting-approval\"}"
    )
    database.execute(
        "INSERT INTO run_continuations(" +
            "run_id,schema_version,revision,phase,payload,digest,updated_commit_sequence" +
            ") VALUES (?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET " +
            "schema_version=excluded.schema_version,revision=excluded.revision," +
            "phase=excluded.phase,payload=excluded.payload,digest=excluded.digest," +
            "updated_commit_sequence=excluded.updated_commit_sequence",
        [
            SqlParameter.Text("recovery-run"), SqlParameter.Int64Value(1),
            SqlParameter.Int64Value(1), SqlParameter.Text("waiting_approval"),
            SqlParameter.Text(encodeDurableRunContinuation(approvalBoundary)),
            SqlParameter.Text(approvalBoundary.digest), SqlParameter.Int64Value(1)
        ]
    )
    expect(planner.inspect(ThreadId("recovery-thread")).isEmpty(),
        "canonical WaitingApproval register is a stable recovery boundary")
    database.execute("DELETE FROM run_continuations WHERE run_id='recovery-run'")
    operationStore.recordApproval(
        "rejected-approval", operationId, RunId("recovery-run"), plan,
        CapabilitySet(), false, "user"
    ).value().getOrThrow()
    operationStore.recordApproval(
        "rejected-approval", operationId, RunId("recovery-run"), plan,
        CapabilitySet(), false, "user"
    ).value().getOrThrow()
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM approvals WHERE operation_id='recovery-operation'"
    ) == 1, "exact approval replay is idempotent")
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.FinalizeRejectedApproval,
        "a durable rejected approval closes its ToolCall without asking again"
    )
    database.execute("DELETE FROM approvals WHERE id='rejected-approval'")
    database.execute(
        "UPDATE operations SET state='waiting_approval',revision=revision+1 " +
            "WHERE id='recovery-operation'"
    )
    let digestDriftPlan = NormalizedOperationPlan(
        "mutate", objectValue([]), [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )],
        OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never,
        "different-digest", resolvedPaths: ["/workspace/file"]
    )
    expect(operationStore.recordApproval(
        "digest-drift-approval", operationId, RunId("recovery-run"), digestDriftPlan,
        CapabilitySet(values: [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )]), true, "user"
    ).isError(), "approval digest mismatch cannot bind to a stored Operation plan")
    let insufficientApproval = operationStore.recordApproval(
        "insufficient-approval", operationId, RunId("recovery-run"), plan,
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)]), true, "user"
    )
    expect(insufficientApproval.isError() &&
        insufficientApproval.error().getOrThrow().code ==
            "operation.approval_ceiling_insufficient" &&
        database.query(
            "SELECT state FROM operations WHERE id='recovery-operation'"
        )[0].required(0) == "waiting_approval",
        "approval cannot authorize capabilities outside its typed ceiling")
    operationStore.recordApproval(
        "recovery-approval", operationId, RunId("recovery-run"), plan,
        CapabilitySet(values: [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )]), true, "user", Some(1000)
    ).value().getOrThrow()
    let driftedPlan = NormalizedOperationPlan(
        "mutate", objectValue([]), [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )],
        OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never,
        "exact-digest", resolvedPaths: ["/workspace/other-file"]
    )
    expect(operationStore.markExecuting(
        operationId, RunId("recovery-run"), driftedPlan, 30,
        true
    ).isError(), "approval blocks path drift even when a caller reuses the reviewed digest")
    let cwdDriftedPlan = NormalizedOperationPlan(
        "mutate", objectValue([]), [Capability(
            CapabilityKind.WorkspaceWrite, resource: "/workspace"
        )],
        OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never,
        "exact-digest", resolvedPaths: ["/workspace/file"], cwd: "/workspace/other"
    )
    expect(operationStore.markExecuting(
        operationId, RunId("recovery-run"), cwdDriftedPlan, 30, true
    ).isError(), "approval blocks cwd drift even when the digest text is reused")
    let escalatedPlan = NormalizedOperationPlan(
        "mutate", objectValue([]), [
            Capability(CapabilityKind.WorkspaceWrite, resource: "/workspace"),
            Capability(CapabilityKind.NetworkAccess, resource: "example.invalid")
        ],
        OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never,
        "exact-digest", resolvedPaths: ["/workspace/file"]
    )
    expect(operationStore.markExecuting(
        operationId, RunId("recovery-run"), escalatedPlan, 30, true
    ).isError(), "approval blocks capability escalation before executor handoff")
    operationStore.markExecuting(
        operationId, RunId("recovery-run"), plan, 30,
        true
    ).value().getOrThrow()
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.ExecuteByRetryPolicy,
        "C3 executing without durable handoff proves executor did not start"
    )
    operationStore.markExecutionHandoff(
        operationId, RunId("recovery-run"), ThreadId("recovery-thread"), 31
    ).value().getOrThrow()
    // Repeating the marker is safe and cannot widen authority.
    operationStore.markExecutionHandoff(
        operationId, RunId("recovery-run"), ThreadId("recovery-thread"), 31
    ).value().getOrThrow()
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.RequireUnknownOutcomeReconciliation,
        "C4 handed-off mutation without Receipt is Unknown and never blindly retried"
    )

    database.execute(
        "INSERT INTO operation_receipts VALUES (" +
            "'recovery-receipt','recovery-operation','completed','detail','verification',32)"
    )
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.FinalizeFromReceipt,
        "C5 durable Receipt finalizes without re-execution"
    )
    database.execute(
        "UPDATE operations SET state='recovery_required',revision=revision+1 " +
            "WHERE id='recovery-operation'"
    )
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.FinalizeFromReceipt,
        "C5 Unknown Receipt remains pending after its terminal Operation state commits"
    )
    database.execute(
        "UPDATE operations SET state='committed',revision=revision+1 " +
            "WHERE id='recovery-operation'"
    )
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.AppendToolResultOnce,
        "C6 committed Operation appends its ToolResult once"
    )

    let result = ThreadItemContent.ToolResult(
        CanonicalToolCallId("recovery-call"), operationId, "recovery-receipt",
        objectValue([ValueField("ok", boolValue(true))]), false
    )
    database.execute(
        "INSERT INTO items " +
            "(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (" +
            "'recovery-result','recovery-thread','recovery-turn',3,'tool_result'," +
            sqliteText(encodeStoredThreadContent(result)) + "," +
            sqliteText(encodeStoredProvenance(ItemProvenance(
                "operation", runId: Some(RunId("recovery-run")),
                operationId: Some(operationId)
            ))) + ",33)"
    )
    database.execute(
        "UPDATE threads SET revision=revision+1,next_item_ordinal=4 " +
            "WHERE id='recovery-thread'"
    )
    database.execute("UPDATE runs SET state='waiting_external' WHERE id='recovery-run'")
    expectRecovery(
        planner.inspect(ThreadId("recovery-thread")),
        RecoveryActionKind.AdvanceRunWithoutDuplicate,
        "C7 existing ToolResult advances Run without duplicating the Item"
    )
    let blocked = SqliteThreadRuntimeRecovery(database).resume(
        ThreadId("recovery-thread"),
        ContextProjector("projector-v1", StoreEstimator()), { => 40 }
    )
    expect(blocked.isError() && blocked.error().getOrThrow().code ==
        "thread.recovery_actions_pending",
        "Runtime cannot resume while a durable Operation reconciliation action is pending")
}

func expectRecovery(
    actions: Array<RecoveryAction>,
    kind: RecoveryActionKind,
    message: String
): Unit {
    expect(actions.size == 1 && actions[0].kind == kind, message)
}

func durableThreadCoordinatorContract(database: SqliteDatabase): Unit {
    let sink = SqliteThreadCommitSink(database)
    let initial = sink.createThread(ThreadId("durable-thread"), "workspace")
    let staleCoordinator = ThreadCoordinator(initial, sink)
    let coordinator = ThreadCoordinator(initial, sink)
    let active = coordinator.startTurn(
        SemanticTurnId("durable-turn"), RunId("durable-run"), ItemId("durable-user"),
        ThreadItemContent.UserMessage(textMessageParts("persist me")), createdAtMillis: 10
    ).value().getOrThrow()
    let staleStart = staleCoordinator.startTurn(
        SemanticTurnId("stale-turn"), RunId("stale-run"), ItemId("stale-user"),
        ThreadItemContent.UserMessage(textMessageParts("stale"))
    )
    expect(staleStart.isError() && staleCoordinator.snapshot().thread.revision == 0,
        "SQLite compare-and-swap rejects and rolls back a stale coordinator")

    let assistant = coordinator.commit(ResultEnvelope(
        ThreadId("durable-thread"), SemanticTurnId("durable-turn"), RunId("durable-run"),
        active.activeEpoch, 1,
        ThreadItemDraft(
            ItemId("durable-assistant"),
            ThreadItemContent.AssistantMessage(textMessageParts("working")),
            ItemProvenance("model", runId: Some(RunId("durable-run"))),
            createdAtMillis: 11
        )
    ))
    expect(isStoreCommitted(assistant), "ordinary Item commits through SQLite before publication")
    let call = coordinator.commit(ResultEnvelope(
        ThreadId("durable-thread"), SemanticTurnId("durable-turn"), RunId("durable-run"),
        active.activeEpoch, 2,
        ThreadItemDraft(
            ItemId("durable-call"),
            ThreadItemContent.ToolCall(
                CanonicalToolCallId("durable-call"), "read", objectValue([])
            ),
            ItemProvenance("model", runId: Some(RunId("durable-run"))),
            createdAtMillis: 12
        )
    ))
    expect(isStoreCommitted(call), "ToolCall is durable before Operation creation")
    database.execute(
        "INSERT INTO operations VALUES ('durable-operation','durable-run','durable-call'," +
            "'plan','capability','resource','read_only','safe',NULL,'executing',1)"
    )
    let operationId = OperationId("durable-operation")
    let toolResult = coordinator.commitOperationResult(
        ResultEnvelope(
            ThreadId("durable-thread"), SemanticTurnId("durable-turn"), RunId("durable-run"),
            active.activeEpoch, 3,
            ThreadItemDraft(
                ItemId("durable-result"),
                ThreadItemContent.ToolResult(
                    CanonicalToolCallId("durable-call"), operationId,
                    "durable-receipt", objectValue([ValueField("ok", boolValue(true))]), false
                ),
                ItemProvenance(
                    "operation", runId: Some(RunId("durable-run")),
                    operationId: Some(operationId)
                ),
                createdAtMillis: 13
            )
        ),
        VNextOperationReceipt(
            "durable-receipt", operationId, OperationOutcome.Completed,
            objectValue([ValueField("ok", boolValue(true))]), objectValue([]), 13
        ),
        "running"
    )
    expect(isStoreCommitted(toolResult),
        "Receipt, Operation, ToolResult, Run and Thread revision commit atomically")
    database.execute(
        "INSERT INTO operations VALUES ('unknown-operation','durable-run','durable-call'," +
            "'plan','capability','resource','external_mutation','never',NULL,'executing',1)"
    )
    let unknownReceipt = VNextOperationReceipt(
        "unknown-receipt", OperationId("unknown-operation"),
        OperationOutcome.Unknown,
        objectValue([ValueField("cause", textValue("transport lost"))]),
        objectValue([ValueField("stage", textValue("executing"))]), 14
    )
    expect(coordinator.recordOperationReceipt(RunId("durable-run"), unknownReceipt).isOk() &&
        database.query(
            "SELECT state FROM operations WHERE id='unknown-operation'"
        )[0].required(0) == "recovery_required" &&
        coordinator.snapshot().thread.revision == 4,
        "Unknown external Receipt remains durable without becoming semantic Thread truth")
    let recovered = sink.loadThread(ThreadId("durable-thread"))
    expect(recovered.thread.revision == 4 && recovered.items.size == 4 &&
        recovered.nextResultSequence == 4 && recovered.activeRunId.getOrThrow().value == "durable-run",
        "durable Thread replay restores active Run correlation and next result sequence")
    let replayed = ThreadCoordinator(recovered, sink)
    let refusedCompletion = replayed.completeTurn(
        SemanticTurnId("durable-turn"), RunId("durable-run"), recovered.activeEpoch
    )
    expect(refusedCompletion.isError() &&
        database.query("SELECT state FROM runs WHERE id='durable-run'")[0].required(0) == "running",
        "successful terminal publication rejects unresolved Operation WorkDebt")
    let quarantined = replayed.requireRecoveryTurn(
        SemanticTurnId("durable-turn"), RunId("durable-run"), recovered.activeEpoch
    ).value().getOrThrow()
    expect(quarantined.thread.revision == 5 && quarantined.thread.activeTurnId.isNone() &&
        database.query("SELECT state FROM runs WHERE id='durable-run'")[0].required(0) ==
            "recovery_required",
        "unresolved outcome settles only through the explicit recovery terminal")
}

func isStoreCommitted(decision: SemanticCommitDecision): Bool {
    match (decision) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }
}

func threadCodecContract(): Unit {
    let nested = objectValue([
        ValueField("unicode", textValue("你好\nagent")),
        ValueField("values", listValue([nullValue(), boolValue(true), numberValue("-12.5e2")]))
    ])
    let encoded = encodeStoredValue(nested)
    expect(encodeStoredValue(decodeStoredValue(encoded)) == encoded,
        "durable AgentValue codec round-trips nested UTF-8 values canonically")
    let contents: Array<ThreadItemContent> = [
        ThreadItemContent.UserMessage([
            ThreadMessagePart.Text("hello"),
            ThreadMessagePart.Image(ThreadImage(
                ThreadImageSourceKind.Base64, "aGVsbG8=", mediaType: "image/png"
            ))
        ]),
        ThreadItemContent.AssistantMessage([ThreadMessagePart.Refusal("cannot")]),
        ThreadItemContent.ToolCall(CanonicalToolCallId("call"), "read", nested),
        ThreadItemContent.ToolResult(
            CanonicalToolCallId("call"), OperationId("operation"), "receipt", nested, true
        ),
        ThreadItemContent.ReasoningReference("reasoning", "safe summary"),
        ThreadItemContent.ProviderOpaqueItem(OpaqueProviderState(
            "provider", "responses", "opaque", itemId: "item", replayRequired: true
        )),
        ThreadItemContent.ArtifactReference("sha256", "text/plain", 7),
        ThreadItemContent.SystemNote("system")
    ]
    for (content in contents) {
        let payload = encodeStoredThreadContent(content)
        expect(encodeStoredThreadContent(decodeStoredThreadContent(payload)) == payload,
            "durable Thread item payload round-trips canonically")
    }
    let provenance = ItemProvenance(
        "operation", runId: Some(RunId("run")), operationId: Some(OperationId("operation"))
    )
    let provenancePayload = encodeStoredProvenance(provenance)
    expect(encodeStoredProvenance(decodeStoredProvenance(provenancePayload)) == provenancePayload,
        "durable provenance round-trips run and operation ownership")
    var malformedRejected = false
    try { let _ = decodeStoredValue("s5:bad") } catch (_: Exception) { malformedRejected = true }
    expect(malformedRejected, "durable value codec rejects truncated frames")
}

func operationCommitContract(database: SqliteDatabase): Unit {
    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO threads VALUES ('operation-thread',7,'workspace','open',3,'turn')"
        )
        transaction.execute(
            "INSERT INTO turns VALUES ('turn','operation-thread',1,'active','user','run')"
        )
        transaction.execute(
            "INSERT INTO items VALUES ('user','operation-thread','turn',1,'user_message','{}','{}',0)"
        )
        transaction.execute(
            "INSERT INTO items VALUES ('call','operation-thread','turn',2,'tool_call','{}','{}',0)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES " +
                "('run','operation-thread','turn',1,'running','{}','{}','{}','{}',0,NULL,NULL)"
        )
        transaction.execute(
            "INSERT INTO operations VALUES ('operation','run','call','{}','{}','{}','workspace_mutation','never',NULL,'executing',1)"
        )
    }
    let store = AgentStore(database)
    let conflicting = operationCommit("call", "receipt-conflict")
    var failed = false
    try { store.commitOperationResult(conflicting) } catch (_: Exception) { failed = true }
    expect(failed, "conflicting canonical item injects a post-receipt failure")
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM operation_receipts WHERE operation_id='operation'"
    ) == 0, "receipt insertion rolls back with later semantic failure")
    expect(database.query(
        "SELECT state FROM operations WHERE id='operation'"
    )[0].required(0) == "executing", "operation transition rolls back with receipt")
    expect(database.scalarInt(
        "SELECT revision FROM threads WHERE id='operation-thread'"
    ) == 7, "thread revision is unchanged after atomic failure")

    store.commitOperationResult(operationCommit("result", "receipt"))
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM operation_receipts WHERE operation_id='operation'"
    ) == 1, "receipt commits exactly once")
    expect(database.query(
        "SELECT state FROM operations WHERE id='operation'"
    )[0].required(0) == "committed", "operation and receipt commit together")
    expect(database.query(
        "SELECT kind FROM items WHERE id='result'"
    )[0].required(0) == "tool_result", "canonical ToolResult commits with receipt")
    expect(database.scalarInt(
        "SELECT revision FROM threads WHERE id='operation-thread'"
    ) == 8, "Thread revision advances in the same transaction")
}

func operationCommit(itemId: String, receiptId: String): OperationSemanticCommit {
    OperationSemanticCommit(
        "operation", "run", receiptId, OperationOutcome.Completed,
        "done", "verified", itemId, "operation-thread", "turn", 3,
        "{\"result\":\"done\"}", "{\"operationId\":\"operation\"}",
        1, 7, "running"
    )
}

func semanticStoreContract(database: SqliteDatabase): Unit {
    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO threads VALUES ('semantic-thread',0,'workspace','open',1,'semantic-turn')"
        )
        transaction.execute(
            "INSERT INTO turns VALUES ('semantic-turn','semantic-thread',1,'active','semantic-user','semantic-run')"
        )
        transaction.execute(
            "INSERT INTO items VALUES ('semantic-user','semantic-thread','semantic-turn',1," +
                "'user_message','{}','{}',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES " +
                "('semantic-run','semantic-thread','semantic-turn',1,'running','{}','{}','{}','{}',1,NULL,NULL)"
        )
    }
    let store = SqliteSemanticStore(database)
    let first = sealDurableRunContinuation(semanticContinuation(
        RunExecutionPhase.Accepted(DurablePhaseState(objectValue([
            ValueField("input_claim", textValue("semantic-user"))
        ])))
    ))
    let committed = store.transact(
        TransactionPreconditions(
            ThreadId("semantic-thread"), 0, RunId("semantic-run"), 0
        ),
        DurableWriteSet(
            continuation: Some(first),
            auditEntries: [SemanticAuditEntry(
                "run.accepted", objectValue([ValueField("source", textValue("contract"))]), 10
            )],
            appEvents: [
                SemanticAppEvent(
                    "semantic-event-1", "run.accepted",
                    objectValue([ValueField("run_id", textValue("semantic-run"))]), 10
                ),
                SemanticAppEvent(
                    "semantic-event-2", "run.phase_changed",
                    objectValue([ValueField("phase", textValue("accepted"))]), 11
                )
            ]
        )
    )
    expect(committed.isOk(), "semantic transaction commits")
    let receipt = committed.value().getOrThrow()
    expect(receipt.commitSequence == 1 && receipt.continuationRevision == 1,
        "semantic transaction allocates first sequence and continuation revision")
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM run_continuation_facts WHERE run_id='semantic-run'"
    ) == 1 && database.scalarInt(
        "SELECT COUNT(*) FROM audit_events WHERE thread_id='semantic-thread' AND commit_sequence=1"
    ) == 1 && database.scalarInt(
        "SELECT COUNT(*) FROM app_event_outbox WHERE thread_id='semantic-thread' AND commit_sequence=1"
    ) == 2, "fact, register, audit and outbox commit atomically")
    let restored = store.continuation(RunId("semantic-run"))
    expect(restored.isOk() && restored.value().getOrThrow().digest == first.digest,
        "sealed continuation round-trips canonically")
    let stale = store.transact(
        TransactionPreconditions(ThreadId("semantic-thread"), 0, RunId("semantic-run"), 1),
        DurableWriteSet(auditEntries: [SemanticAuditEntry(
            "stale", objectValue([]), 12
        )])
    )
    expect(stale.isError() && stale.error().getOrThrow().kind == AgentErrorKind.Conflict,
        "stale Thread revision is rejected as a conflict")
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM audit_events WHERE thread_id='semantic-thread'"
    ) == 1, "conflicting transaction leaves no partial audit write")

    let second = sealDurableRunContinuation(semanticContinuation(
        RunExecutionPhase.ContextCompiling(DurablePhaseState(objectValue([
            ValueField("manifest_reservation", textValue("manifest-1"))
        ])))
    ))
    let advanced = store.transact(
        TransactionPreconditions(ThreadId("semantic-thread"), 1, RunId("semantic-run"), 1),
        DurableWriteSet(
            continuation: Some(second),
            appEvents: [SemanticAppEvent(
                "semantic-event-3", "run.phase_changed",
                objectValue([ValueField("phase", textValue("context_compiling"))]), 13
            )]
        )
    )
    expect(advanced.isOk() && advanced.value().getOrThrow().commitSequence == 2,
        "per-Thread commit sequence is strictly increasing")
    let pending = store.pendingOutbox(ThreadId("semantic-thread"), 0)
    expect(pending.isOk() && pending.value().getOrThrow().size == 3 &&
        pending.value().getOrThrow()[0].event.eventId == "semantic-event-1" &&
        pending.value().getOrThrow()[2].event.eventId == "semantic-event-3",
        "outbox preserves transaction and ordinal order")
    let duplicate = store.transact(
        TransactionPreconditions(ThreadId("semantic-thread"), 2, RunId("semantic-run"), 2),
        DurableWriteSet(appEvents: [SemanticAppEvent(
            "semantic-event-3", "duplicate", objectValue([]), 14
        )])
    )
    expect(duplicate.isError() && database.scalarInt(
        "SELECT revision FROM threads WHERE id='semantic-thread'"
    ) == 2, "duplicate App event rolls back without advancing Thread revision")
    expect(store.acknowledgeOutbox(ThreadId("semantic-thread"), 1).isOk(),
        "outbox delivery acknowledgement succeeds")
    expect(store.pendingOutbox(ThreadId("semantic-thread"), 0).value().getOrThrow().size == 1,
        "acknowledged outbox rows are derived delivery state only")

    let canonical = encodeDurableRunContinuation(second)
    database.execute(
        "UPDATE run_continuations SET payload='corrupt' WHERE run_id='semantic-run'"
    )
    let corrupt = store.continuation(RunId("semantic-run"))
    expect(corrupt.isError() &&
        corrupt.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired,
        "corrupt continuation fails closed as RecoveryRequired")
    database.execute(
        "UPDATE run_continuations SET payload=? WHERE run_id='semantic-run'",
        [SqlParameter.Text(canonical)]
    )
}

func semanticContinuation(phase: RunExecutionPhase): DurableRunContinuationV1 {
    DurableRunContinuationV1(
        RunId("semantic-run"), LaneId("main"), SemanticTurnId("semantic-turn"),
        0, phase, CompositionSnapshotId("composition-1"),
        ModelLaneSnapshotId("model-lane-1")
    )
}

func inboxStepContract(database: SqliteDatabase): Unit {
    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO threads VALUES ('inbox-thread',0,'workspace','open',1,'inbox-turn')"
        )
        transaction.execute(
            "INSERT INTO turns VALUES ('inbox-turn','inbox-thread',1,'active','inbox-accepted','inbox-run')"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES " +
                "('inbox-run','inbox-thread','inbox-turn',1,'running','{}','{}','{}','{}',0,NULL,NULL)"
        )
    }
    let store = SqliteInboxStepStore(database)
    let first = DurableInboxEntry(
        InboxEntryId("inbox-entry-1"), ThreadId("inbox-thread"), LaneId("main"),
        InboxEntryKind.UserPrompt,
        objectValue([ValueField("text", textValue("first prompt"))]),
        createdAtMillis: 1
    )
    let steering = DurableInboxEntry(
        InboxEntryId("inbox-entry-2"), ThreadId("inbox-thread"), LaneId("main"),
        InboxEntryKind.Steering,
        objectValue([ValueField("text", textValue("steer next"))]),
        createdAtMillis: 2
    )
    expect(store.enqueue(first).value().getOrThrow() == InboxEnqueueOutcome.Inserted &&
        store.enqueue(first).value().getOrThrow() == InboxEnqueueOutcome.AlreadyQueued &&
        store.enqueue(steering).isOk(),
        "durable Inbox enqueue reports insertion and queued replay explicitly")
    expect(store.enqueue(DurableInboxEntry(
        InboxEntryId("unknown-lane-entry"), ThreadId("inbox-thread"), LaneId("missing"),
        InboxEntryKind.Steering, objectValue([])
    )).isError(), "Inbox enqueue rejects an unknown Lane before persistence")
    let continuation = sealDurableRunContinuation(DurableRunContinuationV1(
        RunId("inbox-run"), LaneId("main"), SemanticTurnId("inbox-turn"), 0,
        RunExecutionPhase.Accepted(DurablePhaseState(objectValue([
            ValueField("claimed_entry_id", textValue("inbox-entry-1")),
            ValueField("accepted_item_id", textValue("inbox-accepted"))
        ]))),
        CompositionSnapshotId("inbox-composition"),
        ModelLaneSnapshotId("inbox-model-lane")
    ))
    let request = InboxClaimRequest(
        first.id, StepId("inbox-step-1"), RunId("inbox-run"),
        SemanticTurnId("inbox-turn"), ItemId("inbox-accepted"),
        0, 0, continuation, 3
    )
    let claimed = store.claim(request)
    expect(claimed.isOk() && store.claim(request).isOk() &&
        database.query(
            "SELECT status,claimed_step_id FROM lane_inbox_entries WHERE id='inbox-entry-1'"
        )[0].required(0) == "claimed" &&
        database.scalarInt("SELECT COUNT(*) FROM step_records WHERE id='inbox-step-1'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE id='inbox-accepted'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM run_continuation_facts WHERE run_id='inbox-run'") == 1 &&
        database.scalarInt("SELECT revision FROM threads WHERE id='inbox-thread'") == 1,
        "Inbox claim atomically creates Step, accepted Item and continuation exactly once")

    let secondContinuation = sealDurableRunContinuation(DurableRunContinuationV1(
        RunId("inbox-run"), LaneId("main"), SemanticTurnId("inbox-turn"), 1,
        RunExecutionPhase.Accepted(DurablePhaseState(objectValue([
            ValueField("claimed_entry_id", textValue("inbox-entry-2"))
        ]))),
        CompositionSnapshotId("inbox-composition"),
        ModelLaneSnapshotId("inbox-model-lane")
    ))
    let failed = store.claim(InboxClaimRequest(
        steering.id, StepId("inbox-step-2"), RunId("inbox-run"),
        SemanticTurnId("inbox-turn"), ItemId("inbox-accepted"),
        1, 1, secondContinuation, 4
    ))
    expect(failed.isError() && database.query(
        "SELECT status FROM lane_inbox_entries WHERE id='inbox-entry-2'"
    )[0].required(0) == "queued" &&
        database.scalarInt("SELECT COUNT(*) FROM step_records WHERE run_id='inbox-run'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM run_continuation_facts WHERE run_id='inbox-run'") == 1,
        "failed claim rolls back Inbox, Step, Item and continuation together")
    expect(store.settle(
        StepId("inbox-step-1"), 1, StepStatus.Completed, 5
    ).isOk() && database.query(
        "SELECT status FROM lane_inbox_entries WHERE id='inbox-entry-1'"
    )[0].required(0) == "applied" && database.query(
        "SELECT status FROM step_records WHERE id='inbox-step-1'"
    )[0].required(0) == "completed",
        "Step settlement encloses the claimed Inbox entry")
    expect(store.enqueue(first).value().getOrThrow() == InboxEnqueueOutcome.AlreadyApplied,
        "terminal Inbox replay returns its explicit terminal state")
    laneTreeContract(database)
    inboxLaneIsolationContract(database)
    compositionGraphContract(database)
    contextManifestContract(database)
    teamStoreContract(database)
}

func inboxLaneIsolationContract(database: SqliteDatabase): Unit {
    let store = SqliteInboxStepStore(database)
    let reviewEntry = DurableInboxEntry(
        InboxEntryId("review-lane-entry"), ThreadId("inbox-thread"), LaneId("review"),
        InboxEntryKind.Steering,
        objectValue([ValueField("text", textValue("review only"))]),
        createdAtMillis: 8
    )
    expect(store.enqueue(reviewEntry).isOk(), "known child Lane accepts durable input")
    let reviewContinuation = sealDurableRunContinuation(DurableRunContinuationV1(
        RunId("inbox-run"), LaneId("review"), SemanticTurnId("inbox-turn"), 1,
        RunExecutionPhase.Accepted(DurablePhaseState(objectValue([]))),
        CompositionSnapshotId("inbox-composition"),
        ModelLaneSnapshotId("inbox-model-lane")
    ))
    expect(store.claim(InboxClaimRequest(
        reviewEntry.id, StepId("review-lane-step"), RunId("inbox-run"),
        SemanticTurnId("inbox-turn"), ItemId("review-lane-accepted"),
        1, 1, reviewContinuation, 9
    )).isError() && database.query(
        "SELECT status FROM lane_inbox_entries WHERE id='review-lane-entry'"
    )[0].required(0) == "queued",
        "Inbox claim rejects a Run bound to another Lane without consuming input")

    database.execute(
        "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
            "VALUES ('inbox-thread-two',0,'workspace','open',1,NULL)"
    )
    let firstId = scopedInboxEntryId(
        ThreadId("inbox-thread"), LaneId("main"), "shared-correlation"
    )
    let secondId = scopedInboxEntryId(
        ThreadId("inbox-thread-two"), LaneId("main"), "shared-correlation"
    )
    expect(firstId.value != secondId.value && store.enqueue(DurableInboxEntry(
        firstId, ThreadId("inbox-thread"), LaneId("main"), InboxEntryKind.Steering,
        objectValue([ValueField("text", textValue("first"))])
    )).isOk() && store.enqueue(DurableInboxEntry(
        secondId, ThreadId("inbox-thread-two"), LaneId("main"), InboxEntryKind.Steering,
        objectValue([ValueField("text", textValue("second"))])
    )).isOk(), "Inbox durable identity is scoped across Threads")
}

func teamStoreContract(database: SqliteDatabase): Unit {
    let store = SqliteTeamStore(database)
    let teamId = TeamId("review-team")
    let team = TeamRecord(teamId, ThreadId("inbox-thread"), LaneId("main"), "Review team", createdAtMillis: 10)
    expect(store.createTeam(team).isOk() && store.createTeam(team).isOk(),
        "Team creation is durable and idempotent on the coordinator Lane")
    let coordinator = TeamMemberRecord(
        TeamMemberId("coordinator"), teamId, ThreadId("inbox-thread"), LaneId("main"),
        "coordinator", joinedAtMillis: 11
    )
    let reviewer = TeamMemberRecord(
        TeamMemberId("reviewer"), teamId, ThreadId("inbox-thread"), LaneId("review"),
        "reviewer", joinedAtMillis: 12
    )
    expect(store.addMember(coordinator).isOk() && store.addMember(reviewer).isOk() &&
        store.roster(teamId).value().getOrThrow().size == 2,
        "Team roster binds members to durable Lanes")
    let taskId = TeamTaskId("review-task")
    expect(store.addTask(TeamTaskRecord(
        taskId, teamId, "Review change", objectValue([ValueField("scope", textValue("phase-9"))]),
        itemReference: Some(ItemId("review-item")), createdAtMillis: 13, updatedAtMillis: 13
    )).isOk(), "Task board stores payload and Item reference")
    let claimed = store.claimTask(taskId, reviewer.id, 0, 14).value().getOrThrow()
    expect(claimed.status == TeamTaskStatus.Claimed && claimed.revision == 1 &&
        store.claimTask(taskId, coordinator.id, 0, 14).isError(),
        "Task claim uses revision fencing and cannot be stolen")
    expect(store.settleTask(taskId, 1, TeamTaskStatus.Blocked, "", 15).isError() &&
        store.settleTask(taskId, 1, TeamTaskStatus.Blocked, "debt-external-review", 15).isOk(),
        "blocked Team work requires explicit WorkDebt classification")
    let message = TeamMessageRecord(
        TeamMessageId("review-message"), teamId, coordinator.id, reviewer.id,
        objectValue([ValueField("request", textValue("inspect review item"))]),
        itemReference: Some(ItemId("review-item")), createdAtMillis: 16
    )
    expect(store.send(message).isOk() && store.send(message).isOk(),
        "Team mailbox send is idempotent")
    let mailbox = store.mailbox(teamId, reviewer.id).value().getOrThrow()
    expect(mailbox.size == 1 && mailbox[0].itemReference.getOrThrow().value == "review-item" &&
        store.acknowledge(message.id, reviewer.id, 0).isOk() &&
        store.acknowledge(message.id, reviewer.id, 0).isOk(),
        "members exchange durable messages and Item references without touching continuations")
    expect(store.taskBoard(teamId).value().getOrThrow()[0].workDebtId == "debt-external-review",
        "Task board reconstructs classified durable debt")
}

class ContractStringProvider <: ServiceProvider<String> {
    let releases: ArrayList<String>
    init(releases: ArrayList<String>) { this.releases = releases }
    public func acquire(scope: ComponentScope): Result<ServiceLease<String>> {
        Result.Ok(ServiceLease("service-value", scope, { => releases.add(scope.id) }))
    }
}

class ContractDisposable <: DisposableResource {
    var disposed: Bool = false
    public init() {}
    public func dispose(): Unit { disposed = true }
}

func compositionGraphContract(database: SqliteDatabase): Unit {
    let host = ComponentScope(RealmKind.Host, "host")
    let thread = ComponentScope(RealmKind.Thread, "inbox-thread", parent: Some(host))
    let lane = ComponentScope(RealmKind.Lane, "main", parent: Some(thread))
    let run = ComponentScope(RealmKind.Run, "inbox-run", parent: Some(lane))
    let extension = ComponentScope(RealmKind.Extension, "extension-7", parent: Some(host))
    let component = ComponentInstanceRef(
        "filesystem-generation-7", "filesystem", "2.0.0", 7, extension
    )
    let binding = ResolvedServiceBinding(
        "FileSystemService", 1u32, component.instanceId, RealmKind.Run
    )
    let profile = AgentProfile(
        "standard", "2.0.0", [component], [binding],
        objectValue([ValueField("main", textValue("model-lane"))]),
        objectValue([ValueField("policy", textValue("standard"))]),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        objectValue([ValueField("compiler", textValue("manifest-v1"))]),
        objectValue([ValueField("trigger", integerValue(88))]), ["workspace"]
    )
    let snapshot = CompositionResolver().resolve(
        CompositionSnapshotId("composition-inbox-1"), profile,
        "tool-visibility-digest", "prompt-graph-digest"
    )
    expect(snapshot.isSealed(), "Composition resolver seals the complete component graph")
    let store = SqliteCompositionSnapshotStore(database)
    expect(store.bindRun(RunId("inbox-run"), snapshot, 9).isOk() &&
        store.bindRun(RunId("inbox-run"), snapshot, 9).isOk(),
        "Run freezes one idempotent Composition Snapshot")
    let restored = store.loadRun(RunId("inbox-run"))
    expect(restored.isOk() && restored.value().getOrThrow().digest == snapshot.digest &&
        restored.value().getOrThrow().componentInstances[0].generation == 7,
        "Composition generation survives durable reconstruction")

    let releases = ArrayList<String>()
    let registry = ServiceRegistry<String>(ServiceKey<String>(
        "FileSystemService", 1u32, RealmKind.Run
    ))
    expect(registry.bind(ContractStringProvider(releases)).isOk() &&
        registry.acquire(lane).isError(),
        "typed Service registry rejects an illegal Realm")
    let lease = registry.acquire(run).value().getOrThrow()
    expect(lease.value == "service-value", "typed Service lease resolves its provider")
    lease.release()
    lease.release()
    expect(releases.size == 1, "Service lease releases exactly once")

    let scope = EffectScope(component)
    let resource = ContractDisposable()
    let task = ContractDisposable()
    let process = ContractDisposable()
    let disposedEffects = ArrayList<String>()
    let scopedRegistry = ServiceRegistry<String>(ServiceKey<String>(
        "ScopedService", 1u32, RealmKind.Run
    ))
    expect(scope.ownResource(resource).isOk() &&
        scope.ownTask(task).isOk() && scope.ownProcess(process).isOk() &&
        scope.provideService(scopedRegistry, ContractStringProvider(releases)).isOk() &&
        scope.registerTool(EffectRegistration(
            "tool", { => disposedEffects.add("tool") }
        )).isOk() && scope.registerHook(EffectRegistration(
            "hook", { => disposedEffects.add("hook") }
        )).isOk() && scope.registerSkill(EffectRegistration(
            "skill", { => disposedEffects.add("skill") }
        )).isOk() && scope.deferDispose({ => disposedEffects.add("deferred") }).isOk() &&
        scope.registerPrompt(PromptContribution(
            "filesystem-generation-7", "run", "after", PromptArtifact("prompt").hash,
            PromptVisibility.Model
        )).isOk() && scopedRegistry.acquire(run).isOk(),
        "EffectScope owns Service, Tool, Hook, Skill, Task, Process and Prompt effects")
    scope.stopAdmitting()
    expect(scope.registerPrompt(PromptContribution(
        "filesystem-generation-7", "run", "after", PromptArtifact("prompt").hash,
        PromptVisibility.Model
    )).isError(), "stopped EffectScope rejects new contributions")
    scope.dispose()
    expect(resource.disposed && task.disposed && process.disposed &&
        disposedEffects.size == 4 && scopedRegistry.acquire(run).isError() &&
        scope.promptContributions().isEmpty() &&
        scope.toolContributions().isEmpty() &&
        scope.hookContributions().isEmpty() &&
        scope.skillContributions().isEmpty(),
        "EffectScope revokes every owned effect and scoped Service on dispose")
}

func laneTreeContract(database: SqliteDatabase): Unit {
    let store = SqliteLaneTreeStore(database)
    let child = LaneRecord(
        LaneId("review"), ThreadId("inbox-thread"), LaneKind.SharedHistoryChild,
        objectValue([ValueField("model", textValue("reviewer"))]),
        parentLaneId: Some(LaneId("main")),
        forkItemId: Some(ItemId("inbox-accepted")), createdAtMillis: 7
    )
    expect(store.createLane(child).isOk() && store.createLane(child).isOk(),
        "shared-history Lane creation is idempotent at an owned fork Item")
    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES ('review-item','inbox-thread','inbox-turn',2,'system_note',?,?,8)",
            [
                SqlParameter.Text(encodeStoredThreadContent(
                    ThreadItemContent.SystemNote("review branch")
                )),
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance(
                    "lane", runId: Some(RunId("inbox-run"))
                )))
            ]
        )
        transaction.execute(
            "UPDATE threads SET next_item_ordinal=3 WHERE id='inbox-thread'"
        )
    }
    expect(store.bindItem(
        ItemId("review-item"), ThreadId("inbox-thread"), LaneId("review"),
        ItemId("inbox-accepted")
    ).isOk(), "new Item binds to a child Lane parent")
    let mainBranch = store.branchItemIds(ThreadId("inbox-thread"), LaneId("main"))
        .value().getOrThrow()
    let review = store.branchItemIds(ThreadId("inbox-thread"), LaneId("review"))
        .value().getOrThrow()
    expect(mainBranch.size == 1 && mainBranch[0].value == "inbox-accepted" &&
        review.size == 2 && review[0].value == "inbox-accepted" &&
        review[1].value == "review-item" && database.query(
            "SELECT lane_id FROM run_lane_bindings WHERE run_id='inbox-run'"
        )[0].required(0) == "main",
        "main history is an automatic parent chain and child projection shares only its fork prefix")

    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                "VALUES ('fork-source',2,'workspace','open',3,NULL)"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                "VALUES ('fork-source-turn','fork-source',1,'completed','fork-source-user',NULL)"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance," +
                "created_at_millis) VALUES ('fork-source-user','fork-source'," +
                "'fork-source-turn',1,'user_message',?,?,20)",
            [
                SqlParameter.Text(encodeStoredThreadContent(
                    ThreadItemContent.UserMessage(textMessageParts("fork me"))
                )),
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance("user")))
            ]
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance," +
                "created_at_millis) VALUES ('fork-source-answer','fork-source'," +
                "'fork-source-turn',2,'assistant_message',?,?,21)",
            [
                SqlParameter.Text(encodeStoredThreadContent(
                    ThreadItemContent.AssistantMessage(textMessageParts("isolated history"))
                )),
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance(
                    "model", runId: Some(RunId("source-run"))
                )))
            ]
        )
    }
    let forked = store.forkThread(
        ThreadId("fork-source"), LaneId("main"), ItemId("fork-source-answer"),
        ThreadId("fork-target"), "isolated-workspace", 22
    ).value().getOrThrow()
    let repeated = store.forkThread(
        ThreadId("fork-source"), LaneId("main"), ItemId("fork-source-answer"),
        ThreadId("fork-target"), "isolated-workspace", 22
    ).value().getOrThrow()
    expect(forked.size == 2 && repeated.size == 2 &&
        store.branchItemIds(ThreadId("fork-target"), LaneId("main"))
            .value().getOrThrow().size == 2 &&
        database.scalarInt(
            "SELECT COUNT(*) FROM audit_events WHERE thread_id='fork-target' " +
                "AND kind='thread.forked'"
        ) == 1 && SqliteThreadCommitSink(database).loadThread(
            ThreadId("fork-target")
        ).activeRunId.isNone(),
        "ForkThread atomically creates one isolated idle Thread and preserves its source fact")
}

func contextManifestContract(database: SqliteDatabase): Unit {
    let thread = SqliteThreadCommitSink(database).loadThread(ThreadId("inbox-thread"))
    let intent = thread.items[0]
    let lane = recoveryLane()
    let artifact = PromptArtifact("Always preserve exact durable intent.")
    let contribution = PromptContribution(
        "contract-component", "thread", "system.after_core", artifact.hash,
        PromptVisibility.Model
    )
    let rendered = objectValue([
        ValueField("system", textValue(artifact.content)),
        ValueField("messages", listValue([objectValue([
            ValueField("role", textValue("user")),
            ValueField("content", textValue("first prompt"))
        ])])),
        ValueField("tools", listValue([]))
    ])
    let compiled = ContextCompiler("manifest-compiler-v1").compile(ContextCompileInput(
        ContextManifestId("manifest-inbox-1"), ThreadId("inbox-thread"), LaneId("main"),
        SemanticTurnId("inbox-turn"), StepId("inbox-step-1"),
        ModelContextProjection(1, None, [intent], objectValue([]), 3, false),
        intent.id, objectValue([ValueField("profile", integerValue(1))]),
        ["skill-v1"], ["memory-v1"], [contribution], [artifact], lane, rendered
    ))
    expect(compiled.isOk(), "Context Compiler produces a sealed manifest")
    let manifest = compiled.value().getOrThrow()
    let store = SqliteContextManifestStore(database)
    expect(store.save(manifest, [artifact], 6).isOk() &&
        store.save(manifest, [artifact], 6).isOk(),
        "Context Manifest and content-addressed Prompt artifacts persist idempotently")
    let restored = store.load(manifest.id)
    let request = reconstructModelRequest(restored.value().getOrThrow())
    expect(restored.isOk() && request.isOk() &&
        encodeStoredValue(request.value().getOrThrow()) == encodeStoredValue(rendered) &&
        restored.value().getOrThrow().toolCatalogSnapshot.field(
            "snapshot_id"
        ).getOrThrow().text == lane.toolSet.id,
        "stored Context Manifest reconstructs the exact provider-neutral request")
    let replacement = PromptArtifact("A newer plugin prompt must not rewrite old attempts.")
    expect(replacement.hash != artifact.hash && store.load(manifest.id).value().getOrThrow().digest ==
        manifest.digest,
        "new Prompt content cannot mutate a historical Manifest")
    expect(store.ensureModelStep(
        RunId("inbox-run"), ThreadId("inbox-thread"), LaneId("main"),
        SemanticTurnId("inbox-turn"), StepId("inbox-step-context-2"), 2,
        None, None, 10
    ).isOk(), "later model Step persists its nonzero ordinal")
    let secondCompiled = ContextCompiler("manifest-compiler-v1").compile(ContextCompileInput(
        ContextManifestId("manifest-inbox-2"), ThreadId("inbox-thread"), LaneId("main"),
        SemanticTurnId("inbox-turn"), StepId("inbox-step-context-2"),
        ModelContextProjection(1, None, [intent], objectValue([]), 3, false),
        intent.id, objectValue([ValueField("profile", integerValue(1))]),
        ["skill-v1"], ["memory-v1"], [contribution], [artifact], lane, rendered
    ))
    let secondManifest = secondCompiled.value().getOrThrow()
    expect(store.save(secondManifest, [artifact], 10).isOk(),
        "later Context Manifest is durable before continuation")
    database.execute(
        "UPDATE step_records SET lane_id='review' WHERE id='inbox-step-context-2'"
    )
    expect(store.recordContextReady(
        RunId("inbox-run"), secondManifest, 11
    ).isError(), "ContextReady rejects a Manifest/Step identity mismatch")
    database.execute(
        "UPDATE step_records SET lane_id='main' WHERE id='inbox-step-context-2'"
    )
    expect(store.recordContextReady(
        RunId("inbox-run"), secondManifest, 11
    ).isOk() && decodeDurableRunContinuation(database.query(
        "SELECT payload FROM run_continuations WHERE run_id='inbox-run'"
    )[0].required(0)).stepOrdinal == 2,
        "ContextReady recovery preserves a nonzero canonical Step ordinal")
    let canonical = database.query(
        "SELECT payload FROM context_manifests WHERE id='manifest-inbox-1'"
    )[0].required(0)
    database.execute(
        "UPDATE context_manifests SET payload='corrupt' WHERE id='manifest-inbox-1'"
    )
    expect(store.load(manifest.id).isError(),
        "corrupt Context Manifest fails closed")
    database.execute(
        "UPDATE context_manifests SET payload=? WHERE id='manifest-inbox-1'",
        [SqlParameter.Text(canonical)]
    )
}

func removeV10Schema(database: SqliteDatabase): Unit {
    database.execute("ALTER TABLE run_continuations DROP COLUMN active_attempt_id")
    database.execute("DROP TABLE legacy_run_continuation_imports")
    database.execute("ALTER TABLE runs ADD COLUMN continuation TEXT")
    database.execute("DROP TABLE lane_run_admissions")
    database.execute("DROP TABLE team_messages")
    database.execute("DROP TABLE team_tasks")
    database.execute("DROP TABLE team_members")
    database.execute("DROP TABLE teams")
    database.execute("DROP TABLE run_composition_bindings")
    database.execute("DROP TABLE composition_snapshots")
    database.execute("DROP TRIGGER runs_bind_main_lane")
    database.execute("DROP TRIGGER items_create_main_edge")
    database.execute("DROP TRIGGER threads_create_main_lane")
    database.execute("DROP TABLE run_lane_bindings")
    database.execute("DROP TABLE item_tree_edges")
    database.execute("DROP TABLE lanes")
    database.execute("DROP TABLE context_manifests")
    database.execute("DROP TABLE prompt_contribution_artifacts")
    database.execute("DROP TABLE step_records")
    database.execute("DROP TABLE lane_inbox_entries")
    database.execute("DROP TABLE operation_state_registers")
    database.execute("DROP TABLE operation_effect_records")
    database.execute("DROP TABLE app_event_outbox")
    database.execute("DROP TABLE run_continuation_facts")
    database.execute("DROP TABLE run_continuations")
    database.execute("DROP TABLE thread_commit_heads")
    database.execute("ALTER TABLE audit_events DROP COLUMN commit_sequence")
}

func totalContinuationCrashContract(): Unit {
    let names = [
        "accepted", "context_compiling", "context_ready", "model_ready",
        "model_effect_pending", "model_settling", "decision_ready", "tool_batch_ready",
        "waiting_approval", "tool_effect_pending", "tool_settling", "waiting_external",
        "checkpoint", "terminalizing"
    ]
    var index: Int64 = 0
    for (name in names) {
        let root = Directory.createTemp("/tmp").toString()
        let path = root + "/" + name + ".db"
        let seed = SqliteDatabase(path)
        seedContinuationRun(seed, name)
        seed.close()

        // Deterministic crash immediately before the transaction: reopening
        // observes neither a register nor an immutable partial fact.
        let before = SqliteDatabase(path)
        expect(SqliteSemanticStore(before).continuation(
            RunId("crash-run-" + name)
        ).isError() && before.scalarInt(
            "SELECT COUNT(*) FROM run_continuation_facts"
        ) == 0, "crash before " + name + " transaction exposes no partial phase")
        let continuation = crashContinuation(name)
        expect(interpretRunContinuation(continuation).isOk(),
            "phase interpreter handles " + name + " exhaustively")
        let committed = SqliteSemanticStore(before).transact(
            TransactionPreconditions(
                ThreadId("crash-thread-" + name), 0,
                RunId("crash-run-" + name), 0
            ),
            DurableWriteSet(
                continuation: Some(continuation),
                appEvents: [SemanticAppEvent(
                    "crash-event-" + name, "run.phase_changed",
                    objectValue([ValueField("phase", textValue(name))]), index
                )]
            )
        )
        expect(committed.isOk(), "phase transaction commits for " + name)
        before.close()

        // Deterministic crash immediately after COMMIT: reopening sees one
        // exact sealed phase, one fact and one outbox record, never duplicates.
        let after = SqliteDatabase(path)
        let recovered = SqliteSemanticStore(after).continuation(
            RunId("crash-run-" + name)
        )
        expect(recovered.isOk() &&
            runExecutionPhaseName(recovered.value().getOrThrow().phase) == name &&
            recovered.value().getOrThrow().digest == continuation.digest &&
            after.scalarInt("SELECT COUNT(*) FROM run_continuation_facts") == 1 &&
            after.scalarInt("SELECT COUNT(*) FROM app_event_outbox") == 1,
            "crash after " + name + " transaction restores exactly one phase")
        after.close()
        index += 1
    }
    let invalidTerminal = sealDurableRunContinuation(phaseContinuation(
        "invalid-terminal",
        RunExecutionPhase.Terminalizing(DurablePhaseState(objectValue([]))),
        workDebt: WorkDebtSnapshot(ownedTasks: [OwnedTaskId("unfinished")])
    ))
    expect(interpretRunContinuation(invalidTerminal).isError(),
        "terminal phase is rejected until all WorkDebt converges")
}

func seedContinuationRun(database: SqliteDatabase, name: String): Unit {
    database.transaction { transaction =>
        transaction.execute(
            "INSERT INTO threads VALUES (?,?,?,'open',1,?)",
            [
                SqlParameter.Text("crash-thread-" + name), SqlParameter.Int64Value(0),
                SqlParameter.Text("workspace"), SqlParameter.Text("crash-turn-" + name)
            ]
        )
        transaction.execute(
            "INSERT INTO turns VALUES (?,?,1,'active',?,?)",
            [
                SqlParameter.Text("crash-turn-" + name),
                SqlParameter.Text("crash-thread-" + name),
                SqlParameter.Text("crash-user-" + name),
                SqlParameter.Text("crash-run-" + name)
            ]
        )
        transaction.execute(
            "INSERT INTO items VALUES (?,?,?,1,'user_message','{}','{}',0)",
            [
                SqlParameter.Text("crash-user-" + name),
                SqlParameter.Text("crash-thread-" + name),
                SqlParameter.Text("crash-turn-" + name)
            ]
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES " +
                "(?,?,?,1,'running','{}','{}','{}','{}',0,NULL,NULL)",
            [
                SqlParameter.Text("crash-run-" + name),
                SqlParameter.Text("crash-thread-" + name),
                SqlParameter.Text("crash-turn-" + name)
            ]
        )
    }
}

func crashContinuation(name: String): DurableRunContinuationV1 {
    let state = DurablePhaseState(objectValue([
        ValueField("self_contained_phase", textValue(name))
    ]))
    let value = match (name) {
        case "accepted" => phaseContinuation(name, RunExecutionPhase.Accepted(state))
        case "context_compiling" => phaseContinuation(name, RunExecutionPhase.ContextCompiling(state))
        case "context_ready" => phaseContinuation(name, RunExecutionPhase.ContextReady(state))
        case "model_ready" => phaseContinuation(name, RunExecutionPhase.ModelReady(state))
        case "model_effect_pending" => phaseContinuation(
            name, RunExecutionPhase.ModelEffectPending(state),
            semanticRequestId: Some(SemanticModelRequestId("request-" + name)),
            attemptId: Some(ModelAttemptId("attempt-" + name)),
            decisionId: Some(ModelDecisionId("decision-" + name)),
            usageId: Some(UsageRecordId("usage-" + name)),
            workDebt: WorkDebtSnapshot(activeAttempts: [ModelAttemptId("attempt-" + name)])
        )
        case "model_settling" => phaseContinuation(
            name, RunExecutionPhase.ModelSettling(state),
            attemptId: Some(ModelAttemptId("attempt-" + name)),
            decisionId: Some(ModelDecisionId("decision-" + name)),
            usageId: Some(UsageRecordId("usage-" + name)),
            workDebt: WorkDebtSnapshot(activeAttempts: [ModelAttemptId("attempt-" + name)])
        )
        case "decision_ready" => phaseContinuation(
            name, RunExecutionPhase.DecisionReady(state),
            decisionId: Some(ModelDecisionId("decision-" + name))
        )
        case "tool_batch_ready" => phaseContinuation(
            name, RunExecutionPhase.ToolBatchReady(state),
            toolBatch: Some(ToolBatchContinuation(
                ToolBatchId("batch-" + name), 0, [OperationId("operation-" + name)]
            ))
        )
        case "waiting_approval" =>
            let operation = OperationId("operation-" + name)
            let approval = ApprovalId("approval-" + name)
            phaseContinuation(
                name, RunExecutionPhase.WaitingApproval(state),
                operationId: Some(operation), approvalId: Some(approval),
                workDebt: WorkDebtSnapshot(
                    unsettledOperations: [operation], pendingApprovals: [approval]
                )
            )
        case "tool_effect_pending" =>
            let operation = OperationId("operation-" + name)
            phaseContinuation(
                name, RunExecutionPhase.ToolEffectPending(state),
                operationId: Some(operation),
                workDebt: WorkDebtSnapshot(unsettledOperations: [operation])
            )
        case "tool_settling" =>
            let operation = OperationId("operation-" + name)
            phaseContinuation(
                name, RunExecutionPhase.ToolSettling(state),
                operationId: Some(operation),
                workDebt: WorkDebtSnapshot(unsettledOperations: [operation])
            )
        case "waiting_external" =>
            let handle = ExternalHandleId("external-" + name)
            phaseContinuation(
                name, RunExecutionPhase.WaitingExternal(state),
                external: Some(ExternalWaitState(handle, "remote_job", objectValue([
                    ValueField("remote_id", textValue("remote-1"))
                ]))),
                workDebt: WorkDebtSnapshot(waitingExternal: [handle])
            )
        case "checkpoint" => phaseContinuation(name, RunExecutionPhase.Checkpoint(state))
        case "terminalizing" => phaseContinuation(name, RunExecutionPhase.Terminalizing(state))
        case _ => throw IllegalStateException("unknown crash continuation phase")
    }
    sealDurableRunContinuation(value)
}

func phaseContinuation(
    name: String,
    phase: RunExecutionPhase,
    semanticRequestId!: ?SemanticModelRequestId = None,
    attemptId!: ?ModelAttemptId = None,
    decisionId!: ?ModelDecisionId = None,
    usageId!: ?UsageRecordId = None,
    toolBatch!: ?ToolBatchContinuation = None,
    operationId!: ?OperationId = None,
    approvalId!: ?ApprovalId = None,
    external!: ?ExternalWaitState = None,
    workDebt!: WorkDebtSnapshot = WorkDebtSnapshot()
): DurableRunContinuationV1 {
    DurableRunContinuationV1(
        RunId("crash-run-" + name), LaneId("main"),
        SemanticTurnId("crash-turn-" + name), 0, phase,
        CompositionSnapshotId("composition-" + name),
        ModelLaneSnapshotId("model-lane-" + name),
        semanticRequestId: semanticRequestId,
        attemptId: attemptId,
        reservedDecisionId: decisionId,
        reservedUsageId: usageId,
        toolBatch: toolBatch,
        pendingOperationId: operationId,
        pendingApprovalId: approvalId,
        waitingExternal: external,
        workDebt: workDebt
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
