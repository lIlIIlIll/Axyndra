package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func artifactMatrixBlobCount(fixture: LifecycleManagerFixture): Int64 {
    let directory = fixture.files.root + "/state/blobs"
    if (exists(Path(directory))) { Directory.readFrom(directory).size } else { 0 }
}
func artifactMatrixPins(fixture: LifecycleManagerFixture): Int64 {
    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_artifact_observed'")
}
func artifactMatrixUnknown(fixture: LifecycleManagerFixture, thread: String): Int64 {
    fixture.database.query("SELECT receipt.id FROM operation_receipts receipt JOIN operations op " +
        "ON op.id=receipt.operation_id JOIN runs run ON run.id=op.run_id JOIN operation_effect_records e " +
        "ON e.operation_id=op.id WHERE run.thread_id=? AND e.tool_id=? AND receipt.outcome='unknown'",
        [SqlParameter.Text(thread), SqlParameter.Text(fixture.name)]).size
}
func artifactMatrixWaitFile(fixture: LifecycleManagerFixture, baseline: Int64): Unit {
    let deadline = MonoTime.now() + Duration.second * 8
    while (artifactMatrixBlobCount(fixture) == baseline && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
    if (artifactMatrixBlobCount(fixture) != baseline + 1) { throw IllegalStateException("actual partial artifact was never opened") }
}

@Test
class PluginServiceArtifactTests {
    @TestCase
    func rejectedOrIncompleteStreamsCannotWashErrorIntoSuccessAndDiscardNoCleanupOwner(): Unit {
        for (mode in ["artifact_bad_offset", "artifact_bad_digest", "artifact_incomplete",
            "artifact_second_active", "artifact_foreign_path", "artifact_crash"]) {
            let fixture = LifecycleManagerFixture(completeCapabilities: true)
            try {
                let service = lifecycleTestRequire(fixture.startProtocol("artifact-invalid", "artifact-maintenance")).service.getOrThrow()
                let baseline = artifactMatrixBlobCount(fixture)
                @Expect(managedRejected(channelTestCall(fixture, "artifact-invalid", "invalid",
                    channelTestInput("70696e670a", mode: mode))))
                @Expect(channelTestChildren(fixture, "artifact-invalid", "completed"), 1)
                @Expect(channelTestHandoffs(fixture, "artifact-invalid"), 1)
                @Expect(artifactMatrixUnknown(fixture, "artifact-invalid"), 1)
                @Expect(artifactMatrixPins(fixture), 0)
                @Expect(!service.active())
                channelTestAwaitReleased(fixture)
                @Expect(artifactMatrixBlobCount(fixture), baseline)
                @Expect(managedRejected(channelTestCall(fixture, "artifact-invalid", "no-replay", channelTestInput("70696e670a"))))
                @Expect(channelTestHandoffs(fixture, "artifact-invalid"), 1)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func completedObservationSurvivesDuplicateFinishOrWorkerCrashAndActualGcRecheck(): Unit {
        for (mode in ["artifact_duplicate", "artifact_late_finish", "artifact_finish_crash"]) {
            let fixture = LifecycleManagerFixture(completeCapabilities: true)
            try {
                let _ = lifecycleTestRequire(fixture.startProtocol("artifact-pinned", "artifact-maintenance"))
                let baseline = artifactMatrixBlobCount(fixture)
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("artifact-pinned")))
                session.setThinking(ThinkingLevel.Off)
                let rejected = AtomicInt64(0)
                session.subscribe({ event =>
                    match (event.payload) {
                        case AgentEventPayload.ToolOutput(call, channel, text) =>
                            if (call.value == "finished" && channel == ToolOutputChannel.Progress &&
                                text.contains("artifact_rejection_observed") && text.contains("artifact.stream_protocol_invalid")) {
                                let _ = rejected.fetchAdd(1)
                            }
                        case _ => ()
                    }
                })
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("finished", fixture.name,
                    channelTestInput("70696e670a", mode: mode))
                @Expect(session.submit("Capture and retain the actual service artifact.").isError())
                // These exact cases require an observed broker rejection. A
                // duplicate accepted then followed by worker exit is not a
                // passing negative merely because the parent is Unknown.
                @Expect(rejected.load(), if (mode == "artifact_finish_crash") { 0 } else { 1 })
                @Expect(artifactMatrixUnknown(fixture, "artifact-pinned"), 1)
                @Expect(channelTestChildren(fixture, "artifact-pinned", "completed"), 1)
                channelTestAwaitReleased(fixture)
                @Expect(artifactMatrixPins(fixture), 1)
                @Expect(artifactMatrixBlobCount(fixture), baseline + 1)
                let digest = modelPolicySha256Text("content")
                let path = fixture.files.root + "/state/blobs/" + digest + ".txt"
                @Expect(String.fromUtf8(File.readFrom(path)), "content")
                // Reopen the actual database after the worker has died. No
                // in-memory observation is allowed to pin this content.
                let reopened = SqliteDatabase(fixture.files.root + "/state/state.db")
                try {
                    let pins = reopened.query("SELECT a.payload,a.operation_id FROM audit_events a JOIN " +
                        "operation_effect_records e ON e.operation_id=a.operation_id WHERE a.kind='service_artifact_observed' AND e.tool_id=?",
                        [SqlParameter.Text(fixture.name)])
                    @Expect(pins.size, 1)
                    let evidence = decodeStoredValue(pins[0].required(0))
                    @Expect(lifecycleText(evidence, "operation_id"), pins[0].required(1))
                    @Expect(lifecycleText(evidence.field("artifact").getOrThrow(), "sha256"), digest)
                    let candidate = GcBlobCandidate(digest); candidate.paths.add(path)
                    let result = reopened.transaction { tx => deleteUnreferencedGcBlob(tx, candidate) }
                    @Expect(result.retained && result.errors.isEmpty())
                    @Expect(exists(Path(path)))
                } finally { reopened.close() }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func cancellationAndRevocationRemoveRealPartialFileBeforeAcknowledgingCleanup(): Unit {
        for (mode in ["artifact_cancel", "artifact_revoke"]) {
            let fixture = LifecycleManagerFixture(completeCapabilities: true)
            try {
                let service = lifecycleTestRequire(fixture.startProtocol("artifact-cancel", "artifact-maintenance")).service.getOrThrow()
                let baseline = artifactMatrixBlobCount(fixture)
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("artifact-cancel")))
                session.setThinking(ThinkingLevel.Off)
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("partial", fixture.name,
                    channelTestInput("70696e670a", mode: mode))
                let pending = spawn { session.submit("Capture the service output.") }
                try {
                    artifactMatrixWaitFile(fixture, baseline)
                    if (mode == "artifact_cancel") { lifecycleTestRequire(session.cancel()) }
                    else { let _ = service.revoke() }
                    let _ = pending.get()
                    channelTestAwaitReleased(fixture)
                    @Expect(!service.active())
                    @Expect(artifactMatrixBlobCount(fixture), baseline)
                    @Expect(artifactMatrixPins(fixture), 0)
                    @Expect(channelTestChildren(fixture, "artifact-cancel", "completed"), 1)
                    @Expect(channelTestHandoffs(fixture, "artifact-cancel"), 1)
                } finally { let _ = session.cancel(); let _ = pending.get() }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func oldInvocationIdentityCannotFinishAnArtifactInTheNextActualRun(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true)
        try {
            let service = lifecycleTestRequire(fixture.startProtocol("artifact-stale", "artifact-maintenance")).service.getOrThrow()
            @Expect(!managedCompleted(channelTestCall(fixture, "artifact-stale", "same-call",
                channelTestInput("70696e670a", mode: "artifact_ok"))).isError)
            @Expect(artifactMatrixPins(fixture), 1)
            @Expect(managedRejected(channelTestCall(fixture, "artifact-stale", "same-call",
                channelTestInput("70696e670a", mode: "artifact_stale"))))
            @Expect(channelTestChildren(fixture, "artifact-stale", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "artifact-stale"), 1)
            @Expect(artifactMatrixPins(fixture), 1)
            @Expect(!service.active())
            channelTestAwaitReleased(fixture)
            let digest = modelPolicySha256Text("content")
            @Expect(String.fromUtf8(File.readFrom(fixture.files.root + "/state/blobs/" + digest + ".txt")), "content")
        } finally { fixture.close() }
    }
}
