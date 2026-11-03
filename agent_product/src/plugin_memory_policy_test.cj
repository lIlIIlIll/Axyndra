package agent_product

import agent_plugin_registry

import tool_runtime.*

import agent_core.*
import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class MemoryPolicyFixture {
    let root = pluginContractTemp("installed-memory-policy")
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: ?ProductPluginRecord
    var sequence: Int64 = 0
    private let windowed:Bool
    init(install!: Bool = true,windowed!:Bool=false,approval!:ApprovalMode=ApprovalMode.Yolo,pluginPackage!:?String=None) {
        this.windowed=windowed
        let opened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true, approvalMode: approval,
            fixtureDerivedSettlementFailureObserver: Some({ operation, run, parent, message =>
                println("memory actual derived settlement exception: " + stringifyUnifiedJson(objectValue([
                    ValueField("operation_id", textValue(operation)), ValueField("run_id", textValue(run)),
                    ValueField("parent_operation_id", textValue(parent)),
                    ValueField("error_code", textValue("operation.derived_settle_failed")),
                    ValueField("exception_message", textValue(message))]))) }))))
        try {
            let selected: ?ProductPluginRecord = if (install) {
                let value = match (opened.importLocalPlugin(pluginPackage ?? getVariable("AXYNDRA_MEMORY_PLUGIN_PACKAGE").getOrThrow())) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
                let directory=root+"/settings/plugins"
                if(!exists(Path(directory))){Directory.create(directory,recursive:true)}
                let tools=ArrayList<AgentValue>()
                for(name in ["retain","recall","reflect","memory_edit","learn","manage_skill","memory_context"]){
                    tools.add(objectValue([ValueField("name",textValue(name)),ValueField("documents",listValue([
                        objectValue([ValueField("key",textValue("journal")),ValueField("read",boolValue(true)),
                            ValueField("write",boolValue(true))])])),ValueField("preparation_provider",textValue(if(windowed){"prepare_window_document"}else{"prepare_document"})),
                        ValueField("payload_references",boolValue(true)),ValueField("effect_from_intents",boolValue(true)),
                        ValueField("tool_payload_limits",OrdinaryToolPayloadLimits(name).value())]))
                    if(windowed){tools[tools.size-1].put("read_windows",boolValue(true))}}
                File.writeTo(directory+"/documents.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
                    ValueField("plugins",listValue([objectValue([ValueField("namespace",textValue(productRegistryCopyText83(value.descriptor.copyText(PluginDescriptorText.Namespace)))),
                        ValueField("package_digest",textValue(productRegistryCopyText83(value.descriptor.copyText(PluginDescriptorText.ContentDigest)))),ValueField("tools",listValue(tools.toArray())),
                        ValueField("backends",listValue([objectValue([ValueField("key",textValue("journal")),
                            ValueField("layout",textValue("opaque-fact-events-v3"))])]))])]))])).toArray())
                @Expect(opened.setPluginEnabled(productRegistryCopyText83(value.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
                Some(value)
            } else { None }
            this.product = opened; this.record = selected
            this.database = SqliteDatabase(root + "/state/state.db")
            if (selected.isSome()) { selection(productRegistryCopyText83(selected.getOrThrow().descriptor.copyText(PluginDescriptorText.ContentDigest))) }
        } catch (error: Exception) { let _ = opened.close(); remove(root, recursive: true); throw error }
    }
    func selection(digest: String): Unit {
        let directory = root + "/settings/plugins"
        if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
        File.writeTo(directory + "/policies.json", stringifyUnifiedJson(objectValue([ValueField("version", integerValue(1)),
            ValueField("bindings", objectValue([ValueField("memory", objectValue([ValueField("namespace", textValue(productRegistryCopyText83(record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("provider", textValue("memory")), ValueField("package_digest", textValue(digest))]))]))])).toArray())
    }
    func initialContextProfile():Unit{
        let selected=record.getOrThrow();let directory=root+"/settings/plugins"
        File.writeTo(directory+"/document-context.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
            ValueField("providers",listValue([objectValue([ValueField("namespace",textValue(productRegistryCopyText83(selected.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest",textValue(productRegistryCopyText83(selected.descriptor.copyText(PluginDescriptorText.ContentDigest)))),ValueField("provider",textValue("memory_context")),
                ValueField("keys",listValue([textValue("journal")]))])]))])).toArray())
        File.writeTo(directory+"/context.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(5)),
            ValueField("namespace",textValue(productRegistryCopyText83(selected.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(selected.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
            ValueField("provider",textValue("memory_context")),ValueField("resources",listValue([textValue("journal")])),
            ValueField("query",objectValue([ValueField("schema",textValue("axyndra.memory-context-query/v1")),
                ValueField("max_bytes",integerValue(16384))])),ValueField("prompt_field",textValue("query"))])).toArray())
    }
    func legacyPolicy(session:SessionId,cancellation!:CancellationToken=CancellationSource().token):Result<ProductMemoryPolicy>{
        legacyInstalledMemoryPolicy(product.vnext.javascriptPlugins,root+"/settings",session,cancellation:cancellation)
    }
    func call(name: String, arguments: AgentValue, thread!: String = "memory-direct"): ToolResult {
        sequence += 1
        managedCompleted(product.vnext.executeCanonicalTool(SessionId(thread), productCapabilities(),
            ToolCall("memory-call-" + sequence.toString(), "plugin."+productRegistryCopyText83(record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+"."+name, arguments),
            budget:ExecutionBudget(maxToolCalls:if(windowed){10}else{3},maxConcurrentTools:1)))
    }
    // A fixture is the terminal direct-call consumer. Return only its consumed
    // Boolean after the actual payload lease has acknowledged release.
    func callIsError(name:String,arguments:AgentValue,thread!:String="memory-direct"):Bool{
        let result=call(name,arguments,thread:thread)
        try{result.isError}finally{result.releasePayload()}
    }
    // Read only the current synchronous fixture call's already-durable facts.
    // SQL returns a bounded header, never a parameter/history dump. A missing
    // or oversized identity is reported as unresolved, not assumed causal.
    func diagnoseRetainReceipt():Unit{
        try{
            let expected="memory-call-"+sequence.toString()
            let parents=database.query("SELECT "+
                "CASE WHEN length(CAST(o.id AS BLOB))<=1024 THEN o.id ELSE NULL END,"+
                "CASE WHEN length(CAST(o.run_id AS BLOB))<=1024 THEN o.run_id ELSE NULL END,"+
                "CASE WHEN length(CAST(o.state AS BLOB))<=64 THEN o.state ELSE '[oversized state]' END,"+
                "length(CAST(o.id AS BLOB)),length(CAST(o.run_id AS BLOB)),length(CAST(i.payload AS BLOB)),"+
                "CASE WHEN length(CAST(i.payload AS BLOB))<=65536 THEN i.payload ELSE NULL END "+
                "FROM operations o JOIN items i ON i.id=o.tool_call_item_id "+
                "JOIN runs run ON run.id=o.run_id WHERE run.thread_id=? AND i.thread_id=run.thread_id "+
                "AND i.kind='tool_call' AND instr(i.payload,?)>0 "+
                "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id) "+
                "ORDER BY o.rowid DESC LIMIT 1",[SqlParameter.Text("memory-direct"),SqlParameter.Text(encodeStoredValue(textValue(expected)))])
            if(parents.size!=1){println("memory retain receipt diagnostic-unresolved: no current parent for "+expected);return}
            let parent=parents[0]
            if(parent[0].isNone() || parent[1].isNone() || parent[6].isNone()){
                println("memory retain receipt diagnostic-unresolved: oversized parent identity/header; expected="+expected+
                    " operation_bytes="+parent.required(3)+" run_bytes="+parent.required(4)+" call_payload_bytes="+parent.required(5));return}
            let matched=match(decodeStoredThreadContent(parent.required(6))){
                case ThreadItemContent.ToolCall(id,name,_)=>id.value==expected &&
                    name=="plugin."+productRegistryCopyText83(record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+".retain"
                case _=>false}
            if(!matched){println("memory retain receipt diagnostic-unresolved: latest parent does not match "+expected);return}
            println("memory retain correlated actual parent: "+stringifyUnifiedJson(objectValue([
                ValueField("call_id",textValue(expected)),ValueField("operation_id",textValue(parent.required(0))),
                ValueField("run_id",textValue(parent.required(1))),ValueField("state",textValue(parent.required(2)))])))
            var after:Int64=0
            while(true){
                let children=database.query("SELECT a.call_sequence,"+
                    "CASE WHEN length(CAST(o.id AS BLOB))<=1024 THEN o.id ELSE '[oversized operation_id]' END,"+
                    "CASE WHEN length(CAST(o.state AS BLOB))<=64 THEN o.state ELSE '[oversized state]' END,"+
                    "CASE WHEN length(CAST(a.child_call_id AS BLOB))<=1024 THEN a.child_call_id ELSE '[oversized child_call_id]' END,"+
                    "CASE WHEN length(CAST(a.request_key AS BLOB))<=1024 THEN a.request_key ELSE '[oversized request_key]' END,"+
                    "CASE WHEN receipt.id IS NULL THEN NULL WHEN length(CAST(receipt.id AS BLOB))<=1024 THEN receipt.id ELSE '[oversized receipt_id]' END,"+
                    "CASE WHEN receipt.outcome IS NULL THEN NULL WHEN length(CAST(receipt.outcome AS BLOB))<=64 THEN receipt.outcome ELSE '[oversized outcome]' END,"+
                    "length(CAST(receipt.detail AS BLOB)),"+
                    "CASE WHEN length(CAST(receipt.detail AS BLOB))<=65536 THEN receipt.detail ELSE NULL END,"+
                    "length(CAST(o.id AS BLOB)),length(CAST(a.child_call_id AS BLOB)),length(CAST(a.request_key AS BLOB)),"+
                    "length(CAST(receipt.id AS BLOB)),length(CAST(o.state AS BLOB)),length(CAST(receipt.outcome AS BLOB)) "+
                    "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                    "JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.run_id=o.run_id "+
                    "LEFT JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=effect.reserved_receipt_id "+
                    "WHERE a.parent_operation_id=? AND o.run_id=? AND a.call_sequence>? ORDER BY a.call_sequence LIMIT 1",
                    [SqlParameter.Text(parent.required(0)),SqlParameter.Text(parent.required(1)),SqlParameter.Int64Value(after)])
                if(children.size==0){break}
                let child=children[0];after=Int64.parse(child.required(0))
                let code=if(child[8].isNone()){
                    if(child[7].isNone()){"[no reserved durable receipt]"}else{"[oversized detail]"}
                }else{
                    let detail=decodeStoredValue(child.required(8))
                    match(detail.field("error_code")){
                        case Some(value)=>if(value.unifiedKind==ValueKind.Text){
                            if(value.text.toArray().size<=1024){value.text}else{"[oversized error_code]"}
                        }else{"[error_code is not text]"}
                        case None=>"[no error_code]"}}
                println("memory retain correlated actual child: "+stringifyUnifiedJson(objectValue([
                    ValueField("parent_operation_id",textValue(parent.required(0))),ValueField("run_id",textValue(parent.required(1))),
                    ValueField("call_sequence",textValue(child.required(0))),ValueField("operation_id",textValue(child.required(1))),
                    ValueField("state",textValue(child.required(2))),ValueField("child_call_id",textValue(child.required(3))),
                    ValueField("request_key",textValue(child.required(4))),ValueField("receipt_id",textValue(child[5] ?? "[none]")),
                    ValueField("outcome",textValue(child[6] ?? "[none]")),ValueField("error_code",textValue(code)),
                    ValueField("detail_bytes",textValue(child[7] ?? "[none]")),ValueField("operation_id_bytes",textValue(child.required(9))),
                    ValueField("child_call_id_bytes",textValue(child.required(10))),ValueField("request_key_bytes",textValue(child.required(11))),
                    ValueField("receipt_id_bytes",textValue(child[12] ?? "[none]")),ValueField("state_bytes",textValue(child.required(13))),
                    ValueField("outcome_bytes",textValue(child[14] ?? "[none]"))])))
            }
        }catch(_:Exception){println("memory retain receipt diagnostic-unresolved: stored evidence could not be decoded")}
    }
    func retain(content: String, scope!: String = "workspace", key!: String = ""): String {
        let item = objectValue([ValueField("kind", textValue("preference")), ValueField("content", textValue(content)),
            ValueField("scope", textValue(scope))])
        if (key != "") { item.put("scope_key", textValue(key)) }
        let result = call("retain", objectValue([ValueField("items", listValue([item]))]))
        try{
        @Expect(!result.isError)
        // Preserve the original assertion and exact call; report the actual
        // canonical error before a missing ids field can obscure its cause.
        if(result.isError){diagnoseRetainReceipt();throw IllegalStateException("actual Native retain error: "+stringifyUnifiedJson(result.output))}
        result.output.field("ids").getOrThrow().items[0].text
        }finally{result.releasePayload()}
    }
    func close(): Unit { let _ = product.close(); database.close(); remove(root, recursive: true) }
}

class MemoryObservedEmbedding <: MemoryEmbeddingPort {
    private let failed: Bool
    init(failed!: Bool = false) { this.failed = failed }
    public func embed(text: String): Result<Array<Float64>> {
        if (failed) { return Result.Err(AgentError(AgentErrorKind.Transport, "fixture.embedding_failed", "observed adapter failure")) }
        Result.Ok(if (text.contains("concise") || text.contains("meaning-neighbor")) { [1.0, 0.0] } else { [0.0, 1.0] })
    }
}
class MemoryMutatingPolicy <: MemoryRetrievalPolicy {
    private let repository: MemoryV3Repository
    private let mode: String
    init(repository: MemoryV3Repository, mode: String) { this.repository = repository; this.mode = mode }
    public func retrieve(query: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> {
        let _ = query; let _ = options; let _ = embedding
        if (mode == "change") { let _ = repository.delete(records[0].id) }
        if (mode == "foreign") {
            let foreignRecord = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Session, key: "other"), "foreign memory")))
            return Result.Ok(MemoryV3SearchResult([MemoryV3SearchHit(foreignRecord, 1000)], MemorySearchStrategy.Lexical, false)) }
        let hit = MemoryV3SearchHit(records[0], 1000)
        Result.Ok(MemoryV3SearchResult(if (mode == "duplicate") { [hit, hit] } else { [hit] }, MemorySearchStrategy.Lexical, false))
    }
}

class MemoryRemountingEmbedding <: MemoryEmbeddingPort {
    private let product: ProductRuntime
    private let namespace: String
    var calls: Int64 = 0
    init(product: ProductRuntime, namespace: String) { this.product = product; this.namespace = namespace }
    public func embed(text: String): Result<Array<Float64>> {
        let _ = text
        calls += 1
        if (calls == 1) {
            match (product.setPluginEnabled(namespace, false)) {
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code); case PluginRegistryResult.Ok(_) => () }
            match (product.setPluginEnabled(namespace, true)) {
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code); case PluginRegistryResult.Ok(_) => () }
        }
        Result.Ok([1.0, 0.0])
    }
}

class MemoryCorruptingPageConsumer {
    private let fixture: MemoryPolicyFixture
    private let mode: String
    private var sequence: Int64 = 0
    init(fixture: MemoryPolicyFixture, mode: String) { this.fixture = fixture; this.mode = mode }
    func query(input: AgentValue): Result<AgentValue> {
        sequence++
        let record = fixture.record.getOrThrow()
        let response = match (queryProductPluginPolicy(fixture.product.vnext.javascriptPlugins,
            productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "memory", productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), input, ThreadId("page-validation"),
            CancellationSource().token, "page-consumer-" + mode + "-" + sequence.toString())) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            let result = parseUnifiedJson(stringifyUnifiedJson(response.value), maxBytes: 262144)
            let action = httpIntentText(input, "action")
            if (action == "score_page") {
                let rows = result.field("rows").getOrThrow().items.toArray()
                if (mode == "duplicate") { rows[1] = rows[0]; result.put("rows", listValue(rows)) }
                if (mode == "offset") { result.put("offset", integerValue(1)) }
                if (mode == "missing") { result.put("rows", listValue(rows[..rows.size - 1])) }
                if (mode == "snapshot") { result.put("snapshot_digest", textValue("different")) }
                if (mode == "page") { result.put("page_id", textValue("previous")) }
            }
            if (action == "sort_page" && mode == "missing_sort") {
                let rows = result.field("rows").getOrThrow().items.toArray(); result.put("rows", listValue(rows[..rows.size - 1])) }
            if (action == "merge_page") {
                if (mode == "skip_merge") { result.put("left_consumed", integerValue(productMemoryPolicyInt(result, "left_consumed") + 1)) }
                if (mode == "overlap_merge") {
                    let rows = result.field("rows").getOrThrow().items.toArray(); rows[1] = rows[0]; result.put("rows", listValue(rows)) }
            }
            Result.Ok(result)
        } finally { response.close() }
    }
}

class MemoryExpiringContextConsumer <: ProductMemoryPolicy {
    private let underlying: ProductMemoryPolicy
    private let expiresAt: Int64
    var observed: Bool = false
    init(underlying: ProductMemoryPolicy, expiresAt: Int64) { this.underlying = underlying; this.expiresAt = expiresAt }
    public func validateCurrent(): Result<Unit> { underlying.validateCurrent() }
    public func retrieve(query: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> { underlying.retrieve(query, records, options, embedding) }
    public func correction(current: MemoryV3Record, changes: AgentValue): Result<AgentValue> { underlying.correction(current, changes) }
    public func renderContext(hits: Array<MemoryV3SearchHit>, maxBytes: Int64, repository: MemoryV3Repository): Result<String> {
        let result = underlying.renderContext(hits, maxBytes, repository)
        if (result.isOk()) {
            observed = result.value().getOrThrow().contains("expires-during-consumption")
            // Actual passage of time, with no revision mutation or test clock.
            while (agentUtcMillis() <= expiresAt) { sleep(Duration.millisecond * 5) }
        }
        result
    }
}

@Test
class InstalledMemoryPolicyTests {
    @TestCase
    func codingDefaultsInstallNormalPoliciesAndPreserveExplicitMissingSelections(): Unit {
        let f = CodingDistributionFixture()
        try {
            let path = f.bundle + "/distribution.json"
            let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            let entries = ArrayList<AgentValue>(manifest.field("plugins").getOrThrow().items.toArray())
            let bindings = ArrayList<ValueField>()
            for ((id, provider, variable) in [("memory", "memory", "AXYNDRA_MEMORY_PLUGIN_PACKAGE"),
                ("compaction", "summarize", "AXYNDRA_COMPACTION_PLUGIN_PACKAGE")]) {
                let destination = f.bundle + "/plugins/" + id
                Directory.create(destination)
                pluginCopySnapshotTreeSecure(getVariable(variable).getOrThrow(), destination)
                let descriptor = match (inspectPluginPackage(destination)) {
                    case PluginPackageResult.Ok(value) => value; case PluginPackageResult.Err(error) => throw IllegalStateException(error.code) }
                entries.add(objectValue([ValueField("path", textValue("plugins/" + id)), ValueField("namespace", textValue(descriptor.namespace)),
                    ValueField("version", textValue(descriptor.version)), ValueField("package_digest", textValue(descriptor.contentDigest)),
                    ValueField("enabled", boolValue(true))]))
                bindings.add(ValueField(id, objectValue([ValueField("namespace", textValue(descriptor.namespace)), ValueField("provider", textValue(provider))])))
            }
            manifest.put("plugins", listValue(entries.toArray())); manifest.put("policies", objectValue(bindings.toArray()))
            File.writeTo(path, stringifyUnifiedJson(manifest).toArray())
            let workspace = f.root + "/workspace"; Directory.create(workspace)
            let product = lifecycleTestRequire(f.open(workspace))
            try {
                @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 3)
                @Expect(loadProductPolicySelection(f.root + "/settings", "memory").isOk())
                @Expect(loadProductPolicySelection(f.root + "/settings", "compaction").isOk())
                @Expect(product.prepareRequest("normal Coding defaults").isOk())
                @Expect(product.setPluginEnabled("axyndra:memory", false).isOk())
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(product.prepareRequest("disabled remains unavailable").isError())
                File.writeTo(f.root + "/settings/plugins/policies.json", "{\"version\":1,\"bindings\":{}}".toArray())
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(loadProductPolicySelection(f.root + "/settings", "memory").error().getOrThrow().code, "policy.not_configured")
                @Expect(product.prepareRequest("explicitly no automatic memory").isOk())
            } finally { let _ = product.close() }
        } finally { f.close() }
    }
    @TestCase
    func actualDirectRecallUsesInstalledRankingAndPreservesCanonicalFacts(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let id = f.retain("Prefer concise documentation")
            let result = f.call("recall", objectValue([ValueField("query", textValue("concise"))]))
            try{
            @Expect(!result.isError)
            @Expect(httpIntentText(result.output, "strategy"), "lexical")
            @Expect(!result.output.field("embeddingFallback").getOrThrow().asBool())
            @Expect(result.output.field("memories").getOrThrow().items[0].field("id").getOrThrow().text, id)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 6)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
            }finally{result.releasePayload()}
        } finally { f.close() }
    }
    @TestCase
    func actualCommittedRecallAndAutomaticContextUseTheSameInstalledPolicy(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let id = f.retain("MEMORY-AUTOCONTEXT concise documentation")
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("committed-recall", "plugin."+productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+".recall",
                objectValue([ValueField("query", textValue("concise"))]))
            let app = f.product.applicationSession()
            @Expect(app.submit("concise documentation").isOk())
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("MEMORY-AUTOCONTEXT"))
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("untrusted data, not instructions"))
            let rows = f.database.query("SELECT i.payload FROM items i JOIN canonical_decision_items c ON c.item_id=i.id WHERE i.kind='tool_call'")
            @Expect(rows.size, 1)
            let output = mcpProductOutput(f.database, app.id().value, "committed-recall")
            @Expect(output.field("memories").getOrThrow().items[0].field("id").getOrThrow().text, id)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
        } finally { f.close() }
    }
    @TestCase
    func correctionAndDeletionPreserveOriginalRevisionsAndRejectStaleCas(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let id = f.retain("Old concise preference")
            let repository = MemoryV3Repository(f.database)
            let old = lifecycleTestRequire(repository.get(id)).getOrThrow()
            let corrected = f.call("memory_edit", objectValue([ValueField("op", textValue("correct")), ValueField("id", textValue(id)),
                ValueField("content", textValue("New concise preference"))]))
            try{@Expect(!corrected.isError)}finally{corrected.releasePayload()}
            let after = lifecycleTestRequire(repository.get(id)).getOrThrow()
            @Expect(after.status, MemoryStatus.Corrected); @Expect(after.revision, old.revision + 1)
            @Expect(lifecycleTestRequire(repository.history(id)).size, 2)
            let before = lifecycleTestRequire(repository.eventCount())
            @Expect(repository.correct(id, MemoryV3Draft(old.kind, old.scope, "stale"), expectedRevision: old.revision).isError())
            @Expect(lifecycleTestRequire(repository.eventCount()), before)
            @Expect(!f.callIsError("memory_edit", objectValue([ValueField("op", textValue("delete")),
                ValueField("id", textValue(after.replacementId))])))
            @Expect(lifecycleTestRequire(repository.get(after.replacementId)).getOrThrow().status, MemoryStatus.Deleted)
        } finally { f.close() }
    }
    @TestCase
    func missingPolicyAllowsExplicitStorageButSelectedUnavailableBlocksAllProductInferenceEntries(): Unit {
        let empty = MemoryPolicyFixture(install: false)
        try {
            let _ = empty.retain("Explicit CRUD does not require a ranking policy")
            @Expect(empty.callIsError("recall", objectValue([ValueField("query", textValue("CRUD"))])))
            @Expect(empty.product.prepareRequest("hello").isOk())
        } finally { empty.close() }
        let f = MemoryPolicyFixture()
        try {
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            @Expect(f.product.prepareRequest("request with explicit unavailable policy").isError())
            @Expect(f.product.applicationSession().submit("same actual Application path").isError())
            var threw = false
            try { let _ = f.product.request("legacy SDK convenience wrapper") }
            catch (_: ProductRequestPreparationError) { threw = true }
            @Expect(threw)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            @Expect(f.product.prepareRequest("available again").isOk())
        } finally { f.close() }
    }
    @TestCase
    func trustedEmbeddingFactsPreserveHybridAndFailureFallbackThroughRealProvider(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let selected = f.retain("Prefer concise documentation")
            let _ = f.retain("Use blue terminal colors")
            let policy = lifecycleTestRequire(f.legacyPolicy(SessionId("embedding")))
            let options = MemoryV3SearchOptions(scope: Some(MemoryScope(MemoryScopeKind.Workspace, key: f.root)))
            let hybrid = lifecycleTestRequire(MemoryV3Repository(f.database, embedding: Some(MemoryObservedEmbedding())).search(
                "meaning-neighbor", options: options, policy: Some(policy)))
            @Expect(hybrid.strategy, MemorySearchStrategy.Hybrid); @Expect(!hybrid.embeddingFallback)
            @Expect(hybrid.hits[0].memory.id, selected)
            let failed = lifecycleTestRequire(MemoryV3Repository(f.database, embedding: Some(MemoryObservedEmbedding(failed: true))).search(
                "concise", options: options, policy: Some(policy)))
            @Expect(failed.strategy, MemorySearchStrategy.LexicalFallback); @Expect(failed.embeddingFallback)
            @Expect(failed.hits[0].memory.id, selected)
        } finally { f.close() }
    }
    @TestCase
    func storageRejectsForeignDuplicateAndChangedSnapshotsWithoutHoldingCallbackLock(): Unit {
        for (mode in ["foreign", "duplicate", "change"]) {
            let f = MemoryPolicyFixture(install: false)
            try {
                let _ = f.retain("Only authorized concise memory")
                let repository = MemoryV3Repository(f.database)
                @Expect(repository.search("concise", options: MemoryV3SearchOptions(
                    scope: Some(MemoryScope(MemoryScopeKind.Workspace, key: f.root))),
                    policy: Some(MemoryMutatingPolicy(repository, mode))).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            } finally { f.close() }
        }
    }
    @TestCase
    func pinnedSelectionRejectsConfigurationReplacementAndCancellation(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let _ = f.retain("Concise fact")
            let cancellation = CancellationSource()
            let policy = lifecycleTestRequire(f.legacyPolicy(SessionId("pin"), cancellation: cancellation.token))
            let repository = MemoryV3Repository(f.database)
            let options = MemoryV3SearchOptions(scope: Some(MemoryScope(MemoryScopeKind.Workspace, key: f.root)))
            @Expect(repository.search("concise", options: options, policy: Some(policy)).isOk())
            let path = f.root + "/settings/plugins/policies.json"
            File.appendTo(path, " ".toArray())
            @Expect(repository.search("concise", options: options, policy: Some(policy)).isError())
            f.selection(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.ContentDigest)))
            let next = lifecycleTestRequire(f.legacyPolicy(SessionId("pin"), cancellation: cancellation.token))
            let _ = cancellation.cancel()
            @Expect(repository.search("concise", options: options, policy: Some(next)).isError())
            cancellation.close()
        } finally { f.close() }
    }
    @TestCase
    func firstEmbeddingCannotAdoptARemountedInstanceWithTheSamePackageDigest(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let _ = f.retain("Concise immutable fact")
            let policy = lifecycleTestRequire(f.legacyPolicy(SessionId("embedding-remount")))
            let embedding = MemoryRemountingEmbedding(f.product, productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)))
            let options = MemoryV3SearchOptions(scope: Some(MemoryScope(MemoryScopeKind.Workspace, key: f.root)))
            let result = MemoryV3Repository(f.database, embedding: Some(embedding)).search(
                "concise", options: options, policy: Some(policy))
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "memory.policy_changed")
            @Expect(embedding.calls, 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            let current = lifecycleTestRequire(f.legacyPolicy(SessionId("embedding-remount")))
            @Expect(MemoryV3Repository(f.database).search("concise", options: options, policy: Some(current)).isOk())
        } finally { f.close() }
    }
    @TestCase
    func actualPagedRecallExceedsOneLogicalQueryAndKeepsTheCanonicalResult(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let padding = String.fromUtf8(Array<Byte>(1572864, repeat: b'x'))
            let expected = f.retain("needle " + padding)
            let _ = f.retain("haystack-one " + padding)
            let _ = f.retain("haystack-two " + padding)
            let result = f.call("recall", objectValue([ValueField("query", textValue("needle")), ValueField("limit", integerValue(1))]))
            try{
            @Expect(!result.isError)
            @Expect(result.output.field("memories").getOrThrow().items.size, 1)
            @Expect(httpIntentText(result.output.field("memories").getOrThrow().items[0], "id"), expected)
            @Expect(httpIntentText(result.output.field("memories").getOrThrow().items[0], "content"), "needle " + padding)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 12)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 4)
            }finally{result.releasePayload()}
        } finally { f.close() }
    }
    @TestCase
    func hostRejectsDuplicateMissingOverlappingAndStalePageProposalsFromAnActualProvider(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let repository = MemoryV3Repository(f.database); let records = ArrayList<MemoryV3Record>()
            for (index in 0..129) { records.add(lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), "concise " + index.toString())))) }
            for (mode in ["duplicate", "offset", "missing", "snapshot", "page", "missing_sort", "skip_merge", "overlap_merge"]) {
                let consumer = MemoryCorruptingPageConsumer(f, mode)
                let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("page-validation")))
                let options = MemoryV3SearchOptions(nowMillis: agentUtcMillis(), semanticEnabled: false)
                let result = ProductMemoryPagedRanking(records.toArray(), options, "concise", { input => consumer.query(input) },
                    { => selected.validateCurrent() }).retrieve(None)
                @Expect(result.isError())
                @Expect(["memory.page_result_invalid", "memory.page_identity"].contains(result.error().getOrThrow().code))
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 129)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { f.close() }
    }
    @TestCase
    func contextThatExpiresAfterRenderingCannotBecomeAutomaticContextAndHistoryRemains(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let _ = f.retain("warmup")
            let policy = lifecycleTestRequire(f.legacyPolicy(SessionId("expiry")))
            let repository = MemoryV3Repository(f.database)
            @Expect(repository.search("warmup", policy: Some(policy)).isOk())
            let expiry = agentUtcMillis() + 10000
            let record = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), "expires-during-consumption", expiresAt: expiry)))
            let delayed = MemoryExpiringContextConsumer(policy, expiry)
            let runtime = ProductMemoryRuntime(repository, DiskManagedSkillRepository(f.root + "/settings"), f.root + "/settings", f.root,
                policyFactory: Some({ session, cancellation => let _ = session; let _ = cancellation; Result<ProductMemoryPolicy>.Ok(delayed) }))
            let result = runtime.contextFor("expires-during-consumption", SessionId("expiry"), f.root, 65536)
            @Expect(delayed.observed)
            @Expect(result.isError())
            @Expect(result.value().isNone())
            @Expect(result.error().getOrThrow().code, "memory_v3.context_fact_expired_or_changed")
            @Expect(lifecycleTestRequire(repository.history(record.id)).size, 1)
            @Expect(lifecycleTestRequire(repository.get(record.id)).getOrThrow().revision, record.revision)
            @Expect(!lifecycleTestRequire(repository.get(record.id)).getOrThrow().isRetrievable(nowMillis: agentUtcMillis()))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
}
