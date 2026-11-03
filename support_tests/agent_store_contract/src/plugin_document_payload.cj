package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*
import std.sync.*
import std.fs.*
import yjson.*
import yjson_support.*

func pluginDocumentPayloadReadContracts(): Unit {
    for (committed in [false, true]) {
        for (mode in ["completed", "large", "raw", "retained", "double", "absence",
            "bypass", "wrong-digest", "wrong-mime", "missing-metadata", "mutated-row", "forged-return", "missing", "oversize"]) {
            documentReadScenario(committed, if (mode == "absence") { "absence" } else { "completed" }, payloadMode: mode)
        }
        for (mode in ["intent-completed", "intent-missing-budget", "intent-changed-before-prepare",
            "intent-changed-before-execute", "intent-changed-before-handoff", "intent-changed-before-child",
            "intent-changed-before-child-execute", "intent-changed-before-settle", "intent-expanded-before-prepare"]) {
            documentReadScenario(committed, "completed", payloadMode: mode)
        }
        for (mode in ["intent-cas-completed", "intent-cas-large", "intent-cas-missing-pin", "intent-cas-missing-reader",
            "intent-cas-bypass", "intent-cas-double", "intent-cas-retained", "intent-cas-content-changed",
            "intent-cas-noncanonical", "intent-cas-invalid-json", "intent-cas-receipt-rollback", "intent-cas-participant-rollback",
            "intent-cas-trigger-changed", "intent-cas-final-guard", "intent-cas-plan-tamper", "intent-cas-fact-tamper",
            "intent-cas-pin-idempotent", "intent-cas-pin-oversize", "intent-cas-pin-overcount"]) {
            documentReadScenario(committed, "completed", payloadMode: mode)
        }
        for (mode in ["intent-cas-result-completed", "intent-cas-result-same-revision-bytes", "intent-cas-result-revision",
            "intent-cas-result-missing-receipt", "intent-cas-result-tampered-receipt"]) {
            documentReadScenario(committed, "completed", payloadMode: mode)
        }
        for (scenario in ["no-handoff", "cancelled", "guard-before", "guard-after", "different-parent"]) {
            documentReadScenario(committed, scenario, payloadMode: "completed")
        }
    }
    for(committed in [false,true]){documentPayloadManyParents(committed)}
    println("Plugin document payload Store contract passed: 106 scenarios")
}

// This is deliberately a Store-only adapter: it registers metadata in the
// supplied transaction but does not pretend to write/verify an OS file. Actual
// ProductArtifactStore tests must prove the physical file and GC lifetime.
class DocumentPayloadFixture <: PluginDocumentPayloadMaterializer {
    private let mode: String
    var calls: Int64 = 0
    var retained: ?SqlitePluginDocumentPayloadReadProof = None
    init(mode: String) { this.mode = mode }
    public func materialize(value: PluginDocumentPayloadReadProof): Result<AgentValue> {
        calls++
        let proof = match (value as SqlitePluginDocumentPayloadReadProof) { case Some(actual) => actual
            case None => throw IllegalStateException("actual Store materialization proof required") }
        retained = Some(proof)
        if (mode == "bypass") { return Result.Ok(documentPayloadFixtureValue(modelPolicySha256Text("null"), 4)) }
        let result = proof.materialize({ transaction, snapshot, digest =>
            expect(snapshot.threadId.value == proof.threadId.value && snapshot.laneId.value == proof.laneId.value &&
                snapshot.key == proof.key && snapshot.revision == proof.revision && snapshot.encoded.size == proof.bytes,
                "materializer cannot choose a foreign row")
            expect(digest == modelPolicySha256Text(snapshot.encoded), "Store binds complete original bytes, including corrupt history")
            let selected = if (mode == "wrong-digest") { modelPolicySha256Text("other") } else { digest }
            let payload = documentPayloadFixtureValue(selected, snapshot.encoded.size)
            if (mode != "missing-metadata") {
                let mime = if (mode == "wrong-mime") { "application/json" } else { "text/plain; charset=utf-8" }
                let metadata = objectValue([ValueField("version", integerValue(1)),
                    ValueField("ref", textValue("blob:sha256:" + selected)), ValueField("sha256", textValue(selected)),
                    ValueField("bytes", integerValue(snapshot.encoded.size)), ValueField("content_type", textValue(mime))])
                transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(selected), SqlParameter.Text(mime), SqlParameter.Int64Value(snapshot.encoded.size),
                        SqlParameter.Text(encodeAgentValue(metadata) + "\n"), SqlParameter.Text("blobs/" + selected + ".txt")])
            }
            if (mode == "mutated-row") {
                transaction.execute("UPDATE plugin_documents SET revision=revision+1 WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                    [SqlParameter.Text(snapshot.threadId.value), SqlParameter.Text(snapshot.laneId.value),
                        SqlParameter.Text(snapshot.namespace), SqlParameter.Text(snapshot.key)])
            }
            Result.Ok(payload)
        })
        if (mode == "double") {
            expect(proof.materialize({ _, _, _ => Result.Ok(nullValue()) }).isError(), "same supplied proof is consumed once") }
        if (mode == "forged-return" && result.isOk()) {
            return Result.Ok(documentPayloadFixtureValue(modelPolicySha256Text("foreign"), 7)) }
        result
    }
}

func documentPayloadFixtureValue(digest: String, bytes: Int64): AgentValue {
    objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref", textValue("blob:sha256:" + digest)), ValueField("encoding", textValue("utf8")),
        ValueField("bytes", integerValue(bytes)), ValueField("sha256", textValue(digest)),
        ValueField("content_type", textValue("text/plain; charset=utf-8"))])
}

func documentPayloadFinalRead(database: SqliteDatabase, runtime: AgentThreadRuntime, owner: OperationRootSource,
    fact: ContextReadFact, binding: AgentValue, parentCall: ToolCall, epoch: Int64, mode: String, label: String): Unit {
    if (mode.startsWith("intent-cas-result-")) {
        documentPayloadFinalResult(database, owner, fact, binding, parentCall, epoch, mode, label); return }
    if(mode.startsWith("intent-cas-")) {
        documentPayloadFinalWrite(database,runtime,owner,fact,binding,parentCall,epoch,mode,label);return }
    let pool = LogicalJsonOwnerBudget(maximumTransfers: 1)
    let allocations = AtomicInt64(0)
    let allocate = { bytes: Int64 => let _ = allocations.fetchAdd(1); pool.acquire(max(1, bytes)) }
    let selected: ?(Int64) -> LogicalJsonOwnerReservation = if (mode == "intent-missing-budget") { None } else { Some(allocate) }
    let store = DurableOperationStore(database, documentPayloadAllocation: selected)
    let thread = ThreadId(httpIntentText(binding, "thread_id")); let run = fact.runId
    let row = fact.output().field("documents").getOrThrow().items[0]
    let intentValue = objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),
        ValueField("binding", binding), ValueField("intent", objectValue([ValueField("id", textValue("document-1")),
            ValueField("key", textValue("todo")), ValueField("mode", textValue("read")),
            ValueField("expected_revision", row.field("revision").getOrThrow()),
            ValueField("expected_payload", row.field("payload").getOrThrow()), ValueField("next_payload", nullValue())]))])
    let intent = parsePluginDocumentIntent(intentValue).value().getOrThrow()
    let rootArgs = objectValue([ValueField("input", objectValue([])), ValueField("configuration", objectValue([])),
        ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)),
            ValueField("binding", binding), ValueField("intents", listValue([intentValue.field("intent").getOrThrow()]))]))])
    let rootPlan = NormalizedOperationPlan(parentCall.name, rootArgs,
        [Capability(CapabilityKind.ExtensionInvoke, resource: httpIntentText(binding, "namespace"))],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(rootArgs)),
        toolVersion: "workflow-v1", implementationFingerprint: httpIntentText(binding, "implementation_fingerprint"),
        schemaDigest: httpIntentText(binding, "schema_digest"), contextReadFacts: [fact.link()])
    let childPlan = documentServicePlan(true, intentValue)
    let parent = match (owner) {
        case OperationRootSource.Direct(value) => value.operationId
        case OperationRootSource.Committed(value) => OperationId("operation-" + value.decisionId.value + "-" + value.scopedToolCallId.value)
        case _ => throw IllegalStateException("actual test source required") }
    let child = OperationId("document-payload-child")
    let tamper = { =>
        // Explicit corruption seam: same revision, different bytes. Ordinary
        // writes use repository CAS; this negative must not evade the full SHA.
        database.execute("UPDATE plugin_documents SET payload=? WHERE thread_id=? AND namespace=? AND document_key='todo'",
            [SqlParameter.Text(if (mode == "intent-expanded-before-prepare") { String.fromUtf8(Array<Byte>(8388609, repeat: b'x')) }
                else { "{changed-at-same-revision}" }), SqlParameter.Text(thread.value), SqlParameter.Text("axyndra:workflow")])
    }
    if (mode == "intent-changed-before-prepare" || mode == "intent-expanded-before-prepare") { tamper() }
    let prepared = match (owner) {
        case OperationRootSource.Direct(value) => store.prepareDirectOperation(value, rootPlan)
        case OperationRootSource.Committed(value) => store.prepare(parent, run, value, rootPlan)
        case _ => throw IllegalStateException("actual test source required") }
    if (["intent-missing-budget", "intent-changed-before-prepare", "intent-expanded-before-prepare"].contains(mode)) {
        expect(prepared.isError() && database.scalarInt("SELECT COUNT(*) FROM operations") == 1, label + " invalid parent makes no new Operation")
        expect(pool.usage()[0] == 0 && pool.usage()[1] == 0, label + " refusal leaves no byte owner")
        if (mode == "intent-expanded-before-prepare") { expect(allocations.load() == 0, label + " row length is checked before allocation and raw SELECT") }
        return
    }
    httpContractRequire(prepared, label + " real compact parent preparation")
    if (mode == "intent-changed-before-execute") { tamper() }
    let executing = store.markExecutingWithSource(Some(owner), parent, run, rootPlan, 20, false)
    if (mode == "intent-changed-before-execute") { expect(executing.isError(), label + " full original bytes rechecked before parent execution"); return }
    httpContractRequire(executing, label + " actual parent executing")
    if (mode == "intent-changed-before-handoff") { tamper() }
    let handed = store.markExecutionHandoffWithSource(Some(owner), parent, run, thread, 21)
    if (mode == "intent-changed-before-handoff") { expect(handed.isError(), label + " no parent handoff after drift"); return }
    httpContractRequire(handed, label + " parent handoff")
    if (mode == "intent-changed-before-child") { tamper() }
    let admitted = store.prepareDerivedOperation(child, parent, run, owner, exactServiceRequestKey(parentCall.callId, childPlan), childPlan)
    if (mode == "intent-changed-before-child") { expect(admitted.isError(), label + " child cannot reuse stale read reference"); return }
    httpContractRequire(admitted, label + " actual reference child")
    if (mode == "intent-changed-before-child-execute") { tamper() }
    let childExecuting = store.markExecutingWithSource(Some(owner), child, run, childPlan, 22, false)
    if (mode == "intent-changed-before-child-execute") { expect(childExecuting.isError(), label + " child full bytes rechecked"); return }
    httpContractRequire(childExecuting, label + " child executing")
    httpContractRequire(store.markExecutionHandoffWithSource(Some(owner), child, run, thread, 23), label + " child handoff")
    if (mode == "intent-changed-before-settle") { tamper() }
    let receipt = VNextOperationReceipt("receipt-" + child.value, child, OperationOutcome.Completed, intent.result(), objectValue([]), 24)
    let settled = store.settlePluginDocumentOperation(run, parent, receipt, { => Result.Ok(()) })
    if (mode == "intent-changed-before-settle") {
        expect(settled.isError(), label + " no completed read from stale reference")
        httpContractRequire(store.settleDerivedOperation(run, parent, VNextOperationReceipt(receipt.receiptId, child,
            OperationOutcome.Unknown, objectValue([]), objectValue([]), 25)), label + " late uncertainty closes original debt without resurrecting bytes")
    } else {
        httpContractRequire(settled, label + " same transaction complete reference Receipt")
        let actual = httpContractRequire(store.loadDerivedOperationReceipt(child, run), label + " durable reference Receipt").getOrThrow()
        expect(canonicalAgentValue(actual.detail) == canonicalAgentValue(intent.result()) && actual.outcome == OperationOutcome.Completed,
            label + " complete result is the exact host-created reference")
    }
    expect(pool.usage()[0] == 0 && pool.usage()[1] == 0, label + " every Store phase releases only its actual raw byte lifetime")
}


class DocumentPayloadCommitFixture <: PluginDocumentPayloadCommitter {
    let raw: String
    let mode: String
    var calls: Int64=0
    var reads: Int64=0
    var retained: ?SqlitePluginDocumentPayloadCommitProof=None
    init(raw: String,mode: String) { this.raw=raw;this.mode=mode }
    public func commit(value: PluginDocumentPayloadCommitProof): Result<Unit> {
        calls++
        let proof=(value as SqlitePluginDocumentPayloadCommitProof).getOrThrow();retained=Some(proof)
        if(mode=="intent-cas-bypass") { return Result.Ok(()) }
        let result=proof.materialize({ reference =>
            reads++;expect(reference.bytes==raw.size && reference.digest==modelPolicySha256Text(raw),"Host sees exact prepared replacement reference")
            Result<String>.Ok(if(mode=="intent-cas-content-changed") { "null" } else { raw }) })
        if(mode=="intent-cas-double") {
            expect(proof.materialize({ _ => reads++;Result<String>.Ok(raw) }).isError(),"same actual commit proof cannot be consumed twice") }
        result
    }
}
class DocumentPayloadRollbackParticipant <: PluginDocumentCommitParticipant {
    var calls: Int64=0
    public func consume(proof: PluginDocumentCommitProof): Result<Unit> {
        calls++
        expect((proof as SqlitePluginDocumentCommitProof).isSome(),"actual Receipt transaction supplies participant proof")
        Result.Err(AgentError(AgentErrorKind.Conflict,"fixture.payload_participant_rejected","rollback after actual document CAS and Receipt insert"))
    }
}

func documentPayloadFinalWrite(database: SqliteDatabase, runtime: AgentThreadRuntime, owner: OperationRootSource,
    fact: ContextReadFact,binding: AgentValue,parentCall: ToolCall,epoch: Int64,mode: String,label: String,
    frozenContextInput!: Bool = false): Unit {
    let pool=LogicalJsonOwnerBudget(maximumTransfers:1)
    let allocations=AtomicInt64(0)
    let allocate={ bytes: Int64 => let _=allocations.fetchAdd(1);pool.acquire(max(1,bytes)) }
    let store=DurableOperationStore(database,documentPayloadAllocation:Some(allocate))
    let thread=ThreadId(httpIntentText(binding,"thread_id"));let run=fact.runId
    let row=fact.output().field("documents").getOrThrow().items[0]
    let raw=if(mode=="intent-cas-large") { encodeAgentValue(textValue(String.fromUtf8(Array<Byte>(8388606,repeat:b'z')))) }
        else if(mode=="intent-cas-noncanonical") { " {\"message\":\"replacement\"} " }
        else if(mode=="intent-cas-invalid-json") { "{missing" }
        else { encodeAgentValue(objectValue([ValueField("message",textValue("replacement 雪"))])) }
    let digest=modelPolicySha256Text(raw)
    let payload=documentPayloadFixtureValue(digest,raw.size)
    let value=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),ValueField("binding",binding),
        ValueField("intent",objectValue([ValueField("id",textValue("document-1")),ValueField("key",textValue("todo")),
            ValueField("mode",textValue("compare_exchange")),ValueField("expected_revision",row.field("revision").getOrThrow()),
            ValueField("expected_payload",row.field("payload").getOrThrow()),ValueField("next_payload",payload)]))])
    let intent=parsePluginDocumentIntent(value).value().getOrThrow()
    let old=database.query("SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND namespace='axyndra:workflow' AND document_key='todo'",[SqlParameter.Text(thread.value)])
    database.transaction { tx =>
        let metadata=objectValue([ValueField("version",integerValue(1)),ValueField("ref",textValue("blob:sha256:"+digest)),
            ValueField("sha256",textValue(digest)),ValueField("bytes",integerValue(raw.size)),ValueField("content_type",textValue("text/plain; charset=utf-8"))])
        tx.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",[SqlParameter.Text(digest),
            SqlParameter.Text("text/plain; charset=utf-8"),SqlParameter.Int64Value(raw.size),SqlParameter.Text(encodeAgentValue(metadata)+"\n"),SqlParameter.Text("blobs/"+digest+".txt")])
        if(mode!="intent-cas-missing-pin") {
            httpContractRequire(retainPreparedPluginDocumentPayload(tx,fact.link(),value,allocate,{ => Result<Unit>.Ok(()) }),label+" exact pending parent preparation pin") }
    }
    if(mode=="intent-cas-pin-idempotent" || mode=="intent-cas-pin-oversize" || mode=="intent-cas-pin-overcount") {
        let before=allocations.load()
        if(mode=="intent-cas-pin-oversize"){
            // Explicit damaged-history seam, not an alternative producer of
            // authority. The length guard must refuse before reading payload.
            database.execute("UPDATE audit_events SET payload=? WHERE kind='plugin_document_payload_prepared'",
                [SqlParameter.Text(String.fromUtf8(Array<Byte>(65537,repeat:b'x')))])
        }
        if(mode=="intent-cas-pin-overcount"){
            for(_ in 0..8){database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                "SELECT thread_id,run_id,operation_id,kind,payload,created_at_millis FROM audit_events WHERE kind='plugin_document_payload_prepared' LIMIT 1")}
        }
        let repeated=database.transaction{tx=>retainPreparedPluginDocumentPayload(tx,fact.link(),value,allocate,{=>Result<Unit>.Ok(())})}
        if(mode=="intent-cas-pin-idempotent"){
            httpContractRequire(repeated,label+" exact repeat is idempotent")
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_prepared'")==1,label+" no duplicate pin")
        }else{
            expect(repeated.isError(),label+" corrupt bounded history cannot admit another pin")
            // Only the original document bytes were allocated; no corrupt
            // witness raw SELECT/DOM allocation happened after metadata.
            expect(allocations.load()==before+1,label+" metadata rejects before witness allocation")
        }
        expect(database.scalarInt("SELECT COUNT(*) FROM operations")==1,label+" preparation pin is not a parent Operation")
        expect(pool.usage()[0]==0 && pool.usage()[1]==0,label+" all bounded preparation leases released")
        return
    }
    let input=objectValue([])
    if(frozenContextInput){input.put(CONTEXT_READ_INPUT_FIELD,objectValue([
        ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",fact.output()),
        ValueField("facts",contextReadFactLinksValue([fact.link()]))]))}
    let args=objectValue([ValueField("input",input),ValueField("configuration",objectValue([])),
        ValueField("host_plan",objectValue([ValueField("version",textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)),ValueField("binding",binding),
            ValueField("intents",listValue([value.field("intent").getOrThrow()]))]))])
    let plan=NormalizedOperationPlan(parentCall.name,args,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow")],
        OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(args)),
        toolVersion:"workflow-v1",implementationFingerprint:httpIntentText(binding,"implementation_fingerprint"),
        schemaDigest:httpIntentText(binding,"schema_digest"),contextReadFacts:[fact.link()])
    let parent=match(owner) {case OperationRootSource.Direct(v)=>v.operationId
        case OperationRootSource.Committed(v)=>OperationId("operation-"+v.decisionId.value+"-"+v.scopedToolCallId.value)
        case _=>throw IllegalStateException("actual source required")}
    let prepared=match(owner) {case OperationRootSource.Direct(v)=>store.prepareDirectOperation(v,plan)
        case OperationRootSource.Committed(v)=>store.prepare(parent,run,v,plan)
        case _=>throw IllegalStateException("actual source required")}
    if(mode=="intent-cas-missing-pin") {
        expect(prepared.isError() && database.scalarInt("SELECT COUNT(*) FROM operations")==1,label+" artifact descriptor alone cannot prepare mutation");return }
    httpContractRequire(prepared,label+" actual replacement parent prepared")
    httpContractRequire(store.markExecutingWithSource(Some(owner),parent,run,plan,30,false),label+" parent executing")
    httpContractRequire(store.markExecutionHandoffWithSource(Some(owner),parent,run,thread,31),label+" parent handoff")
    let child=OperationId(parent.value+"-payload-child");let childPlan=documentServicePlan(true,value)
    httpContractRequire(store.prepareDerivedOperation(child,parent,run,owner,exactServiceRequestKey(parentCall.callId,childPlan),childPlan),label+" exact replacement child")
    httpContractRequire(store.markExecutingWithSource(Some(owner),child,run,childPlan,32,false),label+" child executing")
    httpContractRequire(store.markExecutionHandoffWithSource(Some(owner),child,run,thread,33),label+" child handoff")
    if(mode=="intent-cas-receipt-rollback") {
        database.execute("CREATE TRIGGER payload_fail_receipt BEFORE INSERT ON operation_receipts WHEN NEW.operation_id='"+child.value+"' BEGIN SELECT RAISE(ABORT,'actual receipt failure'); END") }
    if(mode=="intent-cas-trigger-changed") {
        database.execute("CREATE TRIGGER payload_change_after_receipt AFTER INSERT ON operation_receipts WHEN NEW.operation_id='"+child.value+"' BEGIN UPDATE plugin_documents SET payload='null' WHERE document_key='todo'; END") }
    if(mode=="intent-cas-plan-tamper") {
        database.execute("UPDATE operations SET normalized_plan=? WHERE id=?",[SqlParameter.Text(documentTamperStoredPlan(database, store, child, run, documentServicePlan(true,
            objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),ValueField("binding",binding),ValueField("intent",objectValue([
                ValueField("id",textValue("foreign")),ValueField("key",textValue("todo")),ValueField("mode",textValue("read")),
                ValueField("expected_revision",row.field("revision").getOrThrow()),ValueField("expected_payload",row.field("payload").getOrThrow()),ValueField("next_payload",nullValue())]))])))),SqlParameter.Text(child.value)]) }
    if(mode=="intent-cas-fact-tamper") {
        database.execute("DELETE FROM audit_events WHERE operation_id=? AND kind='plugin_document_payload_observed'",[SqlParameter.Text(fact.operationId.value)])
        // Completed output is still present: the exact Host preparation pin
        // must independently remain bound and cannot be replaced by a hash.
        database.execute("DELETE FROM audit_events WHERE kind='plugin_document_payload_prepared'") }
    let reader=DocumentPayloadCommitFixture(raw,mode);let rollback=DocumentPayloadRollbackParticipant()
    let participant:?PluginDocumentCommitParticipant=if(mode=="intent-cas-participant-rollback"){Some(rollback)}else{None}
    let guardCalls=AtomicInt64(0)
    let guard={ => if(mode=="intent-cas-final-guard" && guardCalls.fetchAdd(1)>0) {
        Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.actual_commit_guard_closed","live guard closed after CAS")) } else {Result<Unit>.Ok(())} }
    let receipt=VNextOperationReceipt("receipt-"+child.value,child,OperationOutcome.Completed,intent.result(),objectValue([]),34)
    let result=if(mode=="intent-cas-missing-reader"){store.settlePluginDocumentOperation(run,parent,receipt,guard)}
        else{store.settlePluginDocumentOperation(run,parent,receipt,guard,participant,reader)}
    let success=["intent-cas-completed","intent-cas-large","intent-cas-double","intent-cas-retained"].contains(mode)
    let after=database.query("SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND namespace='axyndra:workflow' AND document_key='todo'",[SqlParameter.Text(thread.value)])
    if(success) {
        httpContractRequire(result,label+" canonical document CAS and Receipt")
        expect(after[0].required(0)==(intent.expectedRevision+1).toString() && after[0].required(1)==raw,label+" complete replacement preserved")
        let actual=httpContractRequire(store.loadDerivedOperationReceipt(child,run),label+" durable replacement Receipt").getOrThrow()
        expect(canonicalAgentValue(actual.detail)==canonicalAgentValue(intent.result()),label+" exact compact reference retained in Receipt")
        if(mode=="intent-cas-retained") { expect(reader.retained.getOrThrow().materialize({ _=>reader.reads++;Result<String>.Ok(raw) }).isError(),label+" proof expired after original Tx") }
        expect(reader.calls==1 && reader.reads==1,label+" one actual content consumption without replay")
    } else {
        expect(result.isError(),label+" invalid content or transaction cannot complete")
        expect(after[0].required(0)==old[0].required(0) && after[0].required(1)==old[0].required(1),label+" same transaction rolls back all document bytes")
        expect(httpContractRequire(store.loadDerivedOperationReceipt(child,run),label+" rejected completion has no Receipt").isNone(),label+" receipt not independently committed")
        if(mode=="intent-cas-participant-rollback"){expect(rollback.calls==1,label+" actual post-Receipt participant caused rollback")}
    }
    if(mode=="intent-cas-completed" && parentCall.callId.startsWith("history-parent-")){
        let resolution=httpContractRequire(runtime.resolveOperation(ItemId("result-"+parent.value),parent,
            CanonicalToolCallId(parentCall.callId),plan,OperationAttemptStage.Executing,
            Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(parentCall.callId,intent.result()))),
            "receipt-"+parent.value,36,expectedRunId:Some(run),expectedEpoch:Some(epoch)),label+" actual completed parent")
        expect(resolution.semanticCommit.isSome() && isStoreCommitted(resolution.semanticCommit.getOrThrow()),label+" parent round closes before next call")
    }
    expect(pool.usage()[0]==0 && pool.usage()[1]==0,label+" Store releases raw and DOM charge only after consumption")
}

// A new final-result fixture uses two simultaneous reservations for the compact
// child plan/Receipt and its nested document/pin proof. The existing scenarios
// above retain their one-transfer budget. Aggregate and raw bounds are unchanged.
// This proves Store authority/data pins only: it does not claim an OS blob,
// native worker, ProductArtifactStore, or Minimal execution result.
func documentPayloadFinalResult(database: SqliteDatabase, owner: OperationRootSource,
    fact: ContextReadFact, binding: AgentValue, parentCall: ToolCall, epoch: Int64,
    mode: String, label: String): Unit {
    let pool = LogicalJsonOwnerBudget(maximumTransfers: 2)
    let peak = AtomicInt64(0)
    let allocate = { bytes: Int64 =>
        let reservation = pool.acquire(max(1, bytes))
        let owners = pool.usage()[0]
        if (owners > peak.load()) { peak.store(owners) }
        reservation
    }
    let store = DurableOperationStore(database, documentPayloadAllocation: Some(allocate))
    let thread = ThreadId(httpIntentText(binding, "thread_id")); let run = fact.runId
    let lane = LaneId(httpIntentText(binding, "lane_id")); let namespace = httpIntentText(binding, "namespace")
    let row = fact.output().field("documents").getOrThrow().items[0]
    let raw = encodeAgentValue(objectValue([ValueField("message", textValue("replacement 雪"))]))
    let digest = modelPolicySha256Text(raw)
    let payload = documentPayloadFixtureValue(digest, raw.size)
    let value = objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),
        ValueField("binding", binding), ValueField("intent", objectValue([
            ValueField("id", textValue("document-1")), ValueField("key", textValue("todo")),
            ValueField("mode", textValue("compare_exchange")), ValueField("expected_revision", row.field("revision").getOrThrow()),
            ValueField("expected_payload", row.field("payload").getOrThrow()), ValueField("next_payload", payload)]))])
    let intent = parsePluginDocumentIntent(value).value().getOrThrow()
    // The held full result String is independently checked by the trusted
    // Store-only materializer; a descriptor is never substituted for bytes.
    let resultRaw = encodeAgentValue(intent.result())
    let resultPayload = documentPayloadFixtureValue(modelPolicySha256Text(resultRaw), resultRaw.size)
    let resultReference = parsePluginDocumentPayloadReference(resultPayload).value().getOrThrow()
    let input = objectValue([ValueField(CONTEXT_READ_INPUT_FIELD, objectValue([
        ValueField("schema", textValue("axyndra.context-read-input/v1")), ValueField("data", fact.output()),
        ValueField("facts", contextReadFactLinksValue([fact.link()]))]))])
    let args = objectValue([ValueField("input", input), ValueField("configuration", objectValue([])),
        ValueField("host_plan", objectValue([
            ValueField("version", textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)), ValueField("binding", binding),
            ValueField("intents", listValue([value.field("intent").getOrThrow()])), ValueField("result_payload", resultPayload),
            ValueField("result_codec", textValue("axyndra.agent-value-json/v1")), ValueField("is_error", boolValue(false))]))])
    database.transaction { transaction =>
        for (selected in [payload, resultPayload]) {
            let reference = parsePluginDocumentPayloadReference(selected).value().getOrThrow()
            let metadata = objectValue([ValueField("version", integerValue(1)),
                ValueField("ref", textValue("blob:sha256:" + reference.digest)), ValueField("sha256", textValue(reference.digest)),
                ValueField("bytes", integerValue(reference.bytes)), ValueField("content_type", textValue("text/plain; charset=utf-8"))])
            transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                [SqlParameter.Text(reference.digest), SqlParameter.Text("text/plain; charset=utf-8"),
                    SqlParameter.Int64Value(reference.bytes), SqlParameter.Text(encodeAgentValue(metadata) + "\n"),
                    SqlParameter.Text("blobs/" + reference.digest + ".txt")])
        }
        httpContractRequire(retainPreparedPluginDocumentPayload(transaction, fact.link(), value, allocate,
            { => Result<Unit>.Ok(()) }), label + " actual pending replacement pin")
        httpContractRequire(retainPreparedPluginDocumentResult(transaction, fact.link(), args, allocate, { =>
            expect(resultRaw.size == resultReference.bytes && modelPolicySha256Text(resultRaw) == resultReference.digest,
                label + " held complete result bytes match their retained reference")
            Result<Unit>.Ok(())
        }), label + " actual pending frozen-result pin")
    }
    let plan = NormalizedOperationPlan(parentCall.name, args,
        [Capability(CapabilityKind.ExtensionInvoke, resource: namespace)], OperationEffectClass.ExternalMutation,
        OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(args)), toolVersion: "workflow-v1",
        implementationFingerprint: httpIntentText(binding, "implementation_fingerprint"),
        schemaDigest: httpIntentText(binding, "schema_digest"), contextReadFacts: [fact.link()])
    let parent = match (owner) {
        case OperationRootSource.Direct(source) => source.operationId
        case OperationRootSource.Committed(source) => OperationId("operation-" + source.decisionId.value + "-" + source.scopedToolCallId.value)
        case _ => throw IllegalStateException("final result requires the original actual fixture source")
    }
    let prepared = match (owner) {
        case OperationRootSource.Direct(source) => store.prepareDirectOperation(source, plan)
        case OperationRootSource.Committed(source) => store.prepare(parent, run, source, plan)
        case _ => throw IllegalStateException("final result requires the original actual fixture source")
    }
    httpContractRequire(prepared, label + " actual frozen-result parent")
    httpContractRequire(store.markExecutingWithSource(Some(owner), parent, run, plan, 30, false), label + " actual parent execution")
    httpContractRequire(store.markExecutionHandoffWithSource(Some(owner), parent, run, thread, 31), label + " actual parent handoff")
    let guard = { => Result<Unit>.Ok(()) }
    httpContractRequire(store.verifyDocumentFrozenResultExecuting(parent, run, thread, epoch, owner, plan, guard),
        label + " actual before-CAS result proof")
    expect(store.verifyDocumentFrozenResultExecuting(parent, run, thread, epoch, owner, plan, guard,
        completedChildren: true).isError(), label + " a frozen result description cannot invent a completed child")
    let child = OperationId(parent.value + "-frozen-result-child"); let childPlan = documentServicePlan(true, value)
    httpContractRequire(store.prepareDerivedOperation(child, parent, run, owner,
        exactServiceRequestKey(parentCall.callId, childPlan), childPlan), label + " actual child admission")
    httpContractRequire(store.markExecutingWithSource(Some(owner), child, run, childPlan, 32, false), label + " actual child execution")
    httpContractRequire(store.markExecutionHandoffWithSource(Some(owner), child, run, thread, 33), label + " actual child handoff")
    let reader = DocumentPayloadCommitFixture(raw, "intent-cas-completed")
    let receipt = VNextOperationReceipt("receipt-" + child.value, child, OperationOutcome.Completed,
        intent.result(), objectValue([]), 34)
    httpContractRequire(store.settlePluginDocumentOperation(run, parent, receipt, guard, None, reader),
        label + " actual CAS and reserved Completed Receipt")
    let actual = httpContractRequire(store.loadDerivedOperationReceipt(child, run), label + " actual completed child").getOrThrow()
    expect(actual.receiptId == receipt.receiptId && actual.outcome == OperationOutcome.Completed &&
        canonicalAgentValue(actual.detail) == canonicalAgentValue(intent.result()), label + " exact reserved child result")
    expect(reader.calls == 1 && reader.reads == 1, label + " proof validation cannot replay content or CAS")
    peak.store(0)
    httpContractRequire(store.verifyDocumentFrozenResultExecuting(parent, run, thread, epoch, owner, plan, guard,
        completedChildren: true), label + " actual after-CAS final frozen-result proof")
    expect(peak.load() > 0 && peak.load() <= 2 && pool.usage()[0] == 0 && pool.usage()[1] == 0,
        label + " final proof stays within two live reservations and releases all owners")
    expect(store.verifyDocumentFrozenResultExecuting(parent, run, thread, epoch, owner, plan, guard).isError(),
        label + " completed CAS cannot reuse its stale before-CAS proof")
    expect(database.scalarInt("SELECT COUNT(*) FROM operations") == 3 &&
        database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 2,
        label + " final proof creates no new Operation or Receipt")
    if (mode != "intent-cas-result-completed") {
        let repository = SqlitePluginDocumentRepository(database)
        let completed = httpContractRequire(repository.read(thread, lane, namespace, "todo"), label + " actual completed document")
        expect(completed.revision == intent.expectedRevision + 1 && completed.encoded == raw,
            label + " mutation seam begins after the actual child CAS")
        if (mode == "intent-cas-result-same-revision-bytes") {
            // Explicit damaged-history seam keeps byte length and revision.
            // Only the complete byte hash can distinguish this document.
            let changed = encodeAgentValue(objectValue([ValueField("message", textValue("replacement 霜"))]))
            expect(changed.size == raw.size && modelPolicySha256Text(changed) != digest, label + " equal-size distinct full bytes")
            database.execute("UPDATE plugin_documents SET payload=? WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=? AND revision=?",
                [SqlParameter.Text(changed), SqlParameter.Text(thread.value), SqlParameter.Text(lane.value),
                    SqlParameter.Text(namespace), SqlParameter.Text("todo"), SqlParameter.Int64Value(completed.revision)])
        } else if (mode == "intent-cas-result-revision") {
            let advanced = httpContractRequire(repository.compareExchange(completed, parseUnifiedJson(raw),
                { _ => Result<Unit>.Ok(()) }), label + " real competing same-byte repository CAS")
            expect(advanced.revision == completed.revision + 1 && advanced.encoded == raw,
                label + " newer revision alone invalidates the original final result")
        } else if (mode == "intent-cas-result-missing-receipt") {
            database.execute("DELETE FROM operation_receipts WHERE id=? AND operation_id=?",
                [SqlParameter.Text(actual.receiptId), SqlParameter.Text(child.value)])
        } else if (mode == "intent-cas-result-tampered-receipt") {
            database.execute("UPDATE operation_receipts SET detail=? WHERE id=? AND operation_id=?",
                [SqlParameter.Text(encodeStoredValue(objectValue([ValueField("foreign", boolValue(true))]))),
                    SqlParameter.Text(actual.receiptId), SqlParameter.Text(child.value)])
        } else { throw IllegalStateException("unknown final frozen-result mutation fixture") }
        let before = httpContractRequire(repository.read(thread, lane, namespace, "todo"), label + " resulting row after fixture mutation")
        let receiptCount = database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
        let auditCount = database.scalarInt("SELECT COUNT(*) FROM audit_events")
        let failed = store.verifyDocumentFrozenResultExecuting(parent, run, thread, epoch, owner, plan, guard,
            completedChildren: true)
        expect(failed.isError() && failed.error().getOrThrow().code == "plugin.document_result_execution_stale",
            label + " final proof rejects the independent post-commit mutation")
        let after = httpContractRequire(repository.read(thread, lane, namespace, "todo"), label + " row after rejected final proof")
        expect(after.revision == before.revision && after.encoded == before.encoded &&
            database.scalarInt("SELECT COUNT(*) FROM operations") == 3 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == receiptCount &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events") == auditCount,
            label + " rejection neither replays the write nor creates authority or settlement facts")
    }
    expect(peak.load() <= 2 && pool.usage()[0] == 0 && pool.usage()[1] == 0 && reader.calls == 1 && reader.reads == 1,
        label + " every final proof releases its bounded owners without another materialization")
}

// Ten actual sequential parents in one Run prove that the eight-key bound is
// per parent. Every pin has its own completed ContextRead and both origins use
// their real canonical source, rather than cloned audit/Operation SQL rows.
func documentPayloadManyParents(committed:Bool):Unit {
    let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/history.sqlite")
    let label=if(committed){"Committed bounded history"}else{"Direct bounded history"}
    try {
        let thread=ThreadId("document-thread");let turn=SemanticTurnId("document-turn");let run=RunId("document-run")
        let sink=SqliteThreadCommitSink(database);let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
        let runtime=AgentThreadRuntime(coordinator,ContextProjector("document",StoreEstimator()),{=>10})
        let active=httpContractRequire(runtime.startTurn(turn,run,ItemId("history-user"),ThreadItemContent.UserMessage(textMessageParts("ten document calls")),
            recoveryLane(),InvocationContextProjection()),label+" actual Run")
        let store=DurableOperationStore(database);let repository=SqlitePluginDocumentRepository(database)
        let absent=httpContractRequire(repository.read(thread,LaneId("main"),"axyndra:workflow","todo"),label+" absent")
        let _=httpContractRequire(repository.compareExchange(absent,objectValue([]),{_=>Result<Unit>.Ok(())}),label+" original")
        for(index in 0..10){
            let id="history-parent-"+index.toString();let parentItem=ItemId(id);let parent=OperationId("operation-"+id)
            let parentCall=ToolCall(id,"plugin.axyndra:workflow.todo",objectValue([]))
            let owner:OperationRootSource
            if(committed){
                owner=OperationRootSource.Committed(commitDurableToolCall(database,coordinator,thread,turn,run,active.epoch,coordinator.snapshot().nextResultSequence,
                    parentItem,id,parentCall.name,parentCall.arguments,10))
            }else{
                expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread,turn,run,active.epoch,coordinator.snapshot().nextResultSequence,
                    ThreadItemDraft(parentItem,ThreadItemContent.ToolCall(CanonicalToolCallId(id),parentCall.name,parentCall.arguments),
                        ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parent)))))),label+" actual next parent")
                owner=OperationRootSource.Direct(httpContractRequire(runtime.attestDirectToolCall(parentItem,parent,run,active.epoch),label+" parent seal"))
            }
            let binding=documentServiceValue(false,active.epoch,"completed").field("binding").getOrThrow()
            binding.put("parent_call_id",textValue(id))
            let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA)),ValueField("binding",binding),
                ValueField("projection_digest",textValue(contextReadProjectionDigest(active.contextSnapshot))),ValueField("keys",listValue([textValue("todo")]))])
            let call=ToolCall(id+"-read",HOST_CONTEXT_READ_TOOL,request)
            let plan=NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL,request,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow")],
                OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(request)),
                toolVersion:HOST_CONTEXT_READ_IMPLEMENTATION,implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION)
            let admission=httpContractRequire(runtime.beginContextRead(call,"axyndra:workflow",httpIntentText(binding,"package_digest"),
                httpIntentText(binding,"configuration_digest"),id+"-read-request",run,active.epoch,contextReadProjectionDigest(active.contextSnapshot),parent:Some(owner)),label+" admission")
            let source=httpContractRequire(runtime.commitContextReadToolCall(admission,ItemId(id+"-read-call"),OperationId(id+"-read-op"),call,plan),label+" read call")
            httpContractRequire(store.prepareDirectOperation(source,plan),label+" prepare read")
            httpContractRequire(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),source.operationId,run,plan,11,false),label+" read execution")
            httpContractRequire(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),source.operationId,run,thread,12),label+" read handoff")
            let observed=httpContractRequire(store.readPluginDocuments(source,plan,{=>Result<Unit>.Ok(())},None,Some(DocumentPayloadFixture("completed"))),label+" real reference")
            let resolved=httpContractRequire(runtime.resolveOperation(ItemId("result-"+source.operationId.value),source.operationId,CanonicalToolCallId(call.callId),plan,
                OperationAttemptStage.Executing,Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId,observed))),
                "receipt-"+source.operationId.value,13,expectedRunId:Some(run),expectedEpoch:Some(active.epoch)),label+" completed read")
            expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()),label+" read committed")
            let fact=httpContractRequire(store.loadContextReadFact(source.operationId,run),label+" actual fact")
            documentPayloadFinalWrite(database,runtime,owner,fact,binding,parentCall,active.epoch,"intent-cas-completed",label)
        }
        expect(database.scalarInt("SELECT COUNT(DISTINCT operation_id) FROM audit_events WHERE kind='plugin_document_payload_prepared'")==10,label+" ten independent parents")
        expect(database.scalarInt("SELECT COUNT(*) FROM operations")==30,label+" ten reads, actual parents and derived CAS children")
        expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts")==30,label+" each source settles without replay")
        expect(database.scalarInt("SELECT COUNT(*) FROM audit_events pin JOIN operations parent ON parent.id=pin.operation_id " +
            "WHERE pin.kind='plugin_document_payload_prepared' AND EXISTS(SELECT 1 FROM audit_events handoff WHERE handoff.operation_id=parent.id AND handoff.kind='operation_execution_handoff')")==10,
            label+" preparation pin stays distinct from later execution evidence")
    }finally{database.close();remove(root,recursive:true)}
}
