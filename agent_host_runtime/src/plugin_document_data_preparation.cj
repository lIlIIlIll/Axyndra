package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

public let HOST_DOCUMENT_DATA_SCHEMA="axyndra.document-data-query/v1"

public class HostDocumentDataPreparation {
    private let host:HostJavaScriptPluginHost
    private let namespace:String
    private let tool:String
    private let provider:String
    private let generation:UInt64
    private let configuration:HostPluginDocumentConfiguration
    private let context:ToolInvocationContext
    private let call:ToolCall
    private let binding:AgentValue
    private let started:MonoTime
    private let sequence:Int64
    private let sourceDigest:String
    private var scope: ?HostFixedProviderDataScope = None
    init(host:HostJavaScriptPluginHost,namespace:String,tool:String,provider:String,generation:UInt64,
        configuration:HostPluginDocumentConfiguration,context:ToolInvocationContext,call:ToolCall,binding:AgentValue,sequence:Int64,started:MonoTime){
        this.host=host;this.namespace=namespace;this.tool=tool;this.provider=provider;this.generation=generation
        this.configuration=configuration;this.context=context;this.call=call;this.binding=binding;this.sequence=sequence;this.started=started
        sourceDigest=modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("binding",binding),ValueField("input",call.arguments)])))
    }
    // Safe while the Host generation mutex/artifact/DB are already held.
    private func currentData():Result<Unit>{
        if((MonoTime.now()-started).toMilliseconds()>=5000){return hostPluginResourceError("plugin.document_query_timeout","the original document query deadline expired")}
        if(context.cancellation.isCancelled()){return hostPluginResourceError("plugin.document_cancelled","document query was cancelled")}
        if(context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
            context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:namespace)){
            return hostPluginResourceError("plugin.document_query_scope_changed","document query lost its original caller ceiling")}
        configuration.validateTransferWitness()
    }
    private func transportCurrent():Result<Unit>{scope.getOrThrow().current()}
    private func current():Result<Unit>{scope.getOrThrow().validate()}
    private func phase(action:String):AgentValue{phase(action,[])}
    private func phase(action:String,fields:Array<ValueField>):AgentValue{
        let values=ArrayList<ValueField>([ValueField("schema",textValue(HOST_DOCUMENT_DATA_SCHEMA)),ValueField("action",textValue(action)),
            ValueField("sequence",integerValue(sequence)),ValueField("source_digest",textValue(sourceDigest))])
        values.add(all:fields);objectValue(values.toArray())
    }
    private func exchange(value:AgentValue):Result<AgentValue>{
        scope.getOrThrow().exchange(value,checkpoint:["begin","compute","release"].contains(httpIntentText(value,"action")))
    }
    private func accepted(value:AgentValue,name:String):Result<Unit>{
        if(!httpIntentExactFields(value,[name]) || value.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean || !value.field(name).getOrThrow().asBool()){
            return hostPluginResourceError("plugin.document_query_rejected","document data phase did not acknowledge its exact transfer")}
        Result.Ok(())
    }
    private func download(session:HostDocumentDataSession,description:AgentValue):Result<HostServiceArtifactWriter>{
        let id=httpIntentText(description,"id")
        let size=Int64.parse(description.field("bytes").getOrThrow().asNumberText())
        let writer=match(session.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        var offset:Int64=0
        while(true){
            let part=match(exchange(phase("read",[ValueField("id",textValue(id)),ValueField("offset",integerValue(offset)),ValueField("max_bytes",integerValue(65536))]))){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!httpIntentExactFields(part,["offset","bytes_hex","eof"]) || part.field("offset").getOrThrow().unifiedKind!=ValueKind.Number ||
                part.field("offset").getOrThrow().asNumberText()!=offset.toString() || part.field("bytes_hex").getOrThrow().unifiedKind!=ValueKind.Text ||
                part.field("eof").getOrThrow().unifiedKind!=ValueKind.Boolean){return hostPluginResourceError("plugin.document_query_chunk","document output chunk is malformed")}
            let text=httpIntentText(part,"bytes_hex")
            if(text.size<2 || text.size%2!=0 || text.size>131072 || text.size/2>size-offset){return hostPluginResourceError("plugin.document_query_chunk","document output chunk exceeds its exact declaration")}
            let raw=Array<Byte>(text.size/2,repeat:0);let hex=text.toArray()
            for(i in 0..raw.size){let high=hostDocumentDataNibble(hex[i*2]);let low=hostDocumentDataNibble(hex[i*2+1]);raw[i]=UInt8(high*16+low)}
            // The existing artifact writer still consumes physical 16 KiB
            // slices; semantic 64 KiB data chunks use logical framing.
            var piece:Int64=0
            while(piece<raw.size){let end=min(raw.size,piece+16384)
                match(writer.appendBytes(offset+piece,raw[piece..end],size)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                piece=end}
            offset+=raw.size
            if(part.field("eof").getOrThrow().asBool()){
                if(offset!=size){return hostPluginResourceError("plugin.document_query_incomplete","document output ended before its frozen size")};break}
            if(offset==size){return hostPluginResourceError("plugin.document_query_incomplete","document output omitted its exact terminal")}
        }
        match(writer.finish(size,httpIntentText(description,"sha256"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(writer)
    }
    public func prepare(session:HostDocumentDataSession):Result<AgentValue>{
        let selected=HostFixedProviderDataScope(host,configuration,provider,generation,ThreadId(context.sessionId.value),context.cancellation,
            context.budget.processLimits,call.callId,started+Duration.second*5,{=>currentData()},
            {=>hostDocumentPreparationCurrent(host,configuration,generation,context,binding)})
        scope=Some(selected)
        try{selected.run(session,{_=>prepareBody(session)})}finally{scope=None}
    }
    private func prepareBody(session:HostDocumentDataSession):Result<AgentValue>{
        let envelope=call.arguments.field(CONTEXT_READ_INPUT_FIELD).getOrThrow();let data=envelope.field("data").getOrThrow()
        let links=contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())
        if(links.size!=1 || validateContextReadInputProjection(call.arguments,links).isError() ||
            httpIntentText(data,"schema")!=PLUGIN_DOCUMENT_PAYLOAD_READ_RESULT_SCHEMA){return hostPluginResourceError("plugin.document_fact_missing","document data requires its exact completed fact")}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(host.commitDocumentEffect(namespace,generation,configuration.packageDigest,{=>session.authorize(links[0],binding,data,{=>currentData()})})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let descriptions=ArrayList<AgentValue>()
        for(item in data.field("documents").getOrThrow().items){
            let reference=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
            descriptions.add(objectValue([ValueField("id",item.field("key").getOrThrow()),ValueField("bytes",integerValue(reference.bytes)),ValueField("sha256",textValue(reference.digest))]))}
        let encoded=match(session.parameterUploadBytes(call.arguments)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let parameter=objectValue([ValueField("bytes",integerValue(encoded.size)),ValueField("sha256",textValue(modelPolicySha256(encoded)))])
        let beginning=match(exchange(phase("begin",[ValueField("tool",textValue(tool)),ValueField("input_payload",parameter),ValueField("documents",listValue(descriptions.toArray()))]))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(accepted(beginning,"accepted")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        var released=false
        try{
            var parameterOffset:Int64=0
            while(parameterOffset<encoded.size){
                let end=min(encoded.size,parameterOffset+65536)
                let response=match(exchange(phase("append_input",[ValueField("offset",integerValue(parameterOffset)),
                    ValueField("bytes_hex",textValue(logicalJsonEncodeHex(encoded[parameterOffset..end])))]))){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                match(accepted(response,"accepted")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                parameterOffset=end
            }
            for(item in data.field("documents").getOrThrow().items){
                let reference=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
                let id=httpIntentText(item,"key")
                match(session.upload(reference,{=>transportCurrent()},{offset,bytes=>
                    let response=match(exchange(phase("append",[ValueField("id",textValue(id)),ValueField("offset",integerValue(offset)),
                        ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes)))]))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    accepted(response,"accepted")})){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            let proposed=match(exchange(phase("compute"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!hostApplicationPlanObjectShape(proposed,["intents","outputs","result_slot","is_error","user_control","valid_until_millis"],["intents","outputs","result_slot","is_error"]) ||
                proposed.field("intents").getOrThrow().unifiedKind!=ValueKind.List || proposed.field("outputs").getOrThrow().unifiedKind!=ValueKind.List ||
                proposed.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean){return hostPluginResourceError("plugin.document_prepare_rejected","pure document proposal is malformed")}
            let validity=try{pluginDocumentResultValidityCeiling(proposed)}catch(_:Exception){
                return hostPluginResourceError("plugin.document_result_validity_invalid","pure result validity must be omitted or a positive canonical Int64")}
            let proposals=proposed.field("intents").getOrThrow().items
            let outputs=proposed.field("outputs").getOrThrow().items
            if(proposals.size<1 || proposals.size>8 || outputs.size<1 || outputs.size>9){return hostPluginResourceError("plugin.document_prepare_rejected","pure document output count exceeded")}
            let ids=HashSet<String>();let outputWriters=HashMap<String,HostServiceArtifactWriter>()
            for(description in outputs){
                if(!httpIntentExactFields(description,["id","bytes","sha256"]) || !hostDocumentLogicalName(httpIntentText(description,"id")) ||
                    description.field("bytes").getOrThrow().unifiedKind!=ValueKind.Number || !httpIntentDigest(httpIntentText(description,"sha256"))){
                    return hostPluginResourceError("plugin.document_query_output","pure document output declaration is invalid")}
                let size=Int64.parse(description.field("bytes").getOrThrow().asNumberText());let id=httpIntentText(description,"id")
                if(size<1 || size>8388608 || size.toString()!=description.field("bytes").getOrThrow().asNumberText() || ids.contains(id)){
                    return hostPluginResourceError("plugin.document_query_output","pure document output declaration is duplicated or oversized")}
                ids.add(id)
                let writer=match(download(session,description)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                outputWriters.add(id,writer)}
            // All returned bytes remain inert files until this complete
            // package/configuration checkpoint succeeds.
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let resultSlot=httpIntentText(proposed,"result_slot")
            if(!ids.contains(resultSlot)){return hostPluginResourceError("plugin.document_query_output","full pure result slot is missing")}
            let intents=ArrayList<AgentValue>();let used=HashSet<String>();used.add(resultSlot)
            for(proposal in proposals){
                if(!httpIntentExactFields(proposal,["id","key","mode","next_slot"])){return hostPluginResourceError("plugin.document_prepare_rejected","worker cannot supply original bindings or expected data")}
                let key=httpIntentText(proposal,"key");let mode=httpIntentText(proposal,"mode");let write=mode=="compare_exchange"
                if(!["read","compare_exchange"].contains(mode) || !configuration.permits(tool,key,write)){
                    return hostPluginResourceError("plugin.document_rights_denied","operator did not grant this exact action")}
                var prior:?AgentValue=None
                for(item in data.field("documents").getOrThrow().items where httpIntentText(item,"key")==key){
                    if(prior.isSome()){return hostPluginResourceError("plugin.document_unobserved","observed key is ambiguous")};prior=Some(item)}
                if(prior.isNone()){return hostPluginResourceError("plugin.document_unobserved","document intent must use this exact completed key")}
                var next= nullValue()
                let slot=proposal.field("next_slot").getOrThrow()
                if(write){
                    if(slot.unifiedKind!=ValueKind.Text || !ids.contains(slot.text) || used.contains(slot.text)){
                        return hostPluginResourceError("plugin.document_query_output","replacement does not select its unique completed output")}
                    used.add(slot.text);next=hostDocumentDataReference(outputWriters[slot.text])
                }else if(slot.unifiedKind!=ValueKind.Null){return hostPluginResourceError("plugin.document_read_mutation","read intent cannot select replacement bytes")}
                let observed=prior.getOrThrow()
                intents.add(objectValue([ValueField("id",proposal.field("id").getOrThrow()),ValueField("key",textValue(key)),ValueField("mode",textValue(mode)),
                    ValueField("expected_revision",observed.field("revision").getOrThrow()),ValueField("expected_payload",observed.field("payload").getOrThrow()),ValueField("next_payload",next)]))}
            if(used.size!=outputs.size){return hostPluginResourceError("plugin.document_query_output","unconsumed pure output is forbidden")}
            let hostFields=ArrayList<ValueField>([ValueField("version",textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)),ValueField("binding",binding),
                ValueField("intents",listValue(intents.toArray())),ValueField("result_payload",hostDocumentDataReference(outputWriters[resultSlot])),
                ValueField("result_codec",textValue("axyndra.agent-value-json/v1")),ValueField("is_error",proposed.field("is_error").getOrThrow())])
            if(validity>0){hostFields.add(ValueField("valid_until_millis",integerValue(validity)))}
            match(configuration.toolPayloadLimits(tool)){case Some(profile)=>hostFields.add(ValueField("tool_payload_limits",profile.value()));case None=>()}
            let parent=objectValue([ValueField("input",call.arguments),ValueField("configuration",objectValue([])),ValueField("host_plan",objectValue(hostFields.toArray()))])
            match(pluginDocumentFrozenResultCurrent(parent.field("host_plan").getOrThrow(),agentUtcMillis())){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            for(intent in intents){match(pluginDocumentChildArguments(parent,httpIntentText(intent,"id"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            // Download and explicitly release the pure cache before waiting for
            // approval. Host files, refs and the final plan survive a restart.
            let reply=match(exchange(phase("release"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(accepted(reply,"released")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};released=true;session.acknowledgeWorkerRelease()
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            // Reject an invalid/unowned control before durable preparatory GC pins
            // exist for this parent. Its strict rejection path grants no execution.
            match(freezeHostDocumentPreparation(context,call,parent,proposed.field("user_control"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(host.commitDocumentEffect(namespace,generation,configuration.packageDigest,{=>
                for(index in 0..proposals.size where httpIntentText(proposals[index],"mode")=="compare_exchange"){
                    let selected=pluginDocumentChildArguments(parent,httpIntentText(intents[index],"id")).value().getOrThrow()
                    let writer=outputWriters[httpIntentText(proposals[index],"next_slot")]
                    match(session.retainReplacement(links[0],selected,writer,{=>currentData()})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
                session.retainResult(links[0],parent,outputWriters[resultSlot],{=>currentData()})})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            Result.Ok(parent)
        }finally{
            if(!released){
                // Cleanup has no second computation deadline. If the original
                // release cannot ACK, the retained exact process is aborted.
                match(exchange(phase("release"))){case Result.Ok(value)=>
                    if(accepted(value,"released").isOk()){session.acknowledgeWorkerRelease()}
                    case Result.Err(_)=>()}
            }
        }
    }
}

public func hostDocumentDataNibble(value:Byte):Int64{
    if(value>=b'0' && value<=b'9'){return Int64(value-b'0')}
    if(value>=b'a' && value<=b'f'){return Int64(value-b'a')+10}
    throw IllegalArgumentException("canonical lowercase output hex required")
}
public func hostDocumentDataReference(writer:HostServiceArtifactWriter):AgentValue{
    let value=writer.completedArtifact()
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("artifact_ref",textValue(value.reference)),
        ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(value.bytes)),ValueField("sha256",textValue(value.sha256)),
        ValueField("content_type",textValue(value.contentType))])
}
