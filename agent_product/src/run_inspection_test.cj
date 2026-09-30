package agent_product

import agent_domain.*
import agent_store.*
import agent_runtime.*
import yjson_support.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import std.time.*

@Test
class RunInspectionContractTests {
    @TestCase
    func modelRequestLimitKeepsNewestAttemptsInDisplayOrder(): Unit {
        let root = runInspectionTestTemp("newest-attempts")
        Directory.create(root, recursive: true)
        let database = SqliteDatabase(root + "/state.db")
        try {
            seedInspectionRun(database)
            let policy = sqliteText(encodeStoredValue(objectValue([])))
            for (attemptNo in 1..102) {
                let suffix = attemptNo.toString()
                database.execute(
                    "INSERT INTO model_attempts(" +
                        "id,semantic_request_id,run_id,parent_attempt_id,attempt_no,lifecycle," +
                        "policy,policy_reason,started_at_millis,last_activity_at_millis," +
                        "completed_at_millis,provider_request_id,provider_response_id,failure_kind," +
                        "semantic_request_digest,wire_policy_digest,dispatch_state,replay_barrier," +
                        "dispatch_started_at_millis,provider_terminal_at_millis) VALUES(" +
                        sqliteText("attempt-" + suffix) + "," +
                        sqliteText("semantic-" + suffix) + ",'inspection-run',NULL," + suffix +
                        ",'completed'," + policy + ",'fixture'," + suffix + "," + suffix + "," + suffix + "," +
                        sqliteText("request-" + suffix) + ",'','','semantic-digest','wire-digest'," +
                        "'terminal','closed'," + suffix + "," + suffix + ")"
                )
            }

            let unsealedManifest = ModelContextManifest(
                ContextManifestId("inspection-manifest"),
                ThreadId("inspection-thread"),
                LaneId("main"),
                SemanticTurnId("inspection-turn"),
                StepId("inspection-step"),
                1,
                [ItemId("inspection-user")],
                ItemId("inspection-user"),
                objectValue([]),
                [],
                [],
                [],
                objectValue([]),
                100,
                1,
                objectValue([]),
                "compiler-v1"
            )
            let manifest = sealInspectionManifest(unsealedManifest)
            let manifestDigest = manifest.digest
            database.execute(
                "INSERT INTO step_records(id,thread_id,lane_id,turn_id,run_id,ordinal," +
                    "input_entry_id,accepted_item_id,status,opened_at_millis,settled_at_millis,revision) " +
                    "VALUES('inspection-step','inspection-thread','main','inspection-turn'," +
                    "'inspection-run',1,NULL,NULL,'completed',1,1,1)"
            )
            database.execute(
                "INSERT INTO context_manifests(id,thread_id,lane_id,turn_id,step_id,digest,payload," +
                    "created_at_millis) VALUES('inspection-manifest','inspection-thread','main'," +
                    "'inspection-turn','inspection-step'," + sqliteText(manifestDigest) + "," +
                    sqliteText(encodeContextManifest(manifest)) + ",1)"
            )
            let page = match (ProductRunInspectionProjection(database).inspect(
                ThreadId("inspection-thread"), RunId("inspection-run"), 0, 10
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(
                    error.code + ": " + error.message
                )
            }
            @Expect(page.modelRequests.size, 100)
            @Expect(page.modelRequests[0].attemptId, "attempt-2")
            @Expect(page.modelRequests[99].attemptId, "attempt-101")
            @Expect(page.modelRequests[0].sequence, 1)
            @Expect(page.modelRequests[99].sequence, 100)
            @Expect(page.warnings.contains("model.requests_truncated"), true)
            @Expect(page.contexts.size, 1)
            @Expect(page.contexts[0].manifestDigest, manifestDigest)
            @Expect(page.contexts[0].compilerVersion, "compiler-v1")
            @Expect(page.contexts[0].compilerDigest, "")
        } finally {
            database.close()
            remove(root, recursive: true)
        }
    }
}

func sealInspectionManifest(value: ModelContextManifest): ModelContextManifest {
    ModelContextManifest(
        value.id, value.threadId, value.laneId, value.turnId, value.stepId,
        value.threadRevision, value.branchItemIds, value.currentIntentItemId,
        value.namedFactVersions, value.activeSkillIds, value.memoryReferences,
        value.promptContributions, value.toolCatalogSnapshot, value.tokenBudget,
        value.estimatedTokens, value.renderedRequest, value.compilerVersion,
        checkpointId: value.checkpointId, digest: contextManifestDigest(value)
    )
}

func seedInspectionRun(database: SqliteDatabase): Unit {
    let empty = sqliteText(encodeStoredValue(objectValue([])))
    database.transaction<Unit>({ transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                "VALUES('inspection-thread',1,'workspace','open',2,'inspection-turn')"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                "VALUES('inspection-turn','inspection-thread',1,'active','inspection-user','inspection-run')"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES('inspection-user','inspection-thread','inspection-turn',1,'user_message','{}','user',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
                "VALUES('inspection-run','inspection-thread','inspection-turn',1,'running'," +
                empty + "," + empty + "," + empty + "," + empty + ",1)"
        )
    })
}

func runInspectionTestTemp(label: String): String {
    let base = homeDirectory() + "/.cache/agent-tmp/axyndra-run-inspection-tests"
    if (!exists(Path(base))) { Directory.create(base, recursive: true) }
    base + "/" + label + "-" +
        DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
}
