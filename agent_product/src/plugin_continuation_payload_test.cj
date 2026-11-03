package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.reserveNativeDocumentPayload
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func continuationPayloadCommandFixture():WorkflowCommandFixture {
    let f=WorkflowCommandFixture(mode:ApprovalMode.Yolo)
    try {
        let path=f.root+"/settings/plugins/documents.json"
        let config=parseUnifiedJson(String.fromUtf8(File.readFrom(path)),maxBytes:65536)
        for(tool in config.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items) {
            tool.put("preparation_provider",textValue("prepare_document"))
            tool.put("payload_references",boolValue(true))
            tool.put("tool_payload_limits",OrdinaryToolPayloadLimits(httpIntentText(tool,"name")).value())
        }
        File.writeTo(path,stringifyUnifiedJson(config).toArray())
        @Expect(loadProductPluginDocumentConfiguration(f.root+"/settings",productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest))).isOk())
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0)
        f
    }catch(error:Exception){f.close();throw error}
}

func continuationPayloadAssertPins(f:WorkflowCommandFixture):Unit {
    let rows=f.database.query("SELECT payload FROM audit_events WHERE kind='host_continuation_control_document_v1' ORDER BY id")
    @Expect(!rows.isEmpty())
    let pin=decodeStoredValue(rows[rows.size-1].required(0))
    @Expect(httpIntentText(pin,"sha256"),modelPolicySha256Text(f.document("goal").encoded))
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed' AND detail LIKE '%axyndra.plugin-document-result/v2%' ")>0)
}

@Test
class PluginContinuationPayloadTests {
    @TestCase
    func canonicalHostFactsPauseDuringActualHistoricalUploadStopsTheNextRead():Unit {
        let f=continuationPayloadCommandFixture();let cancelled=CancellationSource()
        var session:?ProductDocumentDataSession=None
        try {
            @Expect(f.command("goal","set Keep the real user scope while its control is live").isOk())
            @Expect(f.command("goal","budget 64").isOk())
            let control=f.facts().getOrThrow();let facts=ContinuationAllowanceRepository(SqliteRunRepository(f.database))
            let host=f.product.vnext.javascriptPlugins
            let config=loadProductPluginDocumentConfiguration(f.root+"/settings",productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),
                productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest))).value().getOrThrow()
            let binding=host.policyProviderBinding(config.namespace,"propose").value().getOrThrow()
            let operation=f.database.query("SELECT operation_id FROM audit_events WHERE kind='host_continuation_control_document_v1' ORDER BY id DESC LIMIT 1")[0].required(0)
            let observed={=>
                let paid=ContinuationDocumentReadScope({bytes=>reserveNativeDocumentPayload(bytes)})
                try {f.database.readTransaction<Result<CompletedPluginDocumentObservation>>({tx=>
                    let version=match(readContinuationDocumentVersion(tx,control.address.threadId,control.address.laneId,config.namespace,"goal",paid)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    observeCompletedPluginDocumentPayload(tx,version,"plugin."+config.namespace+".goal",config.packageDigest,
                        binding.generation.toString(),config.digest,paid,operationId:Some(operation))
                })}finally{paid.close()}}
            let original=observed().value().getOrThrow();let reference=original.payload.getOrThrow()
            let current={=>f.database.readTransaction<Result<Unit>>({tx=>continuationPayloadFactsCurrent(tx,facts,control.address,
                control.eventId,control.generation,control.controlSourceDigest)})}
            let authorize: () -> Result<Unit> ={=>
                let actual=match(observed()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                if(canonicalAgentValue(actual.descriptor())!=canonicalAgentValue(original.descriptor())){
                    return commandControlError<Unit>("test.history_changed")}
                current()}
            let owned=host.documentDataSession().value().getOrThrow();session=Some(owned)
            let sequence=host.allocateDocumentDataSequence().value().getOrThrow();let digest=modelPolicySha256Text("actual-facts-pause")
            let phase={action:String,fields:Array<ValueField>=>
                let value=objectValue([ValueField("schema",textValue("axyndra.document-data-query/v1")),ValueField("action",textValue(action)),
                    ValueField("sequence",integerValue(sequence)),ValueField("source_digest",textValue(digest))])
                for(field in fields){value.put(field.name,field.value)};value}
            let data=ProductFixedProviderDataScope(host,config,"propose",binding.generation,control.address.threadId,cancelled.token,
                ExecutionResourceLimits(),"actual-mid-upload-facts",MonoTime.now()+Duration.second*5,{=>Result<Unit>.Ok(())},current)
            let chunks=AtomicInt64(0);let operations=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let runs=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            let outcome=owned.run({actual=>data.run(actual,{scope=>
                let begin=scope.exchange(phase("begin",[ValueField("tool",textValue("goal_continuation")),ValueField("input",objectValue([])),
                    ValueField("documents",listValue([continuationPayloadSlot("approved",reference),continuationPayloadSlot("current",reference)]))]),checkpoint:true)
                @Expect(begin.isOk());@Expect(begin.value().getOrThrow().field("accepted").getOrThrow().asBool())
                let upload=actual.uploadPrepared(reference,authorize,current,{offset,bytes=>
                    let appended=scope.exchange(phase("append",[ValueField("id",textValue("approved")),ValueField("offset",integerValue(offset)),
                        ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes)))]))
                    @Expect(appended.isOk());@Expect(appended.value().getOrThrow().field("accepted").getOrThrow().asBool())
                    if(chunks.fetchAdd(1)==0){
                        // Restrict-only TEST fault through the real Host facts
                        // repository. It does not mint a user scope/admission
                        // and deliberately does not invoke volatile revoke().
                        let paused=f.database.transaction<Result<ContinuationAllowanceFacts>>({tx=>facts.appendControlFacts(tx,control.address,
                            Some(control),ContinuationAllowanceControl.Pause,control.controlSourceDigest,nowMillis())})
                        @Expect(paused.isOk());@Expect(!paused.value().getOrThrow().hasRemainingTokens())
                    }
                    Result<Unit>.Ok(())
                })
                @Expect(chunks.load(),1);@Expect(upload.isError());@Expect(upload.error().getOrThrow().code,"continuation.control_changed_or_exhausted")
                // No compute is issued after the failed exact current source.
                match(upload){case Result.Err(error)=>Result<AgentValue>.Err(error);case Result.Ok(_)=>Result.Ok(nullValue())}
            })})
            @Expect(outcome.isError());let cleanup=MonoTime.now()+Duration.second*5;var acknowledged=owned.collect()
            while(!acknowledged && MonoTime.now()<cleanup){sleep(Duration.millisecond*5);acknowledged=owned.collect()}
            @Expect(acknowledged);@Expect(owned.close().isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),runs)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            @Expect(f.session.submit("The separately retained Application owner also observes the paused canonical control.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
        }finally{match(session){case Some(value)=>let _=value.close();case None=>()};cancelled.close();f.close()}
    }

    @TestCase
    func completedBeginResponseWhosePostguardFailsKeepsActualWorkerCleanup():Unit {
        let f=continuationPayloadCommandFixture();let cancelled=CancellationSource()
        let armed=AtomicBool(false);let checks=AtomicInt64(0)
        var session:?ProductDocumentDataSession=None
        try {
            let host=f.product.vnext.javascriptPlugins
            let config=loadProductPluginDocumentConfiguration(f.root+"/settings",productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),
                productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest))).value().getOrThrow()
            let binding=host.policyProviderBinding(config.namespace,"propose").value().getOrThrow()
            let owned=host.documentDataSession().value().getOrThrow();session=Some(owned)
            let sequence=host.allocateDocumentDataSequence().value().getOrThrow()
            let slot={name:String=>objectValue([ValueField("id",textValue(name)),ValueField("bytes",integerValue(2)),
                ValueField("sha256",textValue(modelPolicySha256Text("{}")))])}
            let data=ProductFixedProviderDataScope(host,config,"propose",binding.generation,ThreadId(f.session.id().value),
                cancelled.token,ExecutionResourceLimits(),"continuation-begin-postguard",MonoTime.now()+Duration.second*5,
                {=>Result<Unit>.Ok(())},{=>
                    if(armed.load() && checks.fetchAdd(1)==1){return pluginProcessError<Unit>("test.postguard_revoked","fixture source changed after a real reply")}
                    Result<Unit>.Ok(())})
            let result=owned.run({actual=>data.run(actual,{scope=>
                armed.store(true)
                let begin=scope.exchange(objectValue([ValueField("schema",textValue("axyndra.document-data-query/v1")),
                    ValueField("action",textValue("begin")),ValueField("sequence",integerValue(sequence)),
                    ValueField("source_digest",textValue(modelPolicySha256Text("postguard-source"))),ValueField("tool",textValue("goal_continuation")),
                    ValueField("input",objectValue([])),ValueField("documents",listValue([slot("approved"),slot("current")]))]),checkpoint:true)
                // The second complete-current call occurs only after an
                // actual successful protocol response was received/validated.
                @Expect(checks.load(),2);@Expect(begin.isError());@Expect(begin.error().getOrThrow().code,"test.postguard_revoked")
                @Expect(!actual.collect());@Expect(actual.close().error().getOrThrow().code,"plugin.document_query_cleanup_pending")
                begin
            })})
            @Expect(result.isError())
            let deadline=MonoTime.now()+Duration.second*5;var acknowledged=owned.collect()
            while(!acknowledged && MonoTime.now()<deadline){sleep(Duration.millisecond*5);acknowledged=owned.collect()}
            @Expect(acknowledged);@Expect(owned.close().isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
        }finally{match(session){case Some(value)=>let _=value.close();case None=>()};cancelled.close();f.close()}
    }

    @TestCase
    func duplicatedActualUserPinCannotPassTheBoundedFinalAdmissionQuery():Unit {
        let f=continuationPayloadCommandFixture()
        try {
            @Expect(f.command("goal","set Retain the one actual user source").isOk())
            @Expect(f.command("goal","budget 64").isOk())
            continuationPayloadAssertPins(f)
            let pin=f.database.query("SELECT id FROM audit_events WHERE kind='host_continuation_control_document_v1' ORDER BY id DESC LIMIT 1")[0].required(0)
            // Explicit corrupted-database negative: only duplicate the real
            // previously committed source; do not manufacture an authority.
            for(_ in 0..32){f.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) "+
                "SELECT thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence FROM audit_events WHERE id=?",[SqlParameter.Text(pin)])}
            @Expect(f.session.submit("Finish the ordinary turn, then reject ambiguous continuation pins.").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','accepted','recovery_required')"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE active_turn_id IS NOT NULL"),0)
        }finally{f.close()}
    }

    @TestCase
    func actualPureTransferCannotConsumePartialDataAfterItsOriginalBoundaryChanges():Unit {
        // This is a transport regression on a real installed pure worker,
        // not a fabricated UserOwner/ContextRead permission. The Application
        // tests below separately exercise the actual continuation authority.
        for(change in ["configuration","generation","package","cancel","deadline"]) {
            let f=continuationPayloadCommandFixture();let cancelled=CancellationSource()
            let host=f.product.vnext.javascriptPlugins
            let configPath=f.root+"/settings/plugins/documents.json"
            let configBytes=File.readFrom(configPath)
            let packagePath=productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Root))+"/README.md";let packageBytes=File.readFrom(packagePath)
            var session:?ProductDocumentDataSession=None
            try {
                let config=loadProductPluginDocumentConfiguration(f.root+"/settings",productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),
                    productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest))).value().getOrThrow()
                let binding=host.policyProviderBinding(config.namespace,"propose").value().getOrThrow()
                let owned=host.documentDataSession().value().getOrThrow();session=Some(owned)
                let sequence=host.allocateDocumentDataSequence().value().getOrThrow()
                let digest=modelPolicySha256Text("continuation-transfer-"+change)
                let slotDigest=modelPolicySha256Text("{}")
                let slot={name:String=>objectValue([ValueField("id",textValue(name)),
                    ValueField("bytes",integerValue(2)),ValueField("sha256",textValue(slotDigest))])}
                let phase={action:String,fields:Array<ValueField>=>
                    let value=objectValue([ValueField("schema",textValue("axyndra.document-data-query/v1")),
                        ValueField("action",textValue(action)),ValueField("sequence",integerValue(sequence)),
                        ValueField("source_digest",textValue(digest))])
                    for(field in fields){value.put(field.name,field.value)};value }
                let deadline=MonoTime.now()+Duration.second*5
                let data=ProductFixedProviderDataScope(host,config,"propose",binding.generation,ThreadId(f.session.id().value),
                    cancelled.token,ExecutionResourceLimits(),"continuation-transfer-"+change,deadline,
                    {=>Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})
                let outcome=owned.run({actual=>data.run(actual,{scope=>
                    let opened=scope.exchange(phase("begin",[ValueField("tool",textValue("goal_continuation")),
                        ValueField("input",objectValue([])),ValueField("documents",listValue([slot("approved"),slot("current")]))]),checkpoint:true)
                    @Expect(opened.isOk());@Expect(opened.value().getOrThrow().field("accepted").getOrThrow().asBool())
                    let partial=scope.exchange(phase("append",[ValueField("id",textValue("approved")),
                        ValueField("offset",integerValue(0)),ValueField("bytes_hex",textValue("7b"))]))
                    @Expect(partial.isOk());@Expect(partial.value().getOrThrow().field("accepted").getOrThrow().asBool())
                    if(change=="configuration"){File.writeTo(configPath,(String.fromUtf8(configBytes)+"\n").toArray())}
                    else if(change=="generation"){@Expect(host.unmount(config.namespace).isOk())}
                    else if(change=="package"){File.writeTo(packagePath,"changed after actual partial pure transfer".toArray())}
                    else if(change=="cancel"){cancelled.cancel()}
                    else {while(MonoTime.now()<deadline){sleep(Duration.millisecond)}}
                    let stopped=scope.validate();@Expect(stopped.isError())
                    let result=scope.exchange(phase("compute",[]),checkpoint:true)
                    @Expect(result.isError());@Expect(result.error().getOrThrow().code,stopped.error().getOrThrow().code)
                    if(change=="cancel" || change=="deadline"){@Expect(result.error().getOrThrow().code,"plugin.document_query_timeout")}
                    result
                })})
                @Expect(outcome.isError())
                let cleanupDeadline=MonoTime.now()+Duration.second*5
                var acknowledged=owned.collect()
                while(!acknowledged && MonoTime.now()<cleanupDeadline){sleep(Duration.millisecond*5);acknowledged=owned.collect()}
                @Expect(acknowledged);@Expect(owned.close().isOk())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            }finally{
                match(session){case Some(value)=>let _=value.close();case None=>()}
                File.writeTo(configPath,configBytes);File.writeTo(packagePath,packageBytes)
                cancelled.close();f.close()
            }
        }
    }

    @TestCase
    func referencedCanonicalProgressConsumesOneActualOwnerAndKeepsTypedAdmission():Unit {
        let f=continuationPayloadCommandFixture()
        try {
            @Expect(f.command("goal","set Retain this exact objective through referenced progress").isOk())
            @Expect(f.command("goal","budget 128").isOk())
            continuationPayloadAssertPins(f)
            let original=f.document("goal");let facts=f.facts().getOrThrow()
            continuationObservationProgress(f,"referenced-progress")
            @Expect(f.document("goal").revision>original.revision)
            @Expect(f.session.submit("One short ordinary reply before the bounded continuation.").isOk())
            let claims=f.database.query("SELECT run_id,payload FROM audit_events WHERE kind='host_continuation_claim_consumed_v1' ORDER BY id")
            @Expect(claims.size>=1);@Expect(claims.size<128)
            for(row in claims) {
                let claim=decodeStoredValue(row.required(1));let origin=continuationRunOriginFromValue(claim.field("origin").getOrThrow())
                @Expect(origin.runId,row.required(0));@Expect(origin.controlSourceDigest,facts.controlSourceDigest)
                @Expect(origin.documentObservation.isSome())
                let observation=origin.documentObservation.getOrThrow().value()
                @Expect(httpIntentText(observation,"original_document_sha256"),modelPolicySha256Text(original.encoded))
                @Expect(observation.field("chain").getOrThrow().items.size>=1)
                expectConsumedContinuationObjective(claim, origin, "Retain this exact objective")
            }
            @Expect(f.facts().getOrThrow().eventId,facts.eventId)
            @Expect(f.facts().getOrThrow().tokenBudget,facts.tokenBudget)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','recovery_required')"),0)
        }finally{f.close()}
    }

    @TestCase
    func referencedIntermediatePauseCannotBeHiddenByLaterResume():Unit {
        let f=continuationPayloadCommandFixture()
        try {
            @Expect(f.command("goal","set Observe every referenced stop").isOk())
            @Expect(f.command("goal","budget 128").isOk())
            continuationPayloadAssertPins(f)
            let before=f.facts().getOrThrow()
            continuationObservationInput(f,"referenced-pause",objectValue([ValueField("method",textValue("pause"))]))
            continuationObservationTool(f,"referenced-resume","resume")
            @Expect(httpIntentText(f.document("goal").decode().value().getOrThrow(),"status"),"active")
            @Expect(f.session.submit("Later active data cannot erase the completed pause.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            @Expect(f.session.submit("A stopped owner cannot be reconstructed from the current row.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            @Expect(f.facts().getOrThrow().eventId,before.eventId)
        }finally{f.close()}
    }

    @TestCase
    func sameRevisionBodyDriftCannotBecomeAReferencedContinuationFact():Unit {
        let f=continuationPayloadCommandFixture()
        try {
            @Expect(f.command("goal","set Exact content identity is mandatory").isOk())
            @Expect(f.command("goal","budget 128").isOk())
            let original=f.document("goal");let before=f.facts().getOrThrow()
            // Explicit corrupt-history seam: no canonical mutation Receipt,
            // unchanged revision, and valid but different JSON bytes.
            f.database.execute("UPDATE plugin_documents SET payload='null' WHERE thread_id=? AND namespace=? AND document_key='goal'",
                [SqlParameter.Text(f.session.id().value),SqlParameter.Text(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))])
            @Expect(f.session.submit("An unproved row is not a mutation source.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            f.database.execute("UPDATE plugin_documents SET payload=? WHERE thread_id=? AND namespace=? AND document_key='goal'",
                [SqlParameter.Text(original.encoded),SqlParameter.Text(f.session.id().value),SqlParameter.Text(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))])
            @Expect(f.session.submit("Restoring bytes does not recreate a live owner.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
            @Expect(f.facts().getOrThrow().eventId,before.eventId)
        }finally{f.close()}
    }

    @TestCase
    func operatorOrGenerationDriftPermanentlyStopsTheExistingReferencedOwner():Unit {
        for(mode in ["configuration","generation"]) {
            let f=continuationPayloadCommandFixture()
            try {
                @Expect(f.command("goal","set Preserve the original installed control").isOk())
                @Expect(f.command("goal","budget 128").isOk())
                let before=f.facts().getOrThrow();let path=f.root+"/settings/plugins/documents.json";let original=File.readFrom(path)
                if(mode=="configuration") {
                    // A different complete configuration, not a stat-only
                    // clock change. The original bytes are restored later.
                    let changed=parseUnifiedJson(String.fromUtf8(original),maxBytes:65536)
                    let tools=changed.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items
                    for(tool in tools where httpIntentText(tool,"name")=="goal") {
                        tool.field("documents").getOrThrow().items[0].put("write",boolValue(false)) }
                    File.writeTo(path,stringifyUnifiedJson(changed).toArray())
                }else{
                    match(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),false,PluginInstallScope.Workspace)) {
                        case PluginRegistryResult.Ok(_)=>();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code) }
                }
                @Expect(f.session.submit("Changed installed rights cannot supply the old continuation.").isOk())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
                if(mode=="configuration"){File.writeTo(path,original)}else{
                    match(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),true,PluginInstallScope.Workspace)) {
                        case PluginRegistryResult.Ok(_)=>();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code) }
                }
                @Expect(f.session.submit("Only a new explicit user control could resume it.").isOk())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"),0)
                @Expect(f.facts().getOrThrow().eventId,before.eventId)
            }finally{f.close()}
        }
    }
}
