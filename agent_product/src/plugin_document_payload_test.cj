package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import std.sync.*
import std.convert.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual Product artifact owner and canonical SQLite Runtime source, exercised
// below the public Tool/provider hydration adapter. These tests do not claim
// the still-unwired native 8 MiB document round trip is complete.
class DocumentPayloadProductRead {
    let runtime: AgentThreadRuntime
    let source: DirectToolCallRef
    let plan: NormalizedOperationPlan
    let call: ToolCall
    let original: PluginDocumentSnapshot
    init(f: PluginDocumentResetFixture, content: AgentValue, keys!: Array<String> = ["todo"],
        cancellation!: ?CancellationToken = None) {
        let thread = ThreadId("payload-thread"); let run = RunId("payload-run"); let turn = SemanticTurnId("payload-turn")
        let sink = SqliteThreadCommitSink(f.database)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let actualRuntime = AgentThreadRuntime(coordinator, ContextProjector("payload-context", ConservativeThreadTokenEstimator()), { => 20 })
        let lane = ModelLane(ModelLaneRole.Main, "fixture", "fixture-model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("payload-tools", []), "system-v1")
        let active = lifecycleTestRequire(actualRuntime.startTurn(turn, run, ItemId("payload-user"),
            ThreadItemContent.UserMessage(textMessageParts("read the complete document")), lane, InvocationContextProjection(), parentCancellation: cancellation))
        let parent = OperationId("payload-parent"); let parentItem = ItemId("payload-parent-call")
        let name = "plugin.axyndra:workflow.todo"
        let committed = actualRuntime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
            ThreadItemDraft(parentItem, ThreadItemContent.ToolCall(CanonicalToolCallId("payload-parent-call"), name, objectValue([])),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))
        @Expect(match (committed) { case SemanticCommitDecision.Committed(_, _) => true; case _ => false })
        let parentSource = lifecycleTestRequire(actualRuntime.attestDirectToolCall(parentItem, parent, run, active.epoch))
        let digest = modelPolicySha256Text("payload-binding")
        let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
            ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("1")),
            ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue(thread.value)),
            ValueField("lane_id", textValue("main")), ValueField("run_id", textValue(run.value)), ValueField("epoch", integerValue(active.epoch)),
            ValueField("parent_call_id", textValue("payload-parent-call")), ValueField("contribution", textValue(name)),
            ValueField("implementation_fingerprint", textValue("actual-payload-fixture")), ValueField("schema_digest", textValue(digest))])
        let request = objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA)), ValueField("binding", binding),
            ValueField("projection_digest", textValue(contextReadProjectionDigest(active.contextSnapshot))),
            ValueField("keys", listValue(keys.map { key => textValue(key) }))])
        let actualCall = ToolCall("payload-read-call", HOST_CONTEXT_READ_TOOL, request)
        let actualPlan = NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, request,
            [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow")], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(request)),
            toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION, implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
        let admission = lifecycleTestRequire(actualRuntime.beginContextRead(actualCall, "axyndra:workflow", "sha256:" + digest,
            digest, "payload-read-request", run, active.epoch, contextReadProjectionDigest(active.contextSnapshot),
            parent: Some(OperationRootSource.Direct(parentSource))))
        let actualSource = lifecycleTestRequire(actualRuntime.commitContextReadToolCall(admission,
            ItemId("payload-read-item"), OperationId("payload-read"), actualCall, actualPlan))
        let store = productOperationStore(f.database)
        lifecycleTestRequire(store.prepareDirectOperation(actualSource, actualPlan))
        lifecycleTestRequire(store.markExecutingWithSource(Some(OperationRootSource.Direct(actualSource)), actualSource.operationId, run, actualPlan, 21, false))
        lifecycleTestRequire(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(actualSource)), actualSource.operationId, run, thread, 22))
        let prior = lifecycleTestRequire(f.documents.read(thread, LaneId("main"), "axyndra:workflow", "todo"))
        let document = lifecycleTestRequire(f.documents.compareExchange(prior, content, { _ => Result<Unit>.Ok(()) }))
        for (key in keys where key != "todo") {
            let previous = lifecycleTestRequire(f.documents.read(thread, LaneId("main"), "axyndra:workflow", key))
            let _ = lifecycleTestRequire(f.documents.compareExchange(previous, content, { _ => Result<Unit>.Ok(()) }))
        }
        this.runtime = actualRuntime; this.source = actualSource; this.plan = actualPlan; this.call = actualCall; this.original = document
    }
    func commit(value: AgentValue): Unit {
        let result = lifecycleTestRequire(runtime.resolveOperation(ItemId("result-" + source.operationId.value), source.operationId,
            CanonicalToolCallId(call.callId), plan, OperationAttemptStage.Executing,
            Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, value))),
            "receipt-payload-read", 23, expectedRunId: Some(source.runId), expectedEpoch: Some(source.epoch)))
        @Expect(result.semanticCommit.isSome())
        @Expect(match (result.semanticCommit.getOrThrow()) { case SemanticCommitDecision.Committed(_, _) => true; case _ => false })
    }
}

@Test
class PluginDocumentPayloadProductTests {
    @TestCase
    func artifactRootReplacedBeforePreparationCannotPublishAnExternalFileOrPin(): Unit {
        productDocumentPayloadReplacementScenario("root-before-pin")
    }
    @TestCase
    func artifactRootReplacedAfterHandoffCannotEnterTheDocumentCommitTransaction(): Unit {
        productDocumentPayloadReplacementScenario("root-before-commit")
    }
    @TestCase
    func actualEightMiBReplacementKeepsCanonicalReceiptAndHistoricalGcReference(): Unit {
        productDocumentPayloadReplacementScenario("complete")
    }
    @TestCase
    func replacementFileChangeAndActualCallerCancelNeverCommitPartialDocument(): Unit {
        for(mode in ["changed", "cancelled"]) { productDocumentPayloadReplacementScenario(mode) }
    }
    @TestCase
    func malformedReplacementHasNoPreparedParentAndNoMetadataPin(): Unit {
        productDocumentPayloadReplacementScenario("invalid")
    }
    @TestCase
    func eightMaximumDocumentsReleaseEachRawLeaseBeforeSelectingTheNextKey(): Unit {
        let f = PluginDocumentResetFixture()
        // 32 MiB occupied in the same aggregate allows one 64 MiB raw row,
        // but never two simultaneous maximum-size row reservations.
        let pressure = reserveNativeDocumentPayload(4194304)
        try {
            let actual = DocumentPayloadProductRead(f, textValue(String.fromUtf8(Array<Byte>(8388606, repeat: b'x'))),
                keys: ["todo", "one", "two", "three", "four", "five", "six", "seven"])
            let artifacts = ProductArtifactStore(f.root + "/state", database: Some(f.database))
            let reader = artifacts.documentPayloadReader(productOperationStore(f.database), actual.source, actual.plan,
                { => Result<Unit>.Ok(()) }, None)
            let value = try { lifecycleTestRequire(reader.read()) } finally { lifecycleTestRequire(reader.close()) }
            @Expect(value.field("documents").getOrThrow().items.size, 8)
            for (row in value.field("documents").getOrThrow().items) {
                let payload = parsePluginDocumentPayloadReference(row.field("payload").getOrThrow()).value().getOrThrow()
                @Expect(payload.bytes, 8388608); @Expect(payload.digest, modelPolicySha256Text(actual.original.encoded))
            }
            actual.commit(value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_observed'"), 8)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 1)
            let probe = reserveNativeDocumentPayload(8388608); probe.close()
            @Expect(reader.read().isError())
        } finally { pressure.close(); f.close() }
    }
    @TestCase
    func actualCallerCancellationDuringCopyRollsBackPinsAndReleasesTheWriter(): Unit {
        let f = PluginDocumentResetFixture(); let cancel = CancellationSource(); let calls = AtomicInt64(0)
        try {
            let actual = DocumentPayloadProductRead(f, textValue(String.fromUtf8(Array<Byte>(1048574, repeat: b'x'))),
                cancellation: Some(cancel.token))
            let token = lifecycleTestRequire(actual.runtime.childCancellationToken())
            let artifacts = ProductArtifactStore(f.root + "/state", database: Some(f.database))
            let reader = artifacts.documentPayloadReader(productOperationStore(f.database), actual.source, actual.plan,
                { => if (calls.fetchAdd(1) == 8) { let _ = cancel.cancel() }; token.check() }, None)
            try { @Expect(reader.read().isError()) } finally { lifecycleTestRequire(reader.close()) }
            @Expect(token.isCancelled()); @Expect(calls.load() >= 9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_observed'"), 0)
            @Expect(!exists(Path(f.root + "/state/blobs/" + modelPolicySha256Text(actual.original.encoded) + ".txt")))
            let first = reserveNativeDocumentPayload(4194304)
            try { let second = reserveNativeDocumentPayload(8388608); second.close() } finally { first.close() }
            @Expect(reader.read().isError())
        } finally { f.close() }
    }
    @TestCase
    func fullEightMiBDocumentBecomesCompactCanonicalFactAndRetainedExactBlob(): Unit {
        let f = PluginDocumentResetFixture()
        try {
            let actual = DocumentPayloadProductRead(f, textValue(String.fromUtf8(Array<Byte>(8388606, repeat: b'x'))))
            @Expect(actual.original.encoded.size, 8388608)
            let artifacts = ProductArtifactStore(f.root + "/state", database: Some(f.database))
            let reader = artifacts.documentPayloadReader(productOperationStore(f.database), actual.source, actual.plan,
                { => Result<Unit>.Ok(()) }, None)
            let value = try { lifecycleTestRequire(reader.read()) } finally { lifecycleTestRequire(reader.close()) }
            @Expect(reader.read().isError())
            let payload = parsePluginDocumentPayloadReference(value.field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
            let path = f.root + "/state/blobs/" + payload.digest + ".txt"
            @Expect(String.fromUtf8(File.readFrom(path)), actual.original.encoded)
            @Expect(payload.bytes, 8388608); @Expect(payload.digest, modelPolicySha256Text(actual.original.encoded))
            @Expect(stringifyUnifiedJson(value).size < 2048)
            actual.commit(value)
            let cleared = lifecycleTestRequire(f.documents.compareExchange(actual.original, nullValue(), { _ => Result<Unit>.Ok(()) }))
            @Expect(cleared.revision, actual.original.revision + 1)
            let candidate = GcBlobCandidate(payload.digest); candidate.paths.add(path)
            let deleted = f.database.transaction { transaction => deleteUnreferencedGcBlob(transaction, candidate) }
            @Expect(deleted.retained && deleted.deleted == 0 && deleted.errors.isEmpty())
            let reopened = SqliteDatabase(f.root + "/state/state.db")
            try {
                let fact = lifecycleTestRequire(productOperationStore(reopened).loadContextReadFact(actual.source.operationId, actual.source.runId))
                @Expect(fact.outputDigest, modelPolicySha256Text(stringifyUnifiedJson(value)))
                @Expect(containsGcString(collectRequiredBlobReferences(reopened).references, payload.digest))
            } finally { reopened.close() }
        } finally { f.close() }
    }
    @TestCase
    func existingBlobWithWrongMimeCannotBecomeAValidDocumentReadReference(): Unit {
        let f = PluginDocumentResetFixture()
        try {
            let actual = DocumentPayloadProductRead(f, textValue("same digest is not permission to reinterpret MIME 雪"))
            let artifacts = ProductArtifactStore(f.root + "/state", database: Some(f.database))
            let old = lifecycleTestRequire(artifacts.persistText(actual.original.encoded))
            f.database.execute("UPDATE artifacts SET mime='application/json' WHERE hash=?", [SqlParameter.Text(old.sha256)])
            let reader = artifacts.documentPayloadReader(productOperationStore(f.database), actual.source, actual.plan,
                { => Result<Unit>.Ok(()) }, None)
            try { @Expect(reader.read().isError()) } finally { lifecycleTestRequire(reader.close()) }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_observed'"), 0)
            @Expect(f.database.query("SELECT mime FROM artifacts WHERE hash=?", [SqlParameter.Text(old.sha256)])[0].required(0), "application/json")
            @Expect(String.fromUtf8(File.readFrom(f.root + "/state/blobs/" + old.sha256 + ".txt")), actual.original.encoded)
        } finally { f.close() }
    }
    @TestCase
    func failedCanonicalPinRollsBackMetadataAndLeavesOnlyCollectableUnpublishedData(): Unit {
        let f = PluginDocumentResetFixture()
        try {
            let actual = DocumentPayloadProductRead(f, textValue("rollback contains no durable document reference"))
            f.database.execute("CREATE TRIGGER fixture_payload_pin BEFORE INSERT ON audit_events " +
                "WHEN NEW.kind='plugin_document_payload_observed' BEGIN SELECT RAISE(ABORT,'reject payload pin'); END")
            let artifacts = ProductArtifactStore(f.root + "/state", database: Some(f.database))
            let reader = artifacts.documentPayloadReader(productOperationStore(f.database), actual.source, actual.plan,
                { => Result<Unit>.Ok(()) }, None)
            try { @Expect(reader.read().isError()) } finally { lifecycleTestRequire(reader.close()) }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_observed'"), 0)
            @Expect(lifecycleTestRequire(f.documents.read(actual.source.threadId, LaneId("main"), "axyndra:workflow", "todo")).encoded,
                actual.original.encoded)
            let digest = modelPolicySha256Text(actual.original.encoded)
            let path = f.root + "/state/blobs/" + digest + ".txt"
            @Expect(exists(Path(path)))
            let candidate = GcBlobCandidate(digest); candidate.paths.add(path)
            let deleted = f.database.transaction { transaction => deleteUnreferencedGcBlob(transaction, candidate) }
            @Expect(!deleted.retained && deleted.deleted == 1 && deleted.errors.isEmpty())
            @Expect(!exists(Path(path)))
        } finally { f.close() }
    }
}


func productDocumentPayloadReplacementScenario(mode: String): Unit {
    let f=PluginDocumentResetFixture();let cancellation=CancellationSource()
    let retained=ArrayList<ProductServiceArtifactWriter>()
    let rootLinked=AtomicBool(false)
    let swapRoot={=>
        // The real files remain intact behind the renamed directory. A leaf
        // metadata/hash-only check would accept them through this root link.
        rename(f.root+"/state/blobs",to:f.root+"/state/original-blobs")
        SymbolicLink.create(f.root+"/state/blobs",to:f.root+"/state/original-blobs")
        rootLinked.store(true)
    }
    let restoreRoot={=>if(rootLinked.load()){
        remove(f.root+"/state/blobs")
        rename(f.root+"/state/original-blobs",to:f.root+"/state/blobs")
        rootLinked.store(false)
    }}
    try {
        let original=DocumentPayloadProductRead(f,textValue("original canonical document"),cancellation:Some(cancellation.token))
        let store=productOperationStore(f.database)
        let artifacts=ProductArtifactStore(f.root+"/state",database:Some(f.database))
        let read=artifacts.documentPayloadReader(store,original.source,original.plan,{=>Result<Unit>.Ok(())},None)
        let observed=try{lifecycleTestRequire(read.read())}finally{lifecycleTestRequire(read.close())}
        original.commit(observed)
        let fact=lifecycleTestRequire(store.loadContextReadFact(original.source.operationId,original.source.runId))
        let row=observed.field("documents").getOrThrow().items[0]
        let raw=if(mode=="invalid"){ "{broken" }else{encodeAgentValue(textValue(String.fromUtf8(Array<Byte>(8388606,repeat:b'w'))))}
        let digest=modelPolicySha256Text(raw)
        let writer=lifecycleTestRequire(artifacts.openServiceArtifactWriter());retained.add(writer)
        lifecycleTestRequire(writer.open())
        let bytes=raw.toArray();var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+16384);lifecycleTestRequire(writer.appendBytes(offset,bytes[offset..end],8388608));offset=end}
        lifecycleTestRequire(writer.finish(bytes.size,digest))
        let payload=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
            ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])
        let binding=original.plan.canonicalArguments.field("binding").getOrThrow()
        let value=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),ValueField("binding",binding),
            ValueField("intent",objectValue([ValueField("id",textValue("document-1")),ValueField("key",textValue("todo")),ValueField("mode",textValue("compare_exchange")),
                ValueField("expected_revision",row.field("revision").getOrThrow()),ValueField("expected_payload",row.field("payload").getOrThrow()),ValueField("next_payload",payload)]))])
        if(mode=="root-before-pin"){swapRoot()}
        let pin=artifacts.retainDocumentPayloadReplacement(fact.link(),value,writer,{=>cancellation.token.check()})
        if(mode=="root-before-pin"){
            @Expect(pin.isError());@Expect(pin.error().getOrThrow().code,"artifact.root_unsafe")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_prepared'"),0)
            @Expect(f.database.query("SELECT hash FROM artifacts WHERE hash=?",[SqlParameter.Text(digest)]).isEmpty())
            @Expect(!exists(Path(f.root+"/state/original-blobs/"+digest+".txt")))
            restoreRoot();lifecycleTestRequire(writer.close());return
        }
        if(mode=="invalid") {
            @Expect(pin.isError());@Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_prepared'"),0)
            @Expect(f.database.query("SELECT hash FROM artifacts WHERE hash=?",[SqlParameter.Text(digest)]).isEmpty())
            lifecycleTestRequire(writer.close())
            let orphan=GcBlobCandidate(digest);orphan.paths.add(f.root+"/state/blobs/"+digest+".txt")
            let removed=f.database.transaction{tx=>deleteUnreferencedGcBlob(tx,orphan)}
            @Expect(removed.deleted,1);return
        }
        lifecycleTestRequire(pin);lifecycleTestRequire(writer.close())
        let parent=OperationId("payload-parent");let run=original.source.runId;let thread=original.source.threadId
        let source=lifecycleTestRequire(original.runtime.attestDirectToolCall(ItemId("payload-parent-call"),parent,run,original.source.epoch))
        let origin=OperationRootSource.Direct(source)
        let args=objectValue([ValueField("input",objectValue([])),ValueField("configuration",objectValue([])),ValueField("host_plan",objectValue([
            ValueField("version",textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)),ValueField("binding",binding),
            ValueField("intents",listValue([value.field("intent").getOrThrow()]))]))])
        let parentPlan=NormalizedOperationPlan("plugin.axyndra:workflow.todo",args,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow")],
            OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(args)),
            implementationFingerprint:"actual-payload-fixture",schemaDigest:httpIntentText(binding,"schema_digest"),contextReadFacts:[fact.link()])
        lifecycleTestRequire(store.prepareDirectOperation(source,parentPlan))
        lifecycleTestRequire(store.markExecutingWithSource(Some(origin),parent,run,parentPlan,30,false))
        lifecycleTestRequire(store.markExecutionHandoffWithSource(Some(origin),parent,run,thread,31))
        let child=OperationId("payload-child")
        let childPlan=NormalizedOperationPlan(HOST_PLUGIN_DOCUMENT_TOOL,value,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow")],
            OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(value)),
            toolVersion:HOST_PLUGIN_DOCUMENT_FINGERPRINT,implementationFingerprint:HOST_PLUGIN_DOCUMENT_FINGERPRINT,schemaDigest:httpIntentText(binding,"schema_digest"))
        lifecycleTestRequire(store.prepareDerivedOperation(child,parent,run,origin,"document-service:payload-parent-call:document-1",childPlan))
        lifecycleTestRequire(store.markExecutingWithSource(Some(origin),child,run,childPlan,32,false))
        lifecycleTestRequire(store.markExecutionHandoffWithSource(Some(origin),child,run,thread,33))
        if(mode=="changed"){File.writeTo(f.root+"/state/blobs/"+digest+".txt",("x"+raw[1..]).toArray())}
        let guardCalls=AtomicInt64(0)
        let guard={=>if(mode=="cancelled" && guardCalls.fetchAdd(1)==4){let _=cancellation.cancel()};cancellation.token.check()}
        let reader=artifacts.documentPayloadCommitReader(run,parent,child,guard)
        let intent=parsePluginDocumentIntent(value).value().getOrThrow()
        let receipt=VNextOperationReceipt("receipt-payload-child",child,OperationOutcome.Completed,intent.result(),objectValue([]),34)
        let pressure=reserveNativeDocumentPayload(4194304)
        let entered=AtomicInt64(0)
        if(mode=="root-before-commit"){swapRoot()}
        let result=try{reader.runCommit({committer=>let _=entered.fetchAdd(1);store.settlePluginDocumentOperation(run,parent,receipt,guard,None,committer)})}
            finally{lifecycleTestRequire(reader.close());pressure.close()}
        if(mode=="root-before-commit"){
            @Expect(result.isError());@Expect(result.error().getOrThrow().code,"artifact.root_unsafe")
            @Expect(entered.load(),0);restoreRoot()
        }
        let latest=lifecycleTestRequire(f.documents.read(thread,LaneId("main"),"axyndra:workflow","todo"))
        if(mode=="complete") {
            lifecycleTestRequire(result);@Expect(latest.encoded,raw);@Expect(latest.revision,original.original.revision+1)
            let actual=lifecycleTestRequire(store.loadDerivedOperationReceipt(child,run)).getOrThrow()
            @Expect(canonicalAgentValue(actual.detail),canonicalAgentValue(intent.result()))
            @Expect(encodeStoredValue(actual.detail).size<2048)
            let next=lifecycleTestRequire(f.documents.compareExchange(latest,nullValue(),{_=>Result<Unit>.Ok(())}))
            @Expect(next.revision,latest.revision+1)
            let old=GcBlobCandidate(digest);old.paths.add(f.root+"/state/blobs/"+digest+".txt")
            let collected=f.database.transaction{tx=>deleteUnreferencedGcBlob(tx,old)}
            @Expect(collected.retained && collected.deleted==0)
            @Expect(String.fromUtf8(File.readFrom(f.root+"/state/blobs/"+digest+".txt")),raw)
        } else {
            @Expect(result.isError());@Expect(latest.encoded,original.original.encoded);@Expect(latest.revision,original.original.revision)
            @Expect(lifecycleTestRequire(store.loadDerivedOperationReceipt(child,run)).isNone())
            lifecycleTestRequire(store.settleDerivedOperation(run,parent,VNextOperationReceipt(receipt.receiptId,child,
                OperationOutcome.Unknown,objectValue([]),objectValue([]),35)))
            if(mode=="cancelled"){@Expect(cancellation.token.isCancelled())}
        }
        @Expect(reader.collect());@Expect(reader.runCommit({_=>Result<Unit>.Ok(())}).isError())
        let probe=reserveNativeDocumentPayload(8388608);probe.close()
    } finally {restoreRoot();for(writer in retained){let _=writer.close()};f.close()}
}
