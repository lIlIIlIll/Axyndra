package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real installed Native and the original SQLite/child-worker fixture. No
// synthetic job, Receipt, Source, service response or completion is inserted.
func jobSnapshotSelection165(f: WorkflowChildFixture111): Unit {
    File.writeTo(f.root + "/settings/plugins/primitives.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
            ValueField("namespace", textValue(f.namespace)), ValueField("package_digest", textValue(f.digest)),
            ValueField("tools", listValue([
                objectValue([ValueField("name", textValue("task")), ValueField("profile", textValue("frozen-primitives-v1")),
                    ValueField("services", listValue([textValue("child.start")])), ValueField("preparation_provider", textValue("prepare_child"))]),
                objectValue([ValueField("name", textValue("hub")), ValueField("profile", textValue("frozen-primitives-v1")),
                    ValueField("services", listValue([textValue("job.list")])), ValueField("preparation_provider", textValue("prepare_child"))])]))])]))])).toArray())
}
func jobSnapshotCall165(f: WorkflowChildFixture111, thread: SessionId, callId: String): ToolCall {
    ToolCall(callId, "plugin." + f.namespace + ".hub", objectValue([ValueField("op", textValue("jobs"))]))
}

@Test
class InstalledWorkflowActualJobs165Tests {
    @TestCase
    func actualHeldAndCompletedJobUsesOriginalPresentationWithoutExtraLaunchOrForeignRows165(): Unit {
        let f = WorkflowChildFixture111(asynchronous: true)
        let probe = ChildControlledTool111(true)
        let thread = SessionId("job-snapshot-original-165")
        try {
            jobSnapshotSelection165(f); childInstallProbe111(f, probe, false)
            let parent = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread, f.capabilities(),
                childBackgroundCall111(f, thread.value), budget: f.budget()))
            try { @Expect(!parent.isError); expectCanonicalReturnedReceipt(f.database, parent) }
            finally { parent.releasePayload() }
            let entered = MonoTime.now() + Duration.second * 5
            while (!probe.entered.load() && MonoTime.now() < entered) { sleep(Duration.millisecond * 5) }
            @Expect(probe.entered.load()); @Expect(probe.calls.load(), 1)
            let source = f.product.asyncJobs(thread)
            @Expect(source.size, 1); @Expect(source[0].executing); @Expect(source[0].result.isNone())
            let launches = f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'")
            let attempts = f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let held = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread, f.capabilities(),
                jobSnapshotCall165(f, thread, "job-snapshot-held-165"), budget: f.budget()))
            try {
                @Expect(!held.isError); expectCanonicalReturnedReceipt(f.database, held)
                let rows = held.output.field("jobs").getOrThrow().items
                @Expect(httpIntentText(held.output, "op"), "jobs"); @Expect(rows.size, 1)
                @Expect(httpIntentText(rows[0], "id"), source[0].id)
                @Expect(httpIntentText(rows[0], "agentId"), source[0].agentId)
                @Expect(httpIntentText(rows[0], "type"), source[0].jobType)
                @Expect(httpIntentText(rows[0], "label"), source[0].label)
                @Expect(httpIntentText(rows[0], "status"), source[0].status)
                @Expect(rows[0].field("result").isNone()); @Expect(rows[0].field("error").isNone())
                @Expect(held.payloadLease.isSome())
            } finally { held.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"), launches+1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), attempts)
            @Expect(probe.calls.load(), 1); @Expect(!probe.released.load())
            let foreignSession165 = SessionId("job-snapshot-foreign-165")
            let empty = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(foreignSession165, f.capabilities(),
                jobSnapshotCall165(f, foreignSession165, "job-snapshot-foreign-call-165"), budget: f.budget()))
            try {
                @Expect(canonicalAgentValue(empty.output), canonicalAgentValue(objectValue([
                    ValueField("op", textValue("jobs")), ValueField("jobs", listValue([]))])))
                expectCanonicalReturnedReceipt(f.database, empty)
            } finally { empty.releasePayload() }
            probe.released.store(true)
            let completed = childJob111(f, thread, "completed")
            let final = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread, f.capabilities(),
                jobSnapshotCall165(f, thread, "job-snapshot-completed-165"), budget: f.budget()))
            try {
                @Expect(!final.isError); expectCanonicalReturnedReceipt(f.database, final)
                @Expect(canonicalAgentValue(final.output), canonicalAgentValue(objectValue([
                    ValueField("op", textValue("jobs")), ValueField("jobs", asyncJobsValue([completed]))])))
            } finally { final.releasePayload() }
            @Expect(probe.calls.load(), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"), launches+3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
        } finally { probe.released.store(true); f.close() }
    }
}

// Historical full-byte Hub presentation oracles, test-only after Native migration.
func hubMessageValue(message: ProductHubMessageSnapshot): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(message.id)))
    fields.add(ValueField("from", textValue(message.from)))
    fields.add(ValueField("to", textValue(message.to)))
    fields.add(ValueField("message", textValue(message.message)))
    if (message.replyTo != "") {
        fields.add(
            ValueField(
                "replyTo",
                textValue(message.replyTo)
            )
        )
    }
    fields.add(
        ValueField(
            "createdAt",
            integerValue(message.createdAt)
        )
    )
    objectValue(fields.toArray())
}

func asyncJobsValue(jobs: Array<ProductAsyncJobSnapshot>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (job in jobs) {
        values.add(asyncJobValue(job))
    }
    listValue(values.toArray())
}
