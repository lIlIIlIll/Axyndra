package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.time.*
import yjson.*
import yjson_support.*

func httpPayloadStoreProfile(): AgentValue {
    objectValue([ValueField("version", integerValue(1)), ValueField("max_message_bytes", integerValue(16777216)),
        ValueField("max_input_bytes", integerValue(4194304)), ValueField("max_prepare_bytes", integerValue(8388608)),
        ValueField("max_result_bytes", integerValue(8388608)), ValueField("max_write_bytes", integerValue(4128768))])
}
func httpPayloadStoreIntent(): AgentValue {
    let raw = "immutable payload\n"; let hex = "696d6d757461626c65207061796c6f61640a"
    let digest = modelPolicySha256Text(hex)
    objectValue([ValueField("id", textValue("write-1")), ValueField("payload", objectValue([
        ValueField("schema", textValue(SERVICE_PAYLOAD_REFERENCE_SCHEMA)), ValueField("artifact_ref", textValue("blob:sha256:" + digest)),
        ValueField("encoding", textValue("hex")), ValueField("bytes", integerValue(raw.size)),
        ValueField("sha256", textValue(modelPolicySha256Text(raw))), ValueField("encoded_sha256", textValue(digest))]))])
}
func httpPayloadStoreFixture(committed: Bool, matchingGrant!: Bool = true): HttpStreamIntentStoreFixture {
    HttpStreamIntentStoreFixture(committed,
        payloadGrant: if (matchingGrant) { Some(httpPayloadStoreProfile()) } else { None }, payloadBinding: Some(httpPayloadStoreProfile()),
        payloadBody: httpPayloadStoreIntent().field("payload"), prepareParent: false)
}
func httpPayloadStoreWitness(fixture: HttpStreamIntentStoreFixture): AgentValue {
    let host = fixture.rootPlan.canonicalArguments.field("host_plan").getOrThrow()
    servicePayloadPreparationWitness(fixture.thread.value, fixture.run.value, fixture.epoch, fixture.call.callId,
        fixture.call.name, fixture.call.arguments, host.field("binding").getOrThrow(), httpPayloadStoreIntent())
}
func httpPayloadStorePin(fixture: HttpStreamIntentStoreFixture, witness: AgentValue): Unit {
    let payload = httpPayloadStoreIntent().field("payload").getOrThrow()
    let digest = httpIntentText(payload, "encoded_sha256")
    let size: Int64 = "immutable payload\n".size * 2
    let metadata = objectValue([ValueField("version", integerValue(1)), ValueField("ref", textValue("blob:sha256:" + digest)),
        ValueField("sha256", textValue(digest)), ValueField("bytes", integerValue(size)),
        ValueField("content_type", textValue("text/plain; charset=utf-8"))])
    fixture.database.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)", [
        SqlParameter.Text(digest), SqlParameter.Text("text/plain; charset=utf-8"), SqlParameter.Int64Value(size),
        SqlParameter.Text(stringifyUnifiedJson(metadata)), SqlParameter.Text("blobs/" + digest + ".txt")])
    fixture.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,NULL,'service_payload_prepared',?,30)",
        [SqlParameter.Text(fixture.thread.value), SqlParameter.Text(fixture.run.value), SqlParameter.Text(encodeStoredValue(witness))])
}
func httpPayloadStorePrepare(fixture: HttpStreamIntentStoreFixture): Result<Unit> {
    match (fixture.source) {
        case OperationRootSource.Committed(value) => fixture.store.prepare(fixture.parent, fixture.run, value, fixture.rootPlan)
        case OperationRootSource.Direct(value) => fixture.store.prepareDirectOperation(value, fixture.rootPlan)
    }
}
func httpPayloadStoreCorruptWitness(fixture: HttpStreamIntentStoreFixture): Unit {
    fixture.database.execute("UPDATE audit_events SET payload=? WHERE kind='service_payload_prepared'", [SqlParameter.Text(encodeStoredValue(objectValue([])))])
}
func httpPayloadStoreRestoreWitness(fixture: HttpStreamIntentStoreFixture): Unit {
    fixture.database.execute("UPDATE audit_events SET payload=? WHERE kind='service_payload_prepared'", [SqlParameter.Text(encodeStoredValue(httpPayloadStoreWitness(fixture)))])
}

func httpPayloadDurableContract(): Unit {
    var cases: Int64 = 0
    for (committed in [false, true]) {
        for (failure in ["missing", "input", "call", "run", "epoch", "binding", "duplicate", "mime", "exact"]) {
            let fixture = httpPayloadStoreFixture(committed)
            try {
                let witness = httpPayloadStoreWitness(fixture)
                if (failure == "input") { witness.put("input_digest", textValue(STREAM_CONTRACT_DIGEST)) }
                if (failure == "call") { witness.put("call_id", textValue("another-call")) }
                if (failure == "run") { witness.put("run_id", textValue("another-run")) }
                if (failure == "epoch") { witness.put("epoch", integerValue(fixture.epoch + 1)) }
                if (failure == "binding") { witness.put("binding_digest", textValue(STREAM_CONTRACT_DIGEST)) }
                if (failure != "missing") { httpPayloadStorePin(fixture, witness) }
                if (failure == "duplicate") { httpPayloadStorePin(fixture, witness) }
                if (failure == "mime") { fixture.database.execute("UPDATE artifacts SET mime='application/octet-stream'") }
                let prepared = httpPayloadStorePrepare(fixture)
                if (failure == "exact") {
                    httpContractRequire(prepared, "exact immutable payload preparation")
                    fixture.activateParent(); httpContractRequire(fixture.admit(), "exact payload child")
                    fixture.execute(); fixture.handoff()
                    httpContractRequire(fixture.store.settleDerivedOperation(fixture.run, fixture.parent,
                        fixture.receipt(OperationOutcome.Unknown)), "artifact child Unknown receipt")
                    expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='stream-child' AND outcome='unknown'") == 1,
                        "one canonical artifact-child receipt")
                } else {
                    expect(prepared.isError() && fixture.database.query("SELECT id FROM operations WHERE id='stream-parent'").isEmpty(),
                        "content metadata alone, a changed source, duplicate pin or foreign MIME cannot prepare an artifact operation: " + failure)
                }
                expect(fixture.database.query("PRAGMA foreign_key_check").isEmpty(), "payload preparation preserves foreign keys")
            } finally { fixture.close() }
            cases += 1
        }
        for (stage in ["admit", "execute", "handoff", "settle"]) {
            let fixture = httpPayloadStoreFixture(committed)
            try {
                httpPayloadStorePin(fixture, httpPayloadStoreWitness(fixture)); httpContractRequire(httpPayloadStorePrepare(fixture), "payload source prepared")
                fixture.activateParent()
                if (stage != "admit") { httpContractRequire(fixture.admit(), "payload source admitted") }
                if (stage == "handoff" || stage == "settle") { fixture.execute() }
                if (stage == "settle") { fixture.handoff() }
                httpPayloadStoreCorruptWitness(fixture)
                let rejected = if (stage == "admit") { fixture.admit().isError() }
                    else if (stage == "execute") { fixture.store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 34, false).isError() }
                    else if (stage == "handoff") { fixture.store.markExecutionHandoff(fixture.child, fixture.run, fixture.thread, 35).isError() }
                    else { fixture.store.settleDerivedOperation(fixture.run, fixture.parent, fixture.receipt(OperationOutcome.Unknown)).isError() }
                expect(rejected, "every actual state transition rechecks immutable payload pin: " + stage)
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='stream-child'") == 0,
                    "failed payload proof cannot create a terminal receipt")
                httpPayloadStoreRestoreWitness(fixture)
                if (stage == "admit") { httpContractRequire(fixture.admit(), "restored payload admit") }
                if (stage == "admit" || stage == "execute") { fixture.execute() }
                if (stage != "settle") { fixture.handoff() }
                httpContractRequire(fixture.store.settleDerivedOperation(fixture.run, fixture.parent,
                    fixture.receipt(OperationOutcome.Unknown)), "restored exact payload proof settles once")
            } finally { fixture.close() }
            cases += 1
        }
        let missingGrant = httpPayloadStoreFixture(committed, matchingGrant: false)
        try {
            httpPayloadStorePin(missingGrant, httpPayloadStoreWitness(missingGrant)); httpContractRequire(httpPayloadStorePrepare(missingGrant), "root proof alone is not a grant")
            missingGrant.activateParent()
            expect(missingGrant.admit().isError() && missingGrant.database.query("SELECT id FROM operations WHERE id='stream-child'").isEmpty(),
                "operator completed startup must explicitly grant this payload profile")
        } finally { missingGrant.close() }
        cases += 1
        httpPayloadCancellationContract(committed); cases += 1
    }
    expect(cases == 30, "every Direct and Committed payload proof scenario ran")
    println("Immutable HTTP payload durable contract passed: 30 scenarios")
}

func httpPayloadCancellationContract(committed: Bool): Unit {
    let fixture = httpPayloadStoreFixture(committed)
    try {
        httpPayloadStorePin(fixture, httpPayloadStoreWitness(fixture)); httpContractRequire(httpPayloadStorePrepare(fixture), "cancel payload prepared")
        fixture.activateParent(); httpContractRequire(fixture.admit(), "cancel payload admitted"); fixture.execute(); fixture.handoff()
        let token = httpContractRequire(fixture.runtime.childCancellationToken(expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)), "actual payload cancellation")
        let task = spawn {
            let deadline = agentUtcMillis() + 3000
            while (!token.isCancelled() && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
            expect(token.isCancelled(), "actual canonical cancellation reached child cleanup")
            httpPayloadStoreCorruptWitness(fixture)
            expect(fixture.store.settleDerivedOperation(fixture.run, fixture.parent, fixture.receipt(OperationOutcome.Unknown)).isError(),
                "cancelled cleanup still requires the historical exact payload witness")
            httpPayloadStoreRestoreWitness(fixture)
            expect(fixture.admit().isError() && fixture.store.markExecutionHandoff(fixture.child, fixture.run, fixture.thread, 40).isError(),
                "late observation permission does not reopen execution")
            httpContractRequire(fixture.store.settleDerivedOperation(fixture.run, fixture.parent, fixture.receipt(OperationOutcome.Unknown)), "late genuine artifact child Unknown")
            let result = httpContractRequire(fixture.runtime.resolveOperation(ItemId("payload-parent-result"), fixture.parent,
                CanonicalToolCallId(fixture.call.callId), fixture.rootPlan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.RecoveryRequired, "payload.cancel_unknown", "cancelled after possible write")),
                "receipt-payload-parent", 42, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)), "payload parent Unknown")
            expect(result.semanticCommit.isSome() && isStoreCommitted(result.semanticCommit.getOrThrow()), "payload root Unknown is a real canonical commit")
        }
        httpContractRequire(fixture.runtime.ownTask("payload-settlement", task), "owned late payload cleanup")
        let cancelled = fixture.runtime.cancel(5000, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch))
        task.get(); httpContractRequire(cancelled, "payload cancellation joins its canonical cleanup")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'") == 2,
            "cancellation preserves both original payload parent and child Unknown facts")
    } finally { fixture.close() }
}
