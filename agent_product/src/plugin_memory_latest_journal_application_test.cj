package agent_product

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func latestJournalApplicationFixture(approval!:ApprovalMode=ApprovalMode.Yolo):MemoryPolicyFixture{
    // This separate required environment names a genuine newly built v3
    // package. A baseline21/40 package is never silently substituted here.
    MemoryPolicyFixture(windowed:true,approval:approval,
        pluginPackage:Some(getVariable("AXYNDRA_MEMORY_LATEST_CONTEXT_PLUGIN_PACKAGE").getOrThrow()))
}
func latestJournalApplicationAccess():AgentValue{
    let paths:Array<Array<String>>=[["version"],["operation"],["record"],["record","id"],["record","kind"],
        ["record","scopeKind"],["record","scopeKey"],["record","content"],["record","status"],
        ["record","context"],["record","source"],["record","revision"],["record","conflictIds"]]
    let fields=paths.map{path=>objectValue([ValueField("path",listValue(path.map{part=>textValue(part)})),
        ValueField("prefix_bytes",integerValue(if((path.size==1 && path[0]=="version") ||
            (path.size==2 && path[0]=="record" && ["kind","scopeKind","status"].contains(path[1]))){64}else{0})),
        ValueField("ascii_trimmed_length",boolValue(path.size==2 && path[0]=="record" && path[1]=="scopeKey"))])}
    let scopes=[("global","text_fallback_empty"),("user","ascii_nonempty"),("workspace","current_workspace"),("session","current_thread")]
    objectValue([ValueField("schema",textValue(ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA)),ValueField("fields",listValue(fields)),
        ValueField("scope_classification_path",listValue([textValue("record"),textValue("scopeKind")])),
        ValueField("scope_key_path",listValue([textValue("record"),textValue("scopeKey")])),
        ValueField("scopes",listValue(scopes.map{row=>objectValue([ValueField("classification",textValue(row[0])),ValueField("key_match",textValue(row[1]))])}))])
}
func latestJournalApplicationProfile(f:MemoryPolicyFixture,readGrant!:Bool=true,computeGrant!:Bool=true,purpose!:Bool=true,
    maximum!:Int64=4096):Unit{
    let record=f.record.getOrThrow();let directory=f.root+"/settings/plugins"
    let providers=ArrayList<AgentValue>()
    if(readGrant){providers.add(memoryWindowProviderGrant(f,"prepare_window_context"))}
    if(computeGrant){providers.add(memoryWindowProviderGrant(f,"memory_context"))}
    File.writeTo(directory+"/document-context.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
        ValueField("providers",listValue(providers.toArray()))])).toArray())
    let mapping=objectValue([ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("key",textValue("journal")),ValueField("purpose",textValue("event-latest-structural-read")),ValueField("access",latestJournalApplicationAccess()),
        ValueField("view",objectValue([ValueField("schema",textValue(ROW_JOURNAL_LATEST_VIEW_SCHEMA)),
            ValueField("group_key_path",listValue([textValue("record"),textValue("id")])),ValueField("ordinal",textValue("event-primary-key")),
            ValueField("fold",textValue("last-value-first-position"))]))])
    File.writeTo(directory+"/document-journal-streams.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
        ValueField("backends",listValue(if(purpose){[mapping]}else{[]})),ValueField("providers",listValue(if(purpose){[
            memoryWindowProviderGrant(f,"prepare_window_context"),memoryWindowProviderGrant(f,"memory_context")]}else{[]})),
        ValueField("tools",listValue([]))])).toArray())
    File.writeTo(directory+"/context.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(8)),
        ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("provider",textValue("memory_context")),ValueField("preparation_provider",textValue("prepare_window_context")),
        ValueField("data_schema",textValue("axyndra.memory-latest-context-data/v3")),ValueField("preparation_schema",textValue("axyndra.context-journal-preparation-query/v3")),
        ValueField("resources",listValue([textValue("journal")])),ValueField("query",objectValue([
            ValueField("schema",textValue("axyndra.memory-context-query/v1")),ValueField("max_bytes",integerValue(maximum))])),
        ValueField("prompt_field",textValue("query"))])).toArray())
}
func latestJournalApplicationContent(f:MemoryPolicyFixture):String{
    let snapshot=contextSnapshotFromValue(decodeStoredValue(f.database.query("SELECT skill_snapshot FROM runs")[0].required(0)))
    let owner=productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+"/context/memory_context"
    for(item in snapshot.contributions() where item.owner==owner){return item.content};""
}
func latestJournalApplicationSuccessful(f:MemoryPolicyFixture,before:String):Unit{
    memoryWindowAssertParentlessFacts(f,1)
    @Expect(memoryNativeHistoryBytes(f.database),before)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),1)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"),1)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
    let operation=f.database.query("SELECT id,run_id FROM operations WHERE tool_name=?",[SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])[0]
    let fact=lifecycleTestRequire(DurableOperationStore(f.database).loadContextReadFact(OperationId(operation.required(0)),RunId(operation.required(1))))
    let data=fact.output();@Expect(httpIntentText(data,"schema"),"axyndra.plugin-document-journal-stream-read-result/v3")
    @Expect(data.field("documents").getOrThrow().items.size,1)
    @Expect(data.field("documents").getOrThrow().items[0].field("stream").isSome())
}
func latestJournalApplicationOriginalContext(f:MemoryPolicyFixture,query:String):String{
    let runtime=ProductMemoryRuntime(MemoryV3Repository(f.database),DiskManagedSkillRepository(f.root+"/settings"),
        f.root+"/settings",f.root,policyFactory:Some({session,cancel=>f.legacyPolicy(session,cancellation:cancel)}))
    // Unmounted original business implementation and real Native policy are
    // a complete behavioral oracle only. No production factory is installed.
    lifecycleTestRequire(runtime.contextFor(query,SessionId("terminal"),f.root,4096))
}
func latestJournalApplicationSeedEvents(f:MemoryPolicyFixture,count:Int64):Unit{
    let first=memoryWindowSeed(f,"unrelated first original record")
    let prototype=f.database.query("SELECT payload FROM memories WHERE id=?",[SqlParameter.Text(first.id)])[0].required(0)
    f.database.transaction<Unit>({tx=>
        for(index in 2..count+1){let event=parseUnifiedJson(prototype,maxBytes:67108864);let record=event.field("record").getOrThrow()
            let id="actual-stream-history-"+index.toString();record.put("id",textValue(id))
            record.put("content",textValue(if(index==count){"needle MEMORY-STREAM-LAST-"+index.toString()}else{"unrelated original record "+index.toString()}))
            let raw=stringifyUnifiedJson(event)
            tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'preference',?,1)",[SqlParameter.Text(id),SqlParameter.Text(raw)])
            tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,1,'retain',?,?)",
                [SqlParameter.Text(id),SqlParameter.Text(raw),SqlParameter.Int64Value(agentUtcMillis())])}})
}

@Test
class InstalledNativeLatestJournalApplicationTests {
    @TestCase
    func genuineSixMiBOneReadMatchesWholeOriginalContextAndHistoryOracle():Unit{
        let f=latestJournalApplicationFixture()
        try{
            let content="needle MEMORY-STREAM-SIX-MIB "+String.fromUtf8(Array<Byte>(6291456,repeat:b'x'))
            let record=memoryWindowSeed(f,content);let before=memoryNativeHistoryBytes(f.database)
            let expected=latestJournalApplicationOriginalContext(f,"needle");@Expect(expected.size,4096)
            latestJournalApplicationProfile(f);@Expect(f.product.applicationSession().submit("needle").isOk())
            @Expect(latestJournalApplicationContent(f),expected);latestJournalApplicationSuccessful(f,before)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).get(record.id)).getOrThrow().content,content)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).history(record.id)).size,1)
        }finally{f.close()}
    }
    @TestCase
    func genuineRecord3001AndEveryOriginalHistoricalFactReachOneRoot():Unit{
        let f=latestJournalApplicationFixture()
        try{
            latestJournalApplicationSeedEvents(f,3001);let before=memoryNativeHistoryBytes(f.database)
            let expected=latestJournalApplicationOriginalContext(f,"needle")
            latestJournalApplicationProfile(f);@Expect(f.product.applicationSession().submit("needle").isOk())
            @Expect(latestJournalApplicationContent(f),expected);@Expect(expected.contains("MEMORY-STREAM-LAST-3001"))
            latestJournalApplicationSuccessful(f,before);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"),3001)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memories"),3001)
        }finally{f.close()}
    }
    @TestCase
    func genuine63MiBRecordCannotBeReducedToOldSevenBodyWindows():Unit{
        let f=latestJournalApplicationFixture()
        try{
            let content="needle MEMORY-STREAM-63-MIB "+String.fromUtf8(Array<Byte>(66060288,repeat:b'x'))
            let record=memoryWindowSeed(f,content)
            // Actual body bytes stay strictly below the original64MiB codec.
            let persisted=Int64.parse(f.database.query("SELECT length(CAST(payload AS BLOB)) FROM memory_events")[0].required(0))
            @Expect(persisted>66060288);@Expect(persisted<67108864)
            let before=memoryNativeHistoryBytes(f.database);let expected=latestJournalApplicationOriginalContext(f,"needle")
            @Expect(expected.size,4096);latestJournalApplicationProfile(f)
            @Expect(f.product.applicationSession().submit("needle").isOk())
            @Expect(latestJournalApplicationContent(f),expected);latestJournalApplicationSuccessful(f,before)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).get(record.id)).getOrThrow().content,content)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).history(record.id)).size,1)
        }finally{f.close()}
    }
    @TestCase
    func actualNearMaximumQueryMatchesSmallQueryOracleWithoutParameterTruncation():Unit{
        let f=latestJournalApplicationFixture()
        try{
            let query=String.fromUtf8(Array<Byte>(CONTENT_PAYLOAD_MESSAGE_BYTES-4096,repeat:b'a'))
            let _=memoryWindowSeed(f,query);let before=memoryNativeHistoryBytes(f.database)
            // The complete original policy renders this all-'a' record for
            // query 'a': both whole-substring and its single token match1000.
            // Native136 separately compares the near-maximum FULL query with
            // the original whole Native business implementation. This real
            // Root must receive that entire large query and render the same
            // complete context, not merely pass an allocation simulation.
            let expected=latestJournalApplicationOriginalContext(f,"a");@Expect(expected.size,4096)
            latestJournalApplicationProfile(f);@Expect(f.product.applicationSession().submit(query).isOk())
            @Expect(latestJournalApplicationContent(f),expected);latestJournalApplicationSuccessful(f,before)
        }finally{f.close()}
    }
    @TestCase
    func oldEventsDetermineCurrentAndMalformedCacheDriftStillRecoversReadOnly():Unit{
        let f=latestJournalApplicationFixture()
        try{
            let record=memoryWindowSeed(f,"needle MEMORY-STREAM-RECOVERED-CURRENT")
            f.database.execute("UPDATE memories SET payload='stale old cache',revision=99 WHERE id=?",[SqlParameter.Text(record.id)])
            let before=memoryNativeHistoryBytes(f.database);let expected=latestJournalApplicationOriginalContext(f,"needle")
            latestJournalApplicationProfile(f);@Expect(f.product.applicationSession().submit("needle").isOk())
            @Expect(latestJournalApplicationContent(f),expected);latestJournalApplicationSuccessful(f,before)
            let cached=f.database.query("SELECT payload,revision FROM memories WHERE id=?",[SqlParameter.Text(record.id)])[0]
            @Expect(cached.required(0),"stale old cache");@Expect(cached.required(1),"99")
        }finally{f.close()}
    }
    @TestCase
    func privateLatestCannotBeReconstructedFromOlderReadableHistory():Unit{
        let f=latestJournalApplicationFixture()
        try{
            let record=memoryWindowSeed(f,"needle MUST-NOT-REVIVE-OLDER-WORKSPACE-CURRENT")
            let event=parseUnifiedJson(f.database.query("SELECT payload FROM memory_events")[0].required(0),maxBytes:67108864)
            let value=event.field("record").getOrThrow();value.put("scopeKind",textValue("session"));value.put("scopeKey",textValue("another-private-thread"))
            value.put("content",textValue("needle PRIVATE-LATEST-SECRET"));value.put("revision",integerValue(2))
            f.database.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,2,'retain',?,?)",
                [SqlParameter.Text(record.id),SqlParameter.Text(stringifyUnifiedJson(event)),SqlParameter.Int64Value(agentUtcMillis())])
            let before=memoryNativeHistoryBytes(f.database);@Expect(latestJournalApplicationOriginalContext(f,"needle"),"")
            latestJournalApplicationProfile(f);@Expect(f.product.applicationSession().submit("needle").isOk())
            @Expect(latestJournalApplicationContent(f),"");latestJournalApplicationSuccessful(f,before)
            let system=f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
            @Expect(!system.contains("MUST-NOT-REVIVE"));@Expect(!system.contains("PRIVATE-LATEST-SECRET"))
        }finally{f.close()}
    }
    @TestCase
    func malformedUnreadableHistoricalVersionStillBlocksModelAfterActualRead():Unit{
        let f=latestJournalApplicationFixture()
        try{
            let _=memoryWindowSeed(f,"needle readable current")
            let event=parseUnifiedJson(f.database.query("SELECT payload FROM memory_events")[0].required(0),maxBytes:67108864)
            let record=event.field("record").getOrThrow();record.put("id",textValue("private-bad-history"))
            record.put("scopeKind",textValue("session"));record.put("scopeKey",textValue("another-private-thread"));record.put("content",integerValue(9))
            f.database.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('private-bad-history',1,'retain',?,?)",
                [SqlParameter.Text(stringifyUnifiedJson(event)),SqlParameter.Int64Value(agentUtcMillis())])
            let before=memoryNativeHistoryBytes(f.database);latestJournalApplicationProfile(f)
            @Expect(f.product.applicationSession().submit("needle").isError())
            memoryWindowAssertParentlessFacts(f,1);memoryWindowNoModelOrFinalContext(f)
            @Expect(memoryNativeHistoryBytes(f.database),before)
        }finally{f.close()}
    }
    @TestCase
    func bothOriginalReadonlyGrantsAndStrictPurposeAreRequiredBeforeRun():Unit{
        for(mode in ["read","compute","purpose"]){let f=latestJournalApplicationFixture()
            try{
                let _=memoryWindowSeed(f,"needle denied");let before=memoryNativeHistoryBytes(f.database)
                latestJournalApplicationProfile(f,readGrant:mode!="read",computeGrant:mode!="compute",purpose:mode!="purpose")
                @Expect(f.product.applicationSession().submit("needle").isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
                memoryWindowNoModelOrFinalContext(f);@Expect(memoryNativeHistoryBytes(f.database),before)
            }finally{f.close()}}
    }
    @TestCase
    func actualApprovalPrecedesSoleParentlessReadAndFinalModel():Unit{
        let f=latestJournalApplicationFixture(approval:ApprovalMode.AlwaysAsk)
        try{
            let _=memoryWindowSeed(f,"needle MEMORY-STREAM-APPROVED");let before=memoryNativeHistoryBytes(f.database)
            latestJournalApplicationProfile(f);let app=f.product.applicationSession()
            let first=lifecycleTestRequire(app.submit("needle")).approval.getOrThrow()
            @Expect(first.toolName,HOST_CONTEXT_READ_TOOL);memoryWindowNoModelOrFinalContext(f)
            let result=lifecycleTestRequire(app.decide(first.operationId.value,ApprovalDecision.Approve))
            @Expect(result.approval.isNone());@Expect(latestJournalApplicationContent(f).contains("MEMORY-STREAM-APPROVED"))
            latestJournalApplicationSuccessful(f,before)
        }finally{f.close()}
    }
    @TestCase
    func cancellationAndEitherProviderGrantRevocationCannotBorrowPendingApproval():Unit{
        for(mode in ["cancel","disable","read","compute","operator"]){let f=latestJournalApplicationFixture(approval:ApprovalMode.AlwaysAsk)
            try{
                let _=memoryWindowSeed(f,"needle revoked actual Root");let before=memoryNativeHistoryBytes(f.database)
                latestJournalApplicationProfile(f);let app=f.product.applicationSession()
                let pending=lifecycleTestRequire(app.submit("needle")).approval.getOrThrow()
                if(mode=="cancel"){@Expect(app.cancel().isOk())}
                else if(mode=="disable"){@Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)),false).isOk())}
                else if(mode=="operator"){
                    File.writeTo(f.root+"/settings/plugins/document-journal-streams.json","{}".toArray())}
                else{latestJournalApplicationProfile(f,readGrant:mode!="read",computeGrant:mode!="compute")}
                @Expect(app.decide(pending.operationId.value,ApprovalDecision.Approve).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"),1)
                memoryWindowNoModelOrFinalContext(f);@Expect(memoryNativeHistoryBytes(f.database),before)
            }finally{f.close()}}
    }
}
