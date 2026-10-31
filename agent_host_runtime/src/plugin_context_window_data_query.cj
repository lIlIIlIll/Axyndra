package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

// The value is inert provider data. Its decoded allocation remains in the
// existing retained session until the trusted consumer acknowledges it.
public class HostContextWindowQueryOutput {
    public let value:AgentValue
    private let owner:HostDocumentDataSession
    init(value:AgentValue,owner:HostDocumentDataSession){this.value=value;this.owner=owner}
    public func close():Result<Unit>{owner.acknowledgeOutput();owner.close()}
}

class HostContextWindowDataQuery {
    private let host:HostJavaScriptPluginHost
    private let configuration:HostPluginDocumentContextWindowConfiguration
    private let context:ToolInvocationContext
    private let binding:AgentValue
    private let provider:String
    private let input:AgentValue
    private let links:Array<ContextReadFactLink>
    private let dataList:AgentValue
    private let requestId:String
    private let sequence:Int64
    private let started:MonoTime
    private let validity:()->Result<Unit>
    private let sourceDigest:String
    private var scope:?HostContextWindowDataScope=None
    init(host:HostJavaScriptPluginHost,configuration:HostPluginDocumentContextWindowConfiguration,
        context:ToolInvocationContext,binding:AgentValue,provider:String,input:AgentValue,
        links:Array<ContextReadFactLink>,dataList:AgentValue,requestId:String,sequence:Int64,validity:()->Result<Unit>){
        this.host=host;this.configuration=configuration;this.context=context;this.binding=binding;this.provider=provider
        this.input=input;this.links=links;this.dataList=dataList;this.requestId=requestId;this.sequence=sequence;this.validity=validity
        started=MonoTime.now()
        sourceDigest=modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("binding",binding),ValueField("input",input)])))
    }
    private func localCurrent():Result<Unit>{
        if(context.cancellation.isCancelled() || (MonoTime.now()-started).toMilliseconds()>=5000 ||
            context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
            context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
            return hostPluginResourceError("context.document_query_scope","pure context query lost its original caller or deadline")}
        configuration.validateCurrent()
    }
    private func fullCurrent():Result<Unit>{
        match(validity()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDocumentContextWindowPreparationCurrent(host,configuration,UInt64.parse(httpIntentText(binding,"generation")),context,binding)
    }
    private func phase(action:String,fields!:Array<ValueField> = []):AgentValue{
        let values=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.document-data-query/v2")),
            ValueField("action",textValue(action)),ValueField("sequence",integerValue(sequence)),ValueField("source_digest",textValue(sourceDigest))])
        values.add(all:fields);objectValue(values.toArray())
    }
    private func exchange(value:AgentValue):Result<AgentValue>{
        scope.getOrThrow().exchange(value,checkpoint:["begin","compute","release"].contains(httpIntentText(value,"action")))
    }
    private func accepted(value:AgentValue,name:String):Result<Unit>{
        if(!httpIntentExactFields(value,[name]) || value.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean ||
            !value.field(name).getOrThrow().asBool()){
            return hostPluginResourceError("context.document_query_rejected","typed context worker did not acknowledge the exact transfer")}
        Result.Ok(())
    }
    private func download(session:HostDocumentDataSession,description:AgentValue):Result<HostServiceArtifactWriter>{
        let id=httpIntentText(description,"id");let size=Int64.parse(description.field("bytes").getOrThrow().asNumberText())
        let writer=match(session.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        var offset:Int64=0
        while(true){
            let reply=match(exchange(phase("read",fields:[ValueField("id",textValue(id)),ValueField("offset",integerValue(offset)),
                ValueField("max_bytes",integerValue(65536))]))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!httpIntentExactFields(reply,["offset","bytes_hex","eof"]) || reply.field("offset").getOrThrow().unifiedKind!=ValueKind.Number ||
                reply.field("offset").getOrThrow().asNumberText()!=offset.toString() || reply.field("bytes_hex").getOrThrow().unifiedKind!=ValueKind.Text ||
                reply.field("eof").getOrThrow().unifiedKind!=ValueKind.Boolean){
                return hostPluginResourceError("context.document_query_chunk","typed context output chunk is malformed")}
            let text=httpIntentText(reply,"bytes_hex")
            if(text.size<2 || text.size%2!=0 || text.size>131072 || text.size/2>size-offset){
                return hostPluginResourceError("context.document_query_chunk","typed context chunk exceeds its exact declared bytes")}
            let raw=Array<Byte>(text.size/2,repeat:0);let hex=text.toArray()
            for(index in 0..raw.size){raw[index]=UInt8(hostWindowDocumentDataNibble(hex[index*2])*16+hostWindowDocumentDataNibble(hex[index*2+1]))}
            var piece:Int64=0
            while(piece<raw.size){let end=min(raw.size,piece+16384)
                match(writer.appendBytes(offset+piece,raw[piece..end],size)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};piece=end}
            offset+=raw.size
            if(reply.field("eof").getOrThrow().asBool()){
                if(offset!=size){return hostPluginResourceError("context.document_query_incomplete","typed context output ended before its complete declaration")};break}
            if(offset==size){return hostPluginResourceError("context.document_query_incomplete","typed context output omitted its terminal")}
        }
        match(writer.finish(size,httpIntentText(description,"sha256"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(writer)
    }
    func run(session:HostDocumentDataSession,complete:Bool):Result<AgentValue>{
        let selected=HostContextWindowDataScope(host,configuration,provider,UInt64.parse(httpIntentText(binding,"generation")),
            ThreadId(context.sessionId.value),context.cancellation,context.budget.processLimits,requestId,
            started+Duration.second*5,{=>localCurrent()},{=>fullCurrent()})
        scope=Some(selected)
        try{selected.run(session,{_=>body(session,complete)})}finally{scope=None}
    }
    private func body(session:HostDocumentDataSession,complete:Bool):Result<AgentValue>{
        if(!pluginDocumentContextBindingValid(binding) || links.isEmpty() || links.size>8 ||
            validateContextReadInputProjection(input,links).isError() || dataList.unifiedKind!=ValueKind.List || dataList.items.size!=links.size){
            return hostPluginResourceError("context.document_fact_invalid","typed context input requires its full original ordered fact projection")}
        match(scope.getOrThrow().validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let generation=UInt64.parse(httpIntentText(binding,"generation"))
        // Generation -> artifact -> existing Store transaction. The supplied
        // current callback is file/atomic-only and cannot acquire Host locks.
        match(host.commitDocumentEffect(configuration.namespace,generation,configuration.packageDigest,{=>
            if(complete){session.authorizeWindows(links,binding,dataList,{=>localCurrent()})}
            else{session.authorizeWindowPrefix(links,binding,dataList,{=>localCurrent()})}})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let descriptions=ArrayList<AgentValue>()
        for(index in 0..dataList.items.size){
            let item=dataList.items[index].field("documents").getOrThrow().items[0]
            let ref=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
            descriptions.add(objectValue([ValueField("id",textValue("read-"+index.toString())),ValueField("bytes",integerValue(ref.bytes)),ValueField("sha256",textValue(ref.digest))]))}
        let encoded=match(session.parameterUploadBytes(input)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let parameter=objectValue([ValueField("bytes",integerValue(encoded.size)),ValueField("sha256",textValue(modelPolicySha256(encoded)))])
        let beginning=match(exchange(phase("begin",fields:[ValueField("tool",textValue(provider)),ValueField("input_payload",parameter),
            ValueField("documents",listValue(descriptions.toArray()))]))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(accepted(beginning,"accepted")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        var released=false
        try{
            var offset:Int64=0
            while(offset<encoded.size){let end=min(encoded.size,offset+65536)
                let reply=match(exchange(phase("append_input",fields:[ValueField("offset",integerValue(offset)),
                    ValueField("bytes_hex",textValue(logicalJsonEncodeHex(encoded[offset..end])))]))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                match(accepted(reply,"accepted")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};offset=end}
            for(index in 0..dataList.items.size){
                let ref=parsePluginDocumentPayloadReference(dataList.items[index].field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
                match(session.upload(ref,{=>scope.getOrThrow().current()},{offset,bytes=>
                    let reply=match(exchange(phase("append",fields:[ValueField("id",textValue("read-"+index.toString())),
                        ValueField("offset",integerValue(offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes)))]))){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    accepted(reply,"accepted")})){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            let proposed=match(exchange(phase("compute"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!httpIntentExactFields(proposed,["outputs","result_slot"]) || proposed.field("outputs").getOrThrow().unifiedKind!=ValueKind.List ||
                proposed.field("outputs").getOrThrow().items.size!=1 || httpIntentText(proposed,"result_slot")!="result"){
                return hostPluginResourceError("context.document_result_invalid","typed context query may return one inert output only")}
            let description=proposed.field("outputs").getOrThrow().items[0]
            if(!httpIntentExactFields(description,["id","bytes","sha256"]) || httpIntentText(description,"id")!="result" ||
                description.field("bytes").getOrThrow().unifiedKind!=ValueKind.Number || !httpIntentDigest(httpIntentText(description,"sha256"))){
                return hostPluginResourceError("context.document_result_invalid","typed context output declaration is malformed")}
            let maximum=if(complete){RUN_CONTEXT_SNAPSHOT_MAX_BYTES}else{16384}
            let size=Int64.parse(description.field("bytes").getOrThrow().asNumberText())
            if(size<1 || size>maximum || size.toString()!=description.field("bytes").getOrThrow().asNumberText()){
                return hostPluginResourceError("context.document_result_limit","typed context output exceeds its original bound")}
            let writer=match(download(session,description)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let reply=match(exchange(phase("release"))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(accepted(reply,"released")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            released=true
            match(scope.getOrThrow().validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            session.readPrivateContextValue(writer,maximum,{=>scope.getOrThrow().validate()})
        }finally{
            if(!released){match(exchange(phase("release"))){case Result.Ok(reply)=>
                let _=accepted(reply,"released");case Result.Err(_)=>()}}
        }
    }
}

func queryDocumentContextWindowData(host:HostJavaScriptPluginHost,configuration:HostPluginDocumentContextWindowConfiguration,
    context:ToolInvocationContext,binding:AgentValue,provider:String,input:AgentValue,links:Array<ContextReadFactLink>,
    dataList:AgentValue,requestId:String,validity:()->Result<Unit>,complete:Bool):Result<HostContextWindowQueryOutput>{
    let sequence=match(host.allocateDocumentDataSequence()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let query=try{HostContextWindowDataQuery(host,configuration,context,binding,provider,input,links,dataList,requestId,sequence,validity)}
        catch(_:Exception){
            // The Host already retained this actual owner. Close also marks
            // it terminal so failed cleanup can be collected on that owner.
            match(session.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            return hostPluginResourceError("context.document_query_invalid","pure context parameters could not be frozen")}
    let value=match(session.run({owner=>query.run(owner,complete)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    Result.Ok(HostContextWindowQueryOutput(value,session))
}

public func hostQueryDocumentContextWindowPrefix(host:HostJavaScriptPluginHost,configuration:HostPluginDocumentContextWindowConfiguration,
    context:ToolInvocationContext,binding:AgentValue,input:AgentValue,links:Array<ContextReadFactLink>,dataList:AgentValue,
    requestId:String,validity:()->Result<Unit>):Result<HostContextWindowQueryOutput>{
    queryDocumentContextWindowData(host,configuration,context,binding,configuration.provider,input,links,dataList,requestId,validity,false)
}
public func hostQueryDocumentContextWindowFinal(host:HostJavaScriptPluginHost,configuration:HostPluginDocumentContextWindowConfiguration,
    context:ToolInvocationContext,binding:AgentValue,provider:String,input:AgentValue,links:Array<ContextReadFactLink>,dataList:AgentValue,
    requestId:String,validity:()->Result<Unit>):Result<HostContextWindowQueryOutput>{
    queryDocumentContextWindowData(host,configuration,context,binding,provider,input,links,dataList,requestId,validity,true)
}
