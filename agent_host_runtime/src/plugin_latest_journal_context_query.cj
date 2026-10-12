package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

// No business schema or provider name is selected here. The trusted Product
// caller supplies its current frozen operator selection, two independently
// permitted typed providers and the actual completed ContextRead fact.
class HostPreparedJournalContextTransfer {
    private let schema:String
    private let sequence:Int64
    private let writer:HostServiceArtifactWriter
    private let current:()->Result<Unit>
    private var loan:?HostPluginPureDataLoan=None
    private var completed=false
    init(schema:String,sequence:Int64,writer:HostServiceArtifactWriter,current:()->Result<Unit>){
        this.schema=schema;this.sequence=sequence;this.writer=writer;this.current=current}
    func borrow(actual:HostPluginPureDataLoan,action:()->Result<Unit>):Result<Unit>{
        if(loan.isSome() || completed){return hostPluginResourceError("context.journal_transfer_closed","one actual worker owns this transfer")}
        loan=Some(actual);try{action()}finally{loan=None}
    }
    private func phase(action:String,fields!:Array<ValueField>=[]):AgentValue{
        let result=ArrayList<ValueField>([ValueField("schema",textValue(schema)),ValueField("action",textValue(action)),
            ValueField("sequence",integerValue(sequence))]);result.add(all:fields);objectValue(result.toArray())}
    private func exchange(request:AgentValue,consume:(AgentValue)->Result<Unit>):Result<Unit>{
        if(loan.isNone() || completed){return hostPluginResourceError("context.journal_transfer_closed","no live actual worker loan")}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let reply=match(loan.getOrThrow().exchange(request)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        // No reply DOM/String is returned or saved outside this paid window.
        try{consume(reply.value)}finally{reply.close()}
    }
    private func ack(action:String,fields!:Array<ValueField>=[],name!:String="accepted"):Result<Unit>{
        exchange(phase(action,fields:fields),{value=>
            if(!httpIntentExactFields(value,[name]) || value.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean ||
                !value.field(name).getOrThrow().asBool()){
                return hostPluginResourceError<Unit>("context.journal_transfer_rejected","exact Native transfer acknowledgement required")}
            Result<Unit>.Ok(())})
    }
    func parameters(session:HostDocumentDataSession,parameters:AgentValue,stream:AgentValue):Result<Unit>{
        // Original complete parameters are uploaded before any history byte.
        // Serialization/backing/copies remain charged by the real Session.
        let bytes=match(session.contextParameterUploadBytes(parameters)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(bytes.size<2 || bytes.size>CONTENT_PAYLOAD_MESSAGE_BYTES){
            return hostPluginResourceError("context.journal_parameters_limit","original content-message parameter ceiling exceeded")}
        let description=objectValue([ValueField("bytes",integerValue(bytes.size)),ValueField("sha256",textValue(modelPolicySha256(bytes)))])
        match(ack("begin",fields:[ValueField("input_payload",description),ValueField("stream",stream)])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+65536)
            match(ack("append_input",fields:[ValueField("offset",integerValue(offset)),
                ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[offset..end])))])){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};offset=end}
        ack("finish_input")
    }
    func append(offset:Int64,bytes:Array<Byte>):Result<Unit>{
        ack("append",fields:[ValueField("offset",integerValue(offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes)))])
    }
    private func download(size:Int64,digest:String):Result<Unit>{
        var offset:Int64=0
        while(offset<size){
            // Mutable scalar references do not cross a delayed callback.
            let requested=offset;let progress=HostJournalDownloadProgress()
            match(exchange(phase("download",fields:[ValueField("offset",integerValue(requested)),ValueField("max_bytes",integerValue(16384))]),{value=>
                if(!hostJournalContextChunkValid(value,requested,size)){
                    return hostPluginResourceError<Unit>("context.journal_output_chunk","exact bounded output chunk required")}
                let encoded=httpIntentText(value,"bytes_hex").toArray();let raw=Array<Byte>(encoded.size/2,repeat:0)
                for(index in 0..raw.size){raw[index]=UInt8(hostWindowDocumentDataNibble(encoded[index*2])*16+hostWindowDocumentDataNibble(encoded[index*2+1]))}
                match(writer.appendBytes(requested,raw,size)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                progress.bytes=raw.size;Result<Unit>.Ok(())})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            offset+=progress.bytes
        }
        // The writer was adopted/opened before generation/entry/SQL locks.
        // finish closes only this fd and hashes bytes; it never publishes or
        // acquires ArtifactStore/Runtime/Host metadata locks inside SQL.
        match(writer.finish(size,digest)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        ack("release",name:"released")
    }
    func end(pass:Int64):Result<Bool>{
        let state=HostJournalEndState()
        match(exchange(phase("end",fields:[ValueField("pass",integerValue(pass))]),{value=>
            if(!httpIntentExactFields(value,["ready"]) && !httpIntentExactFields(value,["ready","output"])){
                return hostPluginResourceError<Unit>("context.journal_output_invalid","exact replay completion required")}
            if(value.field("ready").getOrThrow().unifiedKind!=ValueKind.Boolean){
                return hostPluginResourceError<Unit>("context.journal_output_invalid","boolean replay completion required")}
            state.ready=value.field("ready").getOrThrow().asBool()
            if(!state.ready){
                if(!httpIntentExactFields(value,["ready"])){
                    return hostPluginResourceError<Unit>("context.journal_output_invalid","unfinished replay cannot propose output")}
                return Result<Unit>.Ok(())}
            if(!httpIntentExactFields(value,["ready","output"]) || !hostJournalContextOutputValid(value.field("output").getOrThrow())){
                return hostPluginResourceError<Unit>("context.journal_output_invalid","original bounded final context output required")}
            state.bytes=Int64.parse(value.field("output").getOrThrow().field("bytes").getOrThrow().asNumberText())
            state.digest=httpIntentText(value.field("output").getOrThrow(),"sha256");Result<Unit>.Ok(())})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!state.ready){return Result<Bool>.Ok(false)}
        // Only bounded scalar metadata escapes the paid end reply. A later
        // exchange cannot overlap a retained reply from this actual loan.
        match(download(state.bytes,state.digest)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        completed=true;Result<Bool>.Ok(true)
    }
}
class HostJournalDownloadProgress {var bytes:Int64=0}
class HostJournalEndState {var ready=false;var bytes:Int64=0;var digest=""}

func hostJournalContextOutputValid(value:AgentValue):Bool{
    if(!httpIntentExactFields(value,["bytes","sha256"]) || value.field("bytes").getOrThrow().unifiedKind!=ValueKind.Number ||
        value.field("sha256").getOrThrow().unifiedKind!=ValueKind.Text || !httpIntentDigest(httpIntentText(value,"sha256"))){return false}
    try{let text=value.field("bytes").getOrThrow().asNumberText();let size=Int64.parse(text)
        size>=1 && size<=RUN_CONTEXT_SNAPSHOT_MAX_BYTES && size.toString()==text}catch(_:Exception){false}
}
func hostJournalContextChunkValid(value:AgentValue,offset:Int64,size:Int64):Bool{
    if(!httpIntentExactFields(value,["offset","bytes_hex","eof"]) || value.field("offset").getOrThrow().unifiedKind!=ValueKind.Number ||
        value.field("offset").getOrThrow().asNumberText()!=offset.toString() || value.field("bytes_hex").getOrThrow().unifiedKind!=ValueKind.Text ||
        value.field("eof").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
    let hex=httpIntentText(value,"bytes_hex")
    if(hex.size<2 || hex.size%2!=0 || hex.size>32768 || hex.size/2>size-offset ||
        value.field("eof").getOrThrow().asBool()!=(offset+hex.size/2==size)){return false}
    for(byte in hex.toArray() where !((byte>=b'0' && byte<=b'9') || (byte>=b'a' && byte<=b'f'))){return false};true
}

public func runPreparedLatestJournalContext(host:HostJavaScriptPluginHost,
    readConfiguration:HostPluginDocumentJournalReadConfiguration,computeConfiguration:HostPluginDocumentJournalReadConfiguration,
    generation:UInt64,context:ToolInvocationContext,requestId:String,link:ContextReadFactLink,binding:AgentValue,
    request:AgentValue,data:AgentValue,parameters:AgentValue,dataSchema:String,validity:()->Result<Unit>):Result<HostContextWindowQueryOutput>{
    if(!readConfiguration.contextRead || !computeConfiguration.contextRead || dataSchema=="" || dataSchema.size>128 || dataSchema.contains("\u{0000}") ||
        readConfiguration.namespace!=computeConfiguration.namespace || readConfiguration.packageDigest!=computeConfiguration.packageDigest ||
        !pluginDocumentContextLatestJournalStreamReadRequestValid(request) || canonicalAgentValue(request.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
        !pluginDocumentContextLatestJournalStreamReadResultValid(data,request) || parameters.unifiedKind!=ValueKind.Object ||
        parameters.field(CONTEXT_READ_INPUT_FIELD).isSome() || parameters.field("_axyndra_context_provider").isSome()){
        return hostPluginResourceError("context.journal_scope_invalid","strict actual parentless read and frozen parameters required")}
    let key=httpIntentText(request,"key")
    if(!computeConfiguration.permits(key) || computeConfiguration.access(key).isNone() || computeConfiguration.view(key).isNone() ||
        computeConfiguration.access(key).getOrThrow().digest!=httpIntentText(request,"access_policy_digest") ||
        computeConfiguration.view(key).getOrThrow().digest!=httpIntentText(request,"view_policy_digest")){
        return hostPluginResourceError("context.journal_rights_denied","final actual provider lacks this same original scoped journal purpose")}
    let fullCurrent={=>
        match(validity()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(hostLatestJournalPreparationCurrent(host,readConfiguration,generation,context,request)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(computeConfiguration.validateCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        let actual=match(host.contentProviderBinding(computeConfiguration.namespace,computeConfiguration.provider,false)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
        if(actual.generation!=generation || actual.digest!=computeConfiguration.packageDigest){
            return hostPluginResourceError<Unit>("context.journal_provider_changed","actual final typed provider changed")}
        Result<Unit>.Ok(())}
    let localCurrent={=>
        if(context.cancellation.isCancelled() || (context.budget.deadlineMillis>0 && agentUtcMillis()>=context.budget.deadlineMillis)){
            return hostPluginResourceError<Unit>("context.journal_cancelled","actual caller was cancelled or expired")}
        match(readConfiguration.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        computeConfiguration.validateTransferWitness()}
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let sequence=match(host.allocateDocumentDataSequence()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let value=match(session.run({owner=>
        let writer=match(owner.newWriter()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        let transfer=HostPreparedJournalContextTransfer(dataSchema,sequence,writer,localCurrent)
        let reader=match(owner.createLatestJournalInput(link,binding,data,localCurrent,
            {offset,bytes=>transfer.append(offset,bytes)},{pass=>transfer.end(pass)})){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        let fields=ArrayList<ValueField>()
        for(field in parameters.fields){fields.add(field)}
        fields.add(ValueField("_axyndra_context_provider",objectValue([ValueField("namespace",textValue(computeConfiguration.namespace)),
            ValueField("package_digest",textValue(computeConfiguration.packageDigest)),ValueField("generation",textValue(generation.toString())),
            ValueField("provider",textValue(computeConfiguration.provider))])))
        let actualParameters=objectValue(fields.toArray())
        let document=data.field("documents").getOrThrow().items[0]
        let stream=objectValue([ValueField("reference",document.field("stream").getOrThrow()),
            ValueField("request_digest",textValue(httpIntentText(data,"request_digest"))),
            ValueField("access_policy_digest",request.field("access_policy_digest").getOrThrow()),ValueField("view_policy_digest",request.field("view_policy_digest").getOrThrow())])
        let cancellationDeadline=context.cancellation.deadlineMillis;let budgetDeadline=context.budget.deadlineMillis
        let absolute=if(cancellationDeadline==0){budgetDeadline}else{if(budgetDeadline==0){cancellationDeadline}else{min(cancellationDeadline,budgetDeadline)}}
        let unbounded=absolute==0;let remaining=if(unbounded){5000}else{absolute-agentUtcMillis()}
        if(remaining<1){return hostPluginResourceError<AgentValue>("context.journal_cancelled","actual caller deadline expired")}
        let deadline=MonoTime.now()+Duration.millisecond*remaining
        match(host.withPureDocumentDataLoan(computeConfiguration,generation,context,requestId,deadline,owner,localCurrent,fullCurrent,
            {actual=>transfer.borrow(actual,{=>
                match(transfer.parameters(owner,actualParameters,stream)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                reader.read()})},callerUnbounded:unbounded)){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        // FD EOF/hash/ACK, same-TX private fence, current generation checks and
        // physical worker release have all completed. Never query a closed
        // worker or publish the private final writer as a new read grant.
        match(fullCurrent()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        owner.readPrivateContextValue(writer,RUN_CONTEXT_SNAPSHOT_MAX_BYTES,fullCurrent)
    })){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    Result.Ok(HostContextWindowQueryOutput(value,session))
}
