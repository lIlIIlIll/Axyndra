package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.io.*
import std.sync.*
import std.time.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

let MEMORY_LIVE_TOOL_DATA_SCHEMA="axyndra.memory-live-tool-data/v1"
let MEMORY_LIVE_TOOL_SLOT_BYTES:Int64=8388608
let MEMORY_LIVE_TOOL_INPUT_BYTES:Int64=8388608

func memoryLiveInvalid(message:String):Nothing{
    throw PureProviderError("memory.live_data_invalid",message)
}
func memoryLiveAdd(left:Int64,right:Int64):Int64{
    if(left<0 || right<0 || left>Int64.Max-right){memoryLiveInvalid("Int63 extent overflow")};left+right
}
func memoryLiveMul(value:Int64,factor:Int64):Int64{
    if(value<0 || factor<1 || value>Int64.Max/factor){memoryLiveInvalid("allocation extent overflow")};value*factor
}
func memoryLiveHex(value:String):Array<Byte>{
    if(value.isEmpty() || value.size%2!=0 || value.size>131072){memoryLiveInvalid("one complete nonempty64KiB lowercase hexadecimal chunk required")}
    let bytes=Array<Byte>(value.size/2,repeat:0)
    for(index in 0..bytes.size){bytes[index]=UInt8(documentDataNibble(value[index*2])*16+documentDataNibble(value[index*2+1]))};bytes
}
func memoryLiveAccepted():AgentValue{objectValue([ValueField("accepted",boolValue(true))])}

// Exact full AgentError data. The six durable fields retain their existing
// spelling; both typed optional attachments are explicit null or full values.
// This is never a Receipt/authority; only the original append consumes it.
func memoryLiveErrorKind(value:String):AgentErrorKind{
    match(value){
        case "configuration"=>AgentErrorKind.Configuration
        case "authentication"=>AgentErrorKind.Authentication
        case "permission_denied"=>AgentErrorKind.PermissionDenied
        case "invalid_input"=>AgentErrorKind.InvalidInput
        case "rate_limited"=>AgentErrorKind.RateLimited
        case "timeout"=>AgentErrorKind.Timeout
        case "transport"=>AgentErrorKind.Transport
        case "provider"=>AgentErrorKind.Provider
        case "protocol"=>AgentErrorKind.Protocol
        case "cancelled"=>AgentErrorKind.Cancelled
        case "budget_exceeded"=>AgentErrorKind.BudgetExceeded
        case "conflict"=>AgentErrorKind.Conflict
        case "recovery_required"=>AgentErrorKind.RecoveryRequired
        case "internal"=>AgentErrorKind.Internal
        case _=>memoryLiveInvalid("unknown original error kind")
    }
}
func memoryLiveErrorName(value:AgentErrorKind):String{
    match(value){
        case AgentErrorKind.Configuration=>"configuration"
        case AgentErrorKind.Authentication=>"authentication"
        case AgentErrorKind.PermissionDenied=>"permission_denied"
        case AgentErrorKind.InvalidInput=>"invalid_input"
        case AgentErrorKind.RateLimited=>"rate_limited"
        case AgentErrorKind.Timeout=>"timeout"
        case AgentErrorKind.Transport=>"transport"
        case AgentErrorKind.Provider=>"provider"
        case AgentErrorKind.Protocol=>"protocol"
        case AgentErrorKind.Cancelled=>"cancelled"
        case AgentErrorKind.BudgetExceeded=>"budget_exceeded"
        case AgentErrorKind.Conflict=>"conflict"
        case AgentErrorKind.RecoveryRequired=>"recovery_required"
        case AgentErrorKind.Internal=>"internal"
    }
}
func memoryLiveErrorFrom(value:AgentValue):?AgentError{
    if(value.unifiedKind==ValueKind.Null){return None}
    memoryDocumentFields(value,["kind","code","message","retryable","fallback_allowed","fields","attempt_failure","observation"])
    let fields=value.field("fields").getOrThrow()
    if(fields.unifiedKind!=ValueKind.List || value.field("retryable").getOrThrow().unifiedKind!=ValueKind.Boolean ||
        value.field("fallback_allowed").getOrThrow().unifiedKind!=ValueKind.Boolean){memoryLiveInvalid("complete typed error fields required")}
    let decoded=ArrayList<ErrorField>()
    for(field in fields.items){memoryDocumentFields(field,["name","value"])
        decoded.add(ErrorField(memoryDocumentText(field,"name"),memoryDocumentText(field,"value")))}
    Some(AgentError(memoryLiveErrorKind(memoryDocumentText(value,"kind")),memoryDocumentText(value,"code"),memoryDocumentText(value,"message"),
        retryable:value.field("retryable").getOrThrow().asBool(),fallbackAllowed:value.field("fallback_allowed").getOrThrow().asBool(),fields:decoded.toArray(),attemptFailure:memoryLiveFailureFrom(value.field("attempt_failure").getOrThrow()),
        observation:memoryLiveObservationFrom(value.field("observation").getOrThrow())))
}
func memoryLiveErrorValue(error:AgentError):AgentValue{
    objectValue([ValueField("kind",textValue(memoryLiveErrorName(error.kind))),ValueField("code",textValue(error.code)),
        ValueField("message",textValue(error.message)),ValueField("retryable",boolValue(error.retryable)),
        ValueField("fallback_allowed",boolValue(error.fallbackAllowed)),ValueField("fields",listValue(error.fields.map{field=>
            objectValue([ValueField("name",textValue(field.name)),ValueField("value",textValue(field.value))])})),
        ValueField("attempt_failure",match(error.attemptFailure){case Some(value)=>memoryLiveFailureValue(value);case None=>nullValue()}),
        ValueField("observation",match(error.observation){case Some(value)=>value.toValue();case None=>nullValue()})])
}

// Exact model-facing original tool_runtime.recoverableToolResult output.
// The full receipt error remains separately retained in the replay prefix.
func memoryLiveRecoverableOutput(error:AgentError):AgentValue{
    objectValue([ValueField("error",textValue(error.code)),ValueField("error_kind",textValue(memoryLiveErrorName(error.kind))),
        ValueField("message",textValue(error.message)),ValueField("retryable",boolValue(error.retryable)),
        ValueField("fields",listValue(error.fields.map{field=>objectValue([
            ValueField("name",textValue(field.name)),ValueField("value",textValue(field.value))])}))])
}

func memoryLiveFailureKindName(value:AttemptFailureKind):String{
    match(value){
        case AttemptFailureKind.ConnectTimeout=>"connect_timeout"
        case AttemptFailureKind.FirstResponseTimeout=>"first_response_timeout"
        case AttemptFailureKind.StreamIdleTimeout=>"stream_idle_timeout"
        case AttemptFailureKind.AttemptSoftDeadlineExceeded=>"attempt_soft_deadline_exceeded"
        case AttemptFailureKind.AttemptHardDeadlineExceeded=>"attempt_hard_deadline_exceeded"
        case AttemptFailureKind.DecisionIncompleteAtDeadline=>"decision_incomplete_at_deadline"
        case AttemptFailureKind.ProviderTerminalMissing=>"provider_terminal_missing"
        case AttemptFailureKind.ProtocolIncomplete=>"protocol_incomplete"
        case AttemptFailureKind.OutputLimited=>"output_limited"
        case AttemptFailureKind.OutputLimitedBeforeDecision=>"output_limited_before_decision"
        case AttemptFailureKind.ProviderTransportError=>"provider_transport_error"
        case AttemptFailureKind.ProviderProtocolError=>"provider_protocol_error"
        case AttemptFailureKind.MalformedToolArguments=>"malformed_tool_arguments"
        case AttemptFailureKind.UserCancelled=>"user_cancelled"
        case AttemptFailureKind.RunDeadlineExceeded=>"run_deadline_exceeded"
    }
}
func memoryLiveFailureKindFrom(value:String):AttemptFailureKind{
    match(value){
        case "connect_timeout"=>AttemptFailureKind.ConnectTimeout
        case "first_response_timeout"=>AttemptFailureKind.FirstResponseTimeout
        case "stream_idle_timeout"=>AttemptFailureKind.StreamIdleTimeout
        case "attempt_soft_deadline_exceeded"=>AttemptFailureKind.AttemptSoftDeadlineExceeded
        case "attempt_hard_deadline_exceeded"=>AttemptFailureKind.AttemptHardDeadlineExceeded
        case "decision_incomplete_at_deadline"=>AttemptFailureKind.DecisionIncompleteAtDeadline
        case "provider_terminal_missing"=>AttemptFailureKind.ProviderTerminalMissing
        case "protocol_incomplete"=>AttemptFailureKind.ProtocolIncomplete
        case "output_limited"=>AttemptFailureKind.OutputLimited
        case "output_limited_before_decision"=>AttemptFailureKind.OutputLimitedBeforeDecision
        case "provider_transport_error"=>AttemptFailureKind.ProviderTransportError
        case "provider_protocol_error"=>AttemptFailureKind.ProviderProtocolError
        case "malformed_tool_arguments"=>AttemptFailureKind.MalformedToolArguments
        case "user_cancelled"=>AttemptFailureKind.UserCancelled
        case "run_deadline_exceeded"=>AttemptFailureKind.RunDeadlineExceeded
        case _=>memoryLiveInvalid("unknown typed failure/progress kind")
    }
}
func memoryLiveProgressKindName(value:AttemptProgressKind):String{
    match(value){
        case AttemptProgressKind.NoProgress=>"no_progress"
        case AttemptProgressKind.ReasoningProgress=>"reasoning_progress"
        case AttemptProgressKind.TextProgress=>"text_progress"
        case AttemptProgressKind.ToolCallStartedProgress=>"tool_call_started_progress"
        case AttemptProgressKind.ToolArgumentProgress=>"tool_argument_progress"
        case AttemptProgressKind.ContentBlockCompletedProgress=>"content_block_completed_progress"
        case AttemptProgressKind.ProviderTerminalProgress=>"provider_terminal_progress"
    }
}
func memoryLiveProgressKindFrom(value:String):AttemptProgressKind{
    match(value){
        case "no_progress"=>AttemptProgressKind.NoProgress
        case "reasoning_progress"=>AttemptProgressKind.ReasoningProgress
        case "text_progress"=>AttemptProgressKind.TextProgress
        case "tool_call_started_progress"=>AttemptProgressKind.ToolCallStartedProgress
        case "tool_argument_progress"=>AttemptProgressKind.ToolArgumentProgress
        case "content_block_completed_progress"=>AttemptProgressKind.ContentBlockCompletedProgress
        case "provider_terminal_progress"=>AttemptProgressKind.ProviderTerminalProgress
        case _=>memoryLiveInvalid("unknown typed failure/progress kind")
    }
}
func memoryLiveBool(value:AgentValue,name:String):Bool{
    let item=value.field(name).getOrThrow();if(item.unifiedKind!=ValueKind.Boolean){memoryLiveInvalid("typed boolean required")};item.asBool()
}
func memoryLiveObservationFrom(value:AgentValue):?OperationObservation{
    if(value.unifiedKind==ValueKind.Null){return None}
    memoryDocumentFields(value,["schema","trust","authorizes_effects","content"])
    if(memoryDocumentText(value,"schema")!="axyndra.operation-observation/v1" || memoryDocumentText(value,"trust")!="untrusted_data" ||
        memoryLiveBool(value,"authorizes_effects")){memoryLiveInvalid("observation cannot become effect authority")}
    Some(OperationObservation(stringifyUnifiedJson(value.field("content").getOrThrow())))
}
func memoryLiveFailureFrom(value:AgentValue):?AttemptFailure{
    if(value.unifiedKind==ValueKind.Null){return None};memoryDocumentFields(value,["kind","diagnostics"])
    let data=value.field("diagnostics").getOrThrow()
    memoryDocumentFields(data,["elapsed_millis","soft_deadline_millis","hard_deadline_millis","entered_completion_grace","last_progress_kind",
        "last_progress_age_millis","provider_terminal_observed","open_content_block_count","tool_calls_started","tool_calls_completed"])
    Some(AttemptFailure(memoryLiveFailureKindFrom(memoryDocumentText(value,"kind")),diagnostics:AttemptFailureDiagnostics(
        elapsedMillis:documentDataInteger(data,"elapsed_millis"),softDeadlineMillis:documentDataInteger(data,"soft_deadline_millis"),
        hardDeadlineMillis:documentDataInteger(data,"hard_deadline_millis"),enteredCompletionGrace:memoryLiveBool(data,"entered_completion_grace"),
        lastProgressKind:memoryLiveProgressKindFrom(memoryDocumentText(data,"last_progress_kind")),lastProgressAgeMillis:documentDataInteger(data,"last_progress_age_millis"),
        providerTerminalObserved:memoryLiveBool(data,"provider_terminal_observed"),openContentBlockCount:documentDataInteger(data,"open_content_block_count"),
        toolCallsStarted:documentDataInteger(data,"tool_calls_started"),toolCallsCompleted:documentDataInteger(data,"tool_calls_completed"))))
}
func memoryLiveFailureValue(value:AttemptFailure):AgentValue{
    let data=value.diagnostics
    objectValue([ValueField("kind",textValue(memoryLiveFailureKindName(value.kind))),ValueField("diagnostics",objectValue([
        ValueField("elapsed_millis",integerValue(data.elapsedMillis)),ValueField("soft_deadline_millis",integerValue(data.softDeadlineMillis)),
        ValueField("hard_deadline_millis",integerValue(data.hardDeadlineMillis)),ValueField("entered_completion_grace",boolValue(data.enteredCompletionGrace)),
        ValueField("last_progress_kind",textValue(memoryLiveProgressKindName(data.lastProgressKind))),ValueField("last_progress_age_millis",integerValue(data.lastProgressAgeMillis)),
        ValueField("provider_terminal_observed",boolValue(data.providerTerminalObserved)),ValueField("open_content_block_count",integerValue(data.openContentBlockCount)),
        ValueField("tool_calls_started",integerValue(data.toolCallsStarted)),ValueField("tool_calls_completed",integerValue(data.toolCallsCompleted))]))])
}

// Allocation accounting only, not a JSON parser. The ORIGINAL parser below
// still checks complete UTF8/duplicate keys/depth/EOF. No message node cap is
// imposed on a full proposal merely because it crossed transport fragments.
func memoryLiveLexicalNodes(source:String):Int64{
    var quoted=false;var escaped=false;var scalar=false;var nodes:Int64=0
    for(index in 0..source.size){let byte=source[index]
        if(quoted){if(escaped){escaped=false}else if(byte==b'\\'){escaped=true}else if(byte==b'"'){quoted=false}}
        else if(byte==b'"'){quoted=true;scalar=false;nodes=memoryLiveAdd(nodes,1)}
        else if(byte==b'{' || byte==b'['){scalar=false;nodes=memoryLiveAdd(nodes,1)}
        else if(byte==b',' || byte==b':' || byte==b'}' || byte==b']' || byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n'){scalar=false}
        else if(!scalar){scalar=true;nodes=memoryLiveAdd(nodes,1)}
    };nodes
}

class MemoryLiveSlot {
    let slot:String
    let start:Int64
    let bytes:Int64
    let digest:String
    var downloaded:Int64=0
    var described=false
    init(slot:String,start:Int64,bytes:Int64,digest:String){this.slot=slot;this.start=start;this.bytes=bytes;this.digest=digest}
    func descriptor():AgentValue{objectValue([ValueField("slot",textValue(slot)),ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest))])}
}

// First pass of the original PINNED JSON writer. Only complete hashes,
// lengths and per-reference metadata survive; there is no aggregate8MiB cap.
class MemoryLiveJsonStream <: OutputStream {
    private let current:()->Unit
    private let pay:(Int64)->Unit
    private let slots=ArrayList<MemoryLiveSlot>()
    private let whole=SHA256()
    private var part=SHA256()
    private var count:Int64=0
    private var inPart:Int64=0
    private let requestedStart:Int64
    private let requestedBytes:Int64
    private let selected=ArrayList<Byte>()
    private var ended=false
    init(current:()->Unit,pay:(Int64)->Unit,start!:Int64=0,bytes!:Int64=0){
        this.current=current;this.pay=pay;this.requestedStart=start;this.requestedBytes=bytes}
    public func write(value:Array<Byte>):Unit{
        if(ended){memoryLiveInvalid("JSON output followed EOF")};current()
        var offset:Int64=0
        while(offset<value.size){
            let size=min(65536,min(value.size-offset,MEMORY_LIVE_TOOL_SLOT_BYTES-inPart))
            let bytes=value[offset..offset+size];whole.write(bytes);part.write(bytes)
            let begin=max(count,requestedStart);let end=min(memoryLiveAdd(count,size),memoryLiveAdd(requestedStart,requestedBytes))
            if(begin<end){selected.add(all:bytes[begin-count..end-count])}
            count=memoryLiveAdd(count,size);inPart+=size;offset+=size
            if(inPart==MEMORY_LIVE_TOOL_SLOT_BYTES){finishPart()};current()
        }
    }
    private func finishPart():Unit{
        if(inPart==0){return};pay(memoryLiveMul(slots.size+1,1024))
        slots.add(MemoryLiveSlot("payload-"+slots.size.toString(),count-inPart,inPart,logicalJsonEncodeHex(part.finish())))
        part=SHA256();inPart=0
    }
    public func flush():Unit{current()}
    func finish():(Int64,String,Array<MemoryLiveSlot>,Array<Byte>){
        if(ended){memoryLiveInvalid("JSON stream EOF repeated")};finishPart();ended=true;current()
        (count,logicalJsonEncodeHex(whole.finish()),slots.toArray(),selected.toArray())
    }
}

// Prepay the original writer's largest raw scalar/native escaped temporary,
// traversal and slot metadata. Strings remain owned by the input/turn. This
// performs no JSON serialization and places no aggregate8MiB output limit.
class MemoryLiveWriterPayment {
    private let ancestors=ArrayList<JsonNode>()
    var peak:Int64=0
    var nodes:Int64=0
    private func scalar(value:String):Unit{peak=max(peak,memoryLiveAdd(1048576,memoryLiveMul(value.size,8)))}
    func visit(value:AgentValue):Unit{
        nodes=memoryLiveAdd(nodes,1)
        match(value.unifiedKind){
            case ValueKind.Text=>scalar(value.text)
            case ValueKind.Number=>scalar(value.asNumberText())
            case ValueKind.List | ValueKind.Object=>
                if(ancestors.size>=JsonWriteOptions.defaults.maxDepth){memoryLiveInvalid("original JSON writer depth exceeded")}
                for(parent in ancestors){if(refEq(parent,value)){memoryLiveInvalid("cyclic original JSON output")}}
                ancestors.add(value)
                try{if(value.unifiedKind==ValueKind.List){for(item in value.items){visit(item)}}
                    else{for(field in value.fields){scalar(field.name);visit(field.value)}}}
                finally{ancestors.remove(at:ancestors.size-1)}
            case _=>()
        }
    }
}

// A single real second writer pass, owned by MemoryLiveOutput. There is one
// fixed64KiB publication buffer, not a queue of encoded slots. A subsequent
// exact download offset acknowledges the previous returned slice. The writer
// cannot overwrite that buffer until the consumer has acknowledged its end.
// Only the caller thread runs its current callback; the producer sees a private
// stop flag. close wakes a blocked publisher and JOINS its actual Future before
// the caller may drop the original Node/turn or release any allocation.
class MemoryLiveJsonProducer <: OutputStream {
    private let lock=Mutex()
    private let joining=Mutex()
    private let changed:Condition
    private let stopped=AtomicBool(false)
    private let buffer=Array<Byte>(65536,repeat:0)
    private let slots:Array<MemoryLiveSlot>
    private let expectedBytes:Int64
    private let expectedDigest:String
    private let whole=SHA256()
    private var part=SHA256()
    private var count:Int64=0
    private var partBytes:Int64=0
    private var partIndex:Int64=0
    private var used:Int64=0
    private var publishedStart:Int64=0
    private var publishedBytes:Int64=0
    private var delivered:Int64=0
    private var ready=false
    private var ended=false
    private var exited=false
    private var joined=false
    private var failure:?Exception=None
    private var worker:?Future<Unit>=None
    init(slots:Array<MemoryLiveSlot>,bytes:Int64,digest:String){
        this.slots=slots;this.expectedBytes=bytes;this.expectedDigest=digest
        changed=synchronized(lock){lock.condition()}
    }
    func start(value:AgentValue):Unit{
        // The owner prepays buffer, writer stack/scalar and transport copies
        // before constructing this object. No worker reference escapes.
        lock.lock()
        try{
            if(joined || stopped.load() || worker.isSome()){memoryLiveInvalid("owned producer cannot start twice")}
            worker=Some(spawn {
            try{value.writeJson(this,options:JsonWriteOptions.defaults);finish()}
            catch(error:Exception){lock.lock();try{if(!stopped.load()){failure=Some(error)}}finally{lock.unlock()}}
            finally{lock.lock();try{exited=true;changed.notifyAll()}finally{lock.unlock()}}
            ()
        })}finally{lock.unlock()}
    }
    private func current():Unit{
        if(stopped.load()){memoryLiveInvalid("owned JSON producer was stopped")}
    }
    private func finishPart():Unit{
        if(partBytes==0){return}
        if(partIndex>=slots.size || partBytes!=slots[partIndex].bytes ||
            count-partBytes!=slots[partIndex].start || logicalJsonEncodeHex(part.finish())!=slots[partIndex].digest){
            memoryLiveInvalid("second writer pass differs from its exact reference")}
        partIndex++;partBytes=0;part=SHA256()
    }
    private func publish(final:Bool):Unit{
        current();lock.lock()
        try{
            if(stopped.load() || ready || used<1 || used>65536){memoryLiveInvalid("invalid owned producer publication")}
            publishedStart=count-used;publishedBytes=used;ready=true;ended=final;changed.notifyAll()
            while(ready && !stopped.load()){changed.wait()}
            current();used=0
        }finally{lock.unlock()}
    }
    public func write(value:Array<Byte>):Unit{
        current();var offset:Int64=0
        while(offset<value.size){
            current()
            let size=min(65536-used,min(value.size-offset,MEMORY_LIVE_TOOL_SLOT_BYTES-partBytes))
            if(size<1 || count>expectedBytes-size){memoryLiveInvalid("second writer exceeded its complete original output")}
            let selected=value[offset..offset+size]
            for(index in 0..size){buffer[used+index]=selected[index]}
            whole.write(selected);part.write(selected);used+=size;count+=size;partBytes+=size;offset+=size
            if(partBytes==MEMORY_LIVE_TOOL_SLOT_BYTES){finishPart()}
            // Final bytes remain private until complete writer EOF AND whole
            // hash match. Every earlier reference is checked before its tail.
            if(used==65536 && count<expectedBytes){publish(false)}
        }
    }
    public func flush():Unit{current()}
    private func finish():Unit{
        current();finishPart()
        if(count!=expectedBytes || partIndex!=slots.size || logicalJsonEncodeHex(whole.finish())!=expectedDigest){
            memoryLiveInvalid("second original JSON writer did not reach exact hash and EOF")}
        publish(true)
    }
    func take(offset:Int64,maximum:Int64,current:()->Unit):Array<Byte>{
        current();lock.lock()
        try{
            if(joined || stopped.load() || offset!=delivered || maximum<1 || maximum>65536 || offset>=expectedBytes){
                memoryLiveInvalid("producer download is not its exact next offset")}
            // ACK is a real subsequent request, not merely serializer return.
            // A partial short read keeps the same immutable publication alive.
            if(ready && delivered==publishedStart+publishedBytes){
                if(ended){memoryLiveInvalid("producer EOF cannot be replayed")}
                ready=false;changed.notifyAll()
            }
            while(!ready && failure.isNone() && !exited && !stopped.load()){
                let _=changed.wait(timeout:Duration.millisecond*25)
                lock.unlock();try{current()}finally{lock.lock()}
            }
            match(failure){case Some(error)=>throw error;case None=>()}
            if(stopped.load() || !ready || offset<publishedStart || offset>=publishedStart+publishedBytes){
                memoryLiveInvalid("producer closed before the requested complete slice")}
            let begin=offset-publishedStart;let size=min(maximum,publishedBytes-begin)
            let result=buffer[begin..begin+size].clone();delivered+=size;result
        }finally{lock.unlock()}
    }
    // Internal read-only custody facts; no allocator, source or execution hook.
    func progress():(Int64,Int64,Bool,Bool){
        lock.lock();try{(delivered,if(ready){publishedBytes}else{0},exited,joined)}finally{lock.unlock()}
    }
    func close():Unit{
        joining.lock()
        try{
            let selected:?Future<Unit>
            lock.lock()
            try{if(joined){return};stopped.store(true);changed.notifyAll();selected=worker}
            finally{lock.unlock()}
            // No lock needed by the producer is held across the real join.
            match(selected){case Some(actual)=>actual.get();case None=>lock.lock();try{exited=true}finally{lock.unlock()}}
            lock.lock()
            try{if(!exited){memoryLiveInvalid("producer did not acknowledge actual exit")}
                worker=None;failure=None;ready=false;publishedBytes=0;joined=true}
            finally{lock.unlock()}
        }finally{joining.unlock()}
    }
}

class MemoryLiveOutput {
    private var value:?AgentValue
    private var manifest:?AgentValue=None
    private let turn:NativeMemoryReplayTurn
    private let owner:LogicalJsonOwnerReservation
    private let current:()->Unit
    private var slots:Array<MemoryLiveSlot>=[]
    private var manifestSlot:?MemoryLiveSlot=None
    private var wholeBytes:Int64=0
    private var wholeDigest=""
    private var writerPeak:Int64=1048576
    private var producer:?MemoryLiveJsonProducer=None
    private var described:Int64=0
    private var closed=false
    let kind:String
    let isError:Bool
    let proposalDigest:String
    init(value:AgentValue,turn:NativeMemoryReplayTurn,kind:String,isError:Bool,proposalDigest:String,
        allocate:(Int64)->LogicalJsonOwnerReservation,current:()->Unit){
        this.value=Some(value);this.turn=turn;this.kind=kind;this.isError=isError;this.proposalDigest=proposalDigest;this.current=current
        let retained=allocate(1);this.owner=retained
        try{
            let payment=MemoryLiveWriterPayment();payment.visit(value)
            writerPeak=memoryLiveAdd(payment.peak,memoryLiveAdd(2097152,memoryLiveMul(payment.nodes,512)))
            retained.ensureRetainedPeak(writerPeak)
            let sink=MemoryLiveJsonStream(current,{extra=>retained.ensureRetainedPeak(memoryLiveAdd(writerPeak,extra))})
            value.writeJson(sink,options:JsonWriteOptions.defaults)
            let finished=sink.finish();wholeBytes=finished[0];wholeDigest=finished[1];slots=finished[2]
            let fields=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.memory-live-tool-output/v1")),
                ValueField("kind",textValue(kind)),ValueField("total_bytes",integerValue(wholeBytes)),
                ValueField("sha256",textValue(wholeDigest)),ValueField("payload_count",integerValue(slots.size))])
            if(kind=="effect"){fields.add(ValueField("proposal_digest",textValue(proposalDigest)))}
            let document=objectValue(fields.toArray());manifest=Some(document)
            let text=stringifyUnifiedJson(document)
            if(text.size>16384){memoryLiveInvalid("compact output manifest changed shape")}
            manifestSlot=Some(MemoryLiveSlot("manifest",0,text.size,modelPolicySha256Text(text)))
            current()
        }catch(error:Exception){this.value=None;manifest=None;slots=[];retained.close();throw error}
    }
    func metadata():AgentValue{
        current();let fields=ArrayList<ValueField>([ValueField("kind",textValue(kind)),
            ValueField("manifest",manifestSlot.getOrThrow().descriptor()),ValueField("payload_count",integerValue(slots.size))])
        if(kind=="completed"){fields.add(ValueField("is_error",boolValue(isError)))}
        else{fields.add(ValueField("effect",objectValue([ValueField("kind",textValue("row_journal.append")),ValueField("key",textValue(MEMORY_JOURNAL_KEY))])))}
        objectValue(fields.toArray())
    }
    func describe(offset:Int64,count:Int64):AgentValue{
        current();if(closed || offset!=described || count<1 || count>32 || offset>=slots.size){memoryLiveInvalid("exact bounded descriptor page required")}
        let end=min(slots.size,memoryLiveAdd(offset,count));let values=ArrayList<AgentValue>()
        for(index in offset..end){slots[index].described=true;values.add(slots[index].descriptor())};described=end
        objectValue([ValueField("payloads",listValue(values.toArray())),ValueField("next_offset",integerValue(end)),ValueField("total",integerValue(slots.size))])
    }
    func download(slot:String,offset:Int64,maximum:Int64):AgentValue{
        current();if(closed || maximum<1 || maximum>65536){memoryLiveInvalid("download bound changed")}
        let selected:MemoryLiveSlot
        if(slot=="manifest"){selected=manifestSlot.getOrThrow()}
        else{let found=slots.filter{item=>item.slot==slot};if(found.size!=1 || !found[0].described){memoryLiveInvalid("slot was not actually described")};selected=found[0]}
        if(offset!=selected.downloaded || offset>=selected.bytes){memoryLiveInvalid("download replay, gap or repeated EOF")}
        let size=min(maximum,selected.bytes-offset);let bytes:Array<Byte>
        if(slot=="manifest"){
            let raw=stringifyUnifiedJson(manifest.getOrThrow()).toArray()
            if(raw.size!=selected.bytes || modelPolicySha256(raw)!=selected.digest){memoryLiveInvalid("owned manifest changed")};bytes=raw[offset..offset+size]
        }else{
            if(producer.isNone()){
                if(selected.start+offset!=0){memoryLiveInvalid("payload slots must be consumed in original contiguous order")}
                owner.ensureRetainedPeak(memoryLiveAdd(writerPeak,memoryLiveMul(slots.size,1024)))
                producer=Some(MemoryLiveJsonProducer(slots,wholeBytes,wholeDigest))
                producer.getOrThrow().start(value.getOrThrow())
            }
            bytes=producer.getOrThrow().take(selected.start+offset,size,current)
        }
        current();selected.downloaded+=bytes.size
        objectValue([ValueField("slot",textValue(slot)),ValueField("offset",integerValue(offset)),
            ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes))),ValueField("last",boolValue(selected.downloaded==selected.bytes))])
    }
    func complete():Bool{if(manifestSlot.getOrThrow().downloaded!=manifestSlot.getOrThrow().bytes){return false}
        for(slot in slots where slot.downloaded!=slot.bytes){return false};true}
    func close():Unit{if(!closed){
        // Mark closed only after the actual writer exits. An interrupted join
        // leaves this owner retryable and charged; no synthetic cleanup ACK.
        match(producer){case Some(actual)=>actual.close();case None=>()};producer=None
        value=None;manifest=None;slots=[];manifestSlot=None;turn.close();owner.close();closed=true
    }}
}

// Complete raw readable records only. Projected private history is still
// validated by the original v3 decoder but never turned into invented rows.
// Growing text, builder backing copies, final strings and journal clones are
// prepaid against the SAME real Native pool before retention.
class MemoryLiveHistory {
    let history=ArrayList<MemoryV3Record>()
    let rows=ArrayList<MemoryV3Record>()
    let order=ArrayList<String>()
    private let owner:LogicalJsonOwnerReservation
    private let shared:Bool
    private var frameOwner:?LogicalJsonOwnerReservation=None
    private var frameTextBytes:Int64=0
    private let texts=HashMap<String,StringBuilder>()
    private let offsets=HashMap<String,Int64>()
    private var frameKind=""
    private var frameOrdinal:Int64= -1
    var retained:Int64=1048576
    init(owner:LogicalJsonOwnerReservation,shared!:Bool=false){this.owner=owner;this.shared=shared}
    func pay(extra:Int64):Unit{owner.ensureRetainedPeak(memoryLiveAdd(retained,extra))}
    func text(kind:String,ordinal:Int64,field:String,offset:Int64,value:String):Unit{
        if(frameOrdinal!= -1 && (kind!=frameKind || ordinal!=frameOrdinal)){memoryLiveInvalid("record field crossed its original body")}
        frameKind=kind;frameOrdinal=ordinal
        if(!texts.contains(field)){if(offset!=0){memoryLiveInvalid("record field missing prefix")};texts[field]=StringBuilder();offsets[field]=0}
        if(offset!=offsets[field]){memoryLiveInvalid("record field is not contiguous")}
        if(shared){
            // Persistent bytes are the complete SUM of all independently
            // retained decoded Strings. Current builders, toString and hash
            // input copies are paid separately until this frame is complete.
            retained=memoryLiveAdd(retained,value.size);pay(1048576)
            frameTextBytes=memoryLiveAdd(frameTextBytes,value.size)
            if(frameOwner.isNone()){frameOwner=Some(owner.deriveRetainedLease())}
            frameOwner.getOrThrow().ensureRetainedPeak(memoryLiveAdd(1048576,memoryLiveMul(frameTextBytes,8)))
        }else{retained=memoryLiveAdd(retained,memoryLiveMul(value.size,8));pay(1048576)}
        texts[field].append(value);offsets[field]=memoryLiveAdd(offset,value.size)
    }
    private func field(event:MemoryStreamedEvent,name:String):String{
        match(event.field(name)){case None=>"";case Some(expected)=>
            let actual=if(texts.contains(name)){texts[name].toString()}else{""}
            if(actual.size!=expected.bytes || modelPolicySha256Text(actual)!=expected.digest){memoryLiveInvalid("full original decoded field differs from EOF descriptor")};actual}
    }
    func frame(value:MemoryJournalDecodedFrame):Unit{
        if(frameOrdinal!= -1 && (value.kind!=frameKind || value.ordinal!=frameOrdinal)){memoryLiveInvalid("wrong original record completion")}
        let source=value.event.metadataRecord
        // Charge all original scalar metadata and array/cell clones before
        // the decoder's own body lease retires. No placeholders enter Tools.
        if(shared){
            // Every decoder-created String backing is retained once. Empty
            // and repeated conflict IDs still each occupy a String value cell.
            var metadataBytes:Int64=0
            for(bytes in [source.id.size,source.scope.key.size,source.correctionOf.size,source.replacementId.size,
                source.conflictReason.size,source.deletionReason.size]){metadataBytes=memoryLiveAdd(metadataBytes,bytes)}
            for(id in source.conflictIds){metadataBytes=memoryLiveAdd(metadataBytes,id.size)}
            // Prepay the complete corpus SUM before this first collector clone.
            // Eight simultaneous detached-array layers cover collector, journal,
            // current, search snapshot, fixed Native policy callback, validation
            // current/snapshot and final hits. Each String value cell allows32
            // bytes; Strings/scope are forwarded, not multiplied by eight.
            // The existing8192 covers the eight record/header/order/rank graphs.
            // This is real allocation custody, never a new codec cardinality cap.
            let arrayCells=memoryLiveMul(memoryLiveMul(source.conflictIds.size,32),8)
            retained=memoryLiveAdd(retained,memoryLiveAdd(metadataBytes,memoryLiveAdd(8192,arrayCells)));pay(1048576)
        }else{retained=memoryLiveAdd(retained,memoryLiveAdd(memoryLiveMul(value.bodyBytes,2),8192));pay(1048576)}
        let record=MemoryV3Record(source.id,source.kind,source.scope,field(value.event,"content"),field(value.event,"context"),field(value.event,"source"),
            source.importancePermille,source.status,source.expiresAt,source.correctionOf,source.replacementId,source.conflictIds.clone(),
            source.conflictReason,source.deletionReason,source.createdAt,source.updatedAt,source.deletedAt,source.revision)
        if(value.kind=="event"){history.add(record)}else{
            for(prior in rows where prior.id==record.id){memoryLiveInvalid("independent current contains duplicate original ID")}
            rows.add(record);order.add(record.id)}
        texts.clear();offsets.clear();frameKind="";frameOrdinal= -1
        match(frameOwner){case Some(value)=>value.close();case None=>()};frameOwner=None;frameTextBytes=0
    }
    func close():Unit{history.clear();rows.clear();order.clear();texts.clear();offsets.clear()
        match(frameOwner){case Some(value)=>value.close();case None=>()};frameOwner=None;frameTextBytes=0}
}

// One private worker computation. Every RPC is descriptive data: the real
// Host still owns the canonical parent, full own-Receipt prefix and all effects.
// This class neither creates a Source nor accepts a Native success as a Receipt.
class NativeMemoryLiveToolData {
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let check:()->Unit
    private let sharedCustody:Bool
    private var sequence:Int64=0
    private var lastSequence:Int64=0
    private var now:Int64=0
    private var name=""
    private var callId=""
    private var expectedReceipts:Int64=0
    private var owner:?LogicalJsonOwnerReservation=None
    private var parameterUpload:?MemoryDocumentUpload=None
    private var parameters:?AgentValue=None
    private var parameterBytes:Int64=0
    private var reference:?PluginDocumentLatestJournalStreamReference=None
    private var requestDigest=""
    private var accessDigest=""
    private var viewDigest=""
    private var metadata:?AgentValue=None
    private var bootstrap=ArrayList<Byte>()
    private var baseOffset:Int64=0
    private var baseReady=false
    private var decoder:?MemoryLatestJournalFrameStreamDecoder=None
    private var decoderOwner:?LogicalJsonOwnerReservation=None
    private var historyOwner:?LogicalJsonOwnerReservation=None
    private var history:?MemoryLiveHistory=None
    private var receiptBytes=ArrayList<Byte>()
    private var receiptStarted=false
    private var receiptErrorBytes=ArrayList<Byte>()
    private var receiptErrorExpected:Int64=0
    private var receiptErrorDigest=""
    private var receiptErrorPeak:Int64=0
    private var receiptErrorValue:?AgentValue=None
    private var receiptErrorReader321:?MemoryLiveErrorStream321=None
    private var receiptErrorTyped321:?AgentError=None
    private var streamedErrors321=false
    private var settlements=ArrayList<NativeMemoryReplaySettlement>()
    private var settlementBytes:Int64=0
    private var output:?MemoryLiveOutput=None
    init(allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()},current!:()->Unit={=>()},
        sharedCustody!:Bool=false){
        this.allocate=allocate;this.check=current;this.sharedCustody=sharedCustody
    }
    private func phaseAllocate(bytes:Int64):LogicalJsonOwnerReservation{
        if(sharedCustody){
            let lease=owner.getOrThrow().deriveRetainedLease()
            try{lease.ensureRetainedPeak(memoryLiveMul(bytes,8));lease}
            catch(error:Exception){lease.close();throw error}
        }else{allocate(bytes)}
    }
    private func current():Unit{if(sequence<1){memoryLiveInvalid("Native computation has been released")};check()}
    private func pay():Unit{pay(0)}
    private func pay(extra:Int64):Unit{
        let retained=memoryLiveAdd(2097152,memoryLiveAdd(memoryLiveMul(parameterBytes,8),memoryLiveAdd(settlementBytes,memoryLiveMul(settlements.size,2048))))
        owner.getOrThrow().ensureRetainedPeak(memoryLiveAdd(memoryLiveAdd(retained,receiptErrorPeak),extra))
    }
    private func closeOutput():Unit{match(output){case Some(value)=>value.close();case None=>()};output=None}
    private func closeDecoder():Unit{
        match(decoder){case Some(value)=>value.close();case None=>()};decoder=None
        match(decoderOwner){case Some(value)=>value.close();case None=>()};decoderOwner=None
    }
    func close():Unit{
        closeOutput();closeDecoder()
        if(streamedErrors321){
            // Retire actual typed error/byte backing references, not only
            // ArrayList logical length, before the original owner closes.
            receiptBytes=ArrayList<Byte>();settlements=ArrayList<NativeMemoryReplaySettlement>();bootstrap=ArrayList<Byte>()
            receiptErrorBytes=ArrayList<Byte>()
        }
        parameters=None;parameterUpload=None;receiptBytes.clear();settlements.clear();bootstrap.clear()
        receiptErrorValue=None;receiptErrorBytes.clear();receiptErrorExpected=0;receiptErrorDigest="";receiptErrorPeak=0
        receiptErrorTyped321=None
        match(receiptErrorReader321){case Some(value)=>value.close();case None=>()};receiptErrorReader321=None;streamedErrors321=false
        match(history){case Some(value)=>value.close();case None=>()};history=None
        match(historyOwner){case Some(value)=>value.close();case None=>()};historyOwner=None
        metadata=None;reference=None
        match(owner){case Some(value)=>value.close();case None=>()};owner=None
        sequence=0;now=0;name="";callId="";expectedReceipts=0;parameterBytes=0;baseOffset=0;baseReady=false
        receiptStarted=false;settlementBytes=0;requestDigest="";accessDigest="";viewDigest=""
        // The physical worker high-water mark deliberately survives release.
    }
    private func begin(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","tool","input_payload","stream","prior_receipts","call_id","now_millis"])
        if(sequence!=0){memoryLiveInvalid("another computation still owns the private Native worker")}
        let serial=documentDataInteger(value,"sequence")
        if(serial<1 || serial<=lastSequence || serial==Int64.Max){memoryLiveInvalid("positive unexhausted Int63 sequence required")}
        let tool=memoryDocumentText(value,"tool");let actualCall=memoryDocumentText(value,"call_id")
        let frozenNow=documentDataInteger(value,"now_millis")
        if(!MEMORY_NATIVE_TOOLS.contains(tool) || actualCall.trimAscii()=="" || frozenNow<1){memoryLiveInvalid("actual Tool identity and original frozen business clock required")}
        let ledger=value.field("prior_receipts").getOrThrow();let through=documentDataInteger(ledger,"through_sequence")
        if(!pluginLivePolicyLedgerReferenceValid(ledger,memoryDocumentText(ledger,"parent_operation_id"),through)){
            memoryLiveInvalid("exact descriptive own-Receipt ledger reference required")}
        let input=value.field("input_payload").getOrThrow();memoryDocumentFields(input,["bytes","sha256"])
        let bytes=documentDataInteger(input,"bytes");let digest=memoryDocumentText(input,"sha256")
        if(bytes<2 || bytes>MEMORY_LIVE_TOOL_INPUT_BYTES || !httpIntentDigest(digest)){memoryLiveInvalid("original ordinary Tool input descriptor required")}
        let stream=value.field("stream").getOrThrow();memoryDocumentFields(stream,["reference","request_digest","access_policy_digest","view_policy_digest"])
        let selected=parsePluginDocumentLatestJournalStreamReference(stream.field("reference").getOrThrow()).value().getOrThrow()
        let request=memoryDocumentText(stream,"request_digest");let access=memoryDocumentText(stream,"access_policy_digest");let view=memoryDocumentText(stream,"view_policy_digest")
        if(!httpIntentDigest(request) || !httpIntentDigest(access) || !httpIntentDigest(view)){memoryLiveInvalid("all actual immutable stream descriptors required")}
        let charge=allocate(1);owner=Some(charge)
        try{
            sequence=serial;lastSequence=serial;now=frozenNow;name=tool;callId=actualCall;expectedReceipts=through
            parameterBytes=bytes;reference=Some(selected);requestDigest=request;accessDigest=access;viewDigest=view
            pay();parameterUpload=Some(MemoryDocumentUpload("parameters",bytes,digest));current();memoryLiveAccepted()
        }catch(error:Exception){close();throw error}
    }
    private func appendParameters(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","offset","bytes_hex"])
        if(parameters.isSome() || baseOffset!=0 || parameterUpload.isNone()){memoryLiveInvalid("parameter upload is not its original phase")}
        parameterUpload.getOrThrow().append(documentDataInteger(value,"offset"),memoryDocumentText(value,"bytes_hex"));current();memoryLiveAccepted()
    }
    private func endParameters(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence"])
        if(parameters.isSome() || parameterUpload.isNone() || baseOffset!=0){memoryLiveInvalid("parameter EOF repeated or reordered")}
        let raw=parameterUpload.getOrThrow().complete();let nodes=memoryLiveLexicalNodes(raw)
        pay(memoryLiveMul(nodes,512));let input=parseUnifiedJson(raw,maxBytes:MEMORY_LIVE_TOOL_INPUT_BYTES,maxDepth:32)
        if(input.unifiedKind!=ValueKind.Object || input.field(CONTEXT_READ_INPUT_FIELD).isSome()){
            memoryLiveInvalid("complete original business input only; no synthetic context envelope")}
        if(name=="manage_skill" || (name=="learn" && input.field("skill").isSome())){
            throw PureProviderError("memory.workspace_fact_required","managed skill requires its separate actual Workspace effect profile")}
        parameters=Some(input);parameterUpload=None;current();memoryLiveAccepted()
    }
    private func readAnnotations():?AgentValue{
        let magic=MEMORY_LATEST_JOURNAL_FRAME_MAGIC
        for(index in 0..min(bootstrap.size,magic.size)){if(bootstrap[index]!=magic[index]){memoryLiveInvalid("base stream magic changed")}}
        if(bootstrap.size<=magic.size){return None}
        var cursor=magic.size;var length:Int64=0;var digits:Int64=0;var firstZero=false
        while(cursor<bootstrap.size && bootstrap[cursor]!=b':'){
            let byte=bootstrap[cursor]
            if(byte<b'0' || byte>b'9' || digits>=5 || (digits>0 && firstZero)){memoryLiveInvalid("canonical bounded header length required")}
            if(digits==0){firstZero=byte==b'0'};digits++;length=length*10+Int64(byte-b'0');cursor++
            if(length>16384){memoryLiveInvalid("original stream header bound exceeded")}}
        if(cursor==bootstrap.size){return None}
        if(digits==0 || length<1){memoryLiveInvalid("empty base header")};cursor++
        if(bootstrap.size-cursor<length){return None}
        let raw=bootstrap.toArray();let header=parseUnifiedJson(String.fromUtf8(raw[cursor..cursor+length]),maxBytes:16384,maxDepth:8)
        memoryDocumentFields(header,["kind","schema","body_bytes","request_digest","access_policy_digest","view_policy_digest","revision","annotations"])
        if(memoryDocumentText(header,"kind")!="start" || memoryDocumentText(header,"schema")!="axyndra.row-journal-frames/v3" ||
            documentDataInteger(header,"body_bytes")!=0 || documentDataInteger(header,"revision")<1 ||
            memoryDocumentText(header,"request_digest")!=requestDigest || memoryDocumentText(header,"access_policy_digest")!=accessDigest ||
            memoryDocumentText(header,"view_policy_digest")!=viewDigest){memoryLiveInvalid("base start differs from exact frozen descriptors")}
        let annotations=header.field("annotations").getOrThrow();memoryDocumentFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])
        for(field in annotations.fields where field.value.unifiedKind!=ValueKind.Text){memoryLiveInvalid("all original annotations must be text")};Some(annotations)
    }
    private func appendBase(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","offset","bytes_hex"])
        if(parameters.isNone() || baseReady || receiptStarted || output.isSome() || documentDataInteger(value,"offset")!=baseOffset){memoryLiveInvalid("base phase or contiguous offset changed")}
        let raw=memoryLiveHex(memoryDocumentText(value,"bytes_hex"))
        if(raw.size>reference.getOrThrow().bytes-baseOffset){memoryLiveInvalid("base exceeds its original reference")}
        if(decoder.isNone()){
            if(bootstrap.size+raw.size>98304){memoryLiveInvalid("bounded bootstrap did not finish")};bootstrap.add(all:raw)
            match(readAnnotations()){
                case None=>baseOffset+=raw.size;return memoryLiveAccepted()
                case Some(annotations)=>
                    metadata=Some(annotations)
                    let retained=phaseAllocate(1);historyOwner=Some(retained);let gathered=MemoryLiveHistory(retained,shared:sharedCustody);history=Some(gathered)
                    let state=phaseAllocate(1);decoderOwner=Some(state)
                    let actual=MemoryLatestJournalFrameStreamDecoder(reference.getOrThrow(),requestDigest,accessDigest,viewDigest,annotations,state,{bytes=>phaseAllocate(bytes)},
                        consume:{frame=>gathered.frame(frame)},consumeText:{kind,ordinal,field,offset,text=>gathered.text(kind,ordinal,field,offset,text)},current:{=>current()})
                    decoder=Some(actual);let saved=bootstrap.toArray();var at:Int64=0
                    while(at<saved.size){let end=min(saved.size,at+65536);actual.append(at,saved[at..end]);at=end};bootstrap.clear()
            }
        }else{decoder.getOrThrow().append(baseOffset,raw)}
        baseOffset+=raw.size;current();memoryLiveAccepted()
    }
    private func endBase(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence"])
        if(baseReady || decoder.isNone() || baseOffset!=reference.getOrThrow().bytes){memoryLiveInvalid("complete original v3 EOF required")}
        let completed=decoder.getOrThrow().complete()
        if(completed.rawRows!=history.getOrThrow().rows.size || completed.rawEvents!=history.getOrThrow().history.size){memoryLiveInvalid("every readable original body must survive decoding")}
        current();baseReady=true;closeDecoder();memoryLiveAccepted()
    }
    private func appendReceipt(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","ordinal","offset","bytes_hex"])
        if(!baseReady || documentDataInteger(value,"ordinal")!=settlements.size || documentDataInteger(value,"offset")!=receiptBytes.size){memoryLiveInvalid("whole own-proposal replay prefix is out of order")}
        match(output){case Some(previous)=>
            if(previous.kind!="effect" || !previous.complete()){memoryLiveInvalid("actual whole proposal download must precede its settlement data")}
            case None=>if(settlements.size>=expectedReceipts){memoryLiveInvalid("unsolicited settlement has no prior own proposal")}}
        let raw=memoryLiveHex(memoryDocumentText(value,"bytes_hex"))
        pay(memoryLiveMul(memoryLiveAdd(receiptBytes.size,raw.size),8));receiptBytes.add(all:raw);receiptStarted=true;current();memoryLiveAccepted()
    }
    private func endReceipt(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","ordinal","bytes","sha256","proposal_digest","error"])
        if(!baseReady || !receiptStarted || documentDataInteger(value,"ordinal")!=settlements.size || documentDataInteger(value,"bytes")!=receiptBytes.size){memoryLiveInvalid("full original proposal EOF and ordinal required")}
        let digest=memoryDocumentText(value,"sha256");let proposalDigest=memoryDocumentText(value,"proposal_digest")
        if(!httpIntentDigest(digest) || !httpIntentDigest(proposalDigest)){memoryLiveInvalid("full original JSON and canonical digests required")}
        let raw=receiptBytes.toArray();if(modelPolicySha256(raw)!=digest){memoryLiveInvalid("replayed proposal JSON bytes changed")}
        let text=String.fromUtf8(raw);let nodes=memoryLiveLexicalNodes(text)
        pay(memoryLiveAdd(memoryLiveMul(raw.size,8),memoryLiveMul(nodes,512)))
        let group=parseUnifiedJson(text,maxBytes:raw.size,maxDepth:32)
        memoryDocumentFields(group,["schema","ordinal","operation","events","expected_record"])
        if(memoryDocumentText(group,"schema")!="axyndra.memory-transaction-proposal/v1" || documentDataInteger(group,"ordinal")!=settlements.size ||
            nativeMemoryReplayDigest(group,owner.getOrThrow())!=proposalDigest){memoryLiveInvalid("known settlement differs from full original own proposal")}
        match(output){case Some(previous)=>if(previous.proposalDigest!=proposalDigest){memoryLiveInvalid("Host replay differs from Native's actual frozen proposal")};case None=>()}
        // The original gate re-executes and matches this digest before any
        // virtual append. Merely parsing a caller's group never applies it.
        let error=memoryLiveErrorFrom(value.field("error").getOrThrow())
        let errorBytes=if(error.isSome()){stringifyUnifiedJson(value.field("error").getOrThrow()).size}else{0}
        settlementBytes=memoryLiveAdd(settlementBytes,memoryLiveMul(errorBytes,8));pay(memoryLiveAdd(memoryLiveMul(raw.size,8),memoryLiveMul(nodes,512)))
        settlements.add(NativeMemoryReplaySettlement(proposalDigest,error:error));receiptBytes.clear();receiptStarted=false
        closeOutput();expectedReceipts=max(expectedReceipts,settlements.size);current();memoryLiveAccepted()
    }
    // A data-only transfer on the SAME computation and original owner.
    //321 removes escaped wire storage; all decoded backing/reference cells
    // and its real temporary scalar lease share the original aggregate bank.
    private func beginReceiptError289(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","ordinal","bytes","sha256"])
        if(!baseReady || !receiptStarted || documentDataInteger(value,"ordinal")!=settlements.size ||
            receiptErrorExpected!=0 || receiptErrorValue.isSome() || !receiptErrorBytes.isEmpty() ||
            receiptErrorReader321.isSome() || receiptErrorTyped321.isSome()){
            memoryLiveInvalid("one exact pending proposal error transfer required")}
        let bytes=documentDataInteger(value,"bytes");let digest=memoryDocumentText(value,"sha256")
        if(bytes<1 || !httpIntentDigest(digest)){memoryLiveInvalid("complete original error JSON extent and hash required")}
        let temporary=owner.getOrThrow().deriveRetainedLease()
        try{
            receiptErrorReader321=Some(MemoryLiveErrorStream321(bytes,digest,temporary,{retained=>
                receiptErrorPeak=retained;pay(memoryLiveMul(receiptBytes.size,8))}))
        }catch(error:Exception){temporary.close();throw error}
        receiptErrorExpected=bytes;receiptErrorDigest=digest
        streamedErrors321=true
        current();memoryLiveAccepted()
    }
    private func appendReceiptError289(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","ordinal","offset","bytes_hex"])
        if(receiptErrorExpected<1 || receiptErrorTyped321.isSome() || receiptErrorReader321.isNone() ||
            documentDataInteger(value,"ordinal")!=settlements.size ||
            documentDataInteger(value,"offset")!=receiptErrorReader321.getOrThrow().position()){
            memoryLiveInvalid("error transfer changed exact original ordinal/offset")}
        let hex=memoryDocumentText(value,"bytes_hex")
        let offset=receiptErrorReader321.getOrThrow().position()
        if(hex.size/2>receiptErrorExpected-offset){memoryLiveInvalid("error transfer exceeded its original full extent")}
        // Its real same-owner temporary lease prepays bounded RPC/hex/raw
        // copies before this conversion, then each decoded scalar's growth.
        let bytes=memoryLiveHex(hex)
        receiptErrorReader321.getOrThrow().append(offset,bytes)
        current();memoryLiveAccepted()
    }
    private func endReceiptError289(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","ordinal"])
        if(receiptErrorExpected<1 || receiptErrorTyped321.isSome() || receiptErrorReader321.isNone() ||
            documentDataInteger(value,"ordinal")!=settlements.size ||
            receiptErrorReader321.getOrThrow().position()!=receiptErrorExpected){
            memoryLiveInvalid("error transfer requires complete original EOF")}
        // finish validates ALL original bytes/keys/UTF8/depth/hash and calls
        // the ORIGINAL eight-field typed decoder. Its returned error is kept
        // by this computation before decoder DOM/buffer references clear.
        receiptErrorTyped321=Some(receiptErrorReader321.getOrThrow().finish())
        let retained=receiptErrorReader321.getOrThrow().typedRetainedBytes()
        receiptErrorReader321.getOrThrow().close();receiptErrorReader321=None
        receiptErrorPeak=retained;pay(memoryLiveMul(receiptBytes.size,8))
        current();memoryLiveAccepted()
    }
    private func endReceiptStreamed289(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","ordinal","bytes","sha256","proposal_digest","error_payload"])
        let descriptor=value.field("error_payload").getOrThrow()
        if(descriptor.unifiedKind==ValueKind.Null){
            if(receiptErrorExpected!=0 || receiptErrorTyped321.isSome() || receiptErrorReader321.isSome() ||
                receiptErrorValue.isSome() || !receiptErrorBytes.isEmpty()){
                memoryLiveInvalid("null error cannot discard an actual unfinished transfer")}
        }else{
            memoryDocumentFields(descriptor,["bytes","sha256"])
            if(receiptErrorExpected<1 || receiptErrorTyped321.isNone() || receiptErrorReader321.isSome() ||
                documentDataInteger(descriptor,"bytes")!=receiptErrorExpected ||
                memoryDocumentText(descriptor,"sha256")!=receiptErrorDigest){
                memoryLiveInvalid("streamed error descriptor changed complete EOF/hash")}
        }
        // The following proposal/replay checks are the exact original
        // endReceipt checks, in the original order. Only its resource invoice
        // uses the actual decoded error retained above instead of serializing
        // an escaped48MiB copy and charging it eight times.
        if(!baseReady || !receiptStarted || documentDataInteger(value,"ordinal")!=settlements.size || documentDataInteger(value,"bytes")!=receiptBytes.size){memoryLiveInvalid("full original proposal EOF and ordinal required")}
        let digest=memoryDocumentText(value,"sha256");let proposalDigest=memoryDocumentText(value,"proposal_digest")
        if(!httpIntentDigest(digest) || !httpIntentDigest(proposalDigest)){memoryLiveInvalid("full original JSON and canonical digests required")}
        let raw=receiptBytes.toArray();if(modelPolicySha256(raw)!=digest){memoryLiveInvalid("replayed proposal JSON bytes changed")}
        let text=String.fromUtf8(raw);let nodes=memoryLiveLexicalNodes(text)
        pay(memoryLiveAdd(memoryLiveMul(raw.size,8),memoryLiveMul(nodes,512)))
        let group=parseUnifiedJson(text,maxBytes:raw.size,maxDepth:32)
        memoryDocumentFields(group,["schema","ordinal","operation","events","expected_record"])
        if(memoryDocumentText(group,"schema")!="axyndra.memory-transaction-proposal/v1" || documentDataInteger(group,"ordinal")!=settlements.size ||
            nativeMemoryReplayDigest(group,owner.getOrThrow())!=proposalDigest){memoryLiveInvalid("known settlement differs from full original own proposal")}
        match(output){case Some(previous)=>if(previous.proposalDigest!=proposalDigest){memoryLiveInvalid("Host replay differs from Native's actual frozen proposal")};case None=>()}
        // Existing payment remains live while references transfer to the
        // original settlement and original gate; no new error DOM/String.
        settlementBytes=memoryLiveAdd(settlementBytes,receiptErrorPeak);receiptErrorPeak=0
        pay(memoryLiveAdd(memoryLiveMul(raw.size,8),memoryLiveMul(nodes,512)))
        settlements.add(NativeMemoryReplaySettlement(proposalDigest,error:receiptErrorTyped321));receiptBytes.clear();receiptStarted=false
        receiptErrorTyped321=None;receiptErrorExpected=0;receiptErrorDigest=""
        closeOutput();expectedReceipts=max(expectedReceipts,settlements.size);current();memoryLiveAccepted()
    }
    private func invoke(journal:NativeMemoryJournal):Result<ToolResult>{
        let annotations=metadata.getOrThrow();let workspace=memoryDocumentText(annotations,"workspace_root")
        let thread=memoryDocumentText(annotations,"thread_id");let settings=memoryDocumentText(annotations,"settings_root")
        let tools=NativeMemoryTools(journal,NativeManagedSkillProposals([]),settings,workspace,[])
        let context=NativeMemoryToolContext(SessionId(thread),workspace);let call=ToolCall(callId,name,parameters.getOrThrow())
        match(name){
            case "retain"=>tools.retain(context,call)
            case "recall"=>tools.recall(context,call)
            case "reflect"=>tools.reflect(context,call)
            case "memory_edit"=>tools.edit(context,call)
            case "learn"=>tools.learn(context,call)
            case "memory_context"=>
                let input=parameters.getOrThrow();memoryDocumentFields(input,["query","max_bytes"])
                match(tools.contextFor(memoryDocumentText(input,"query"),SessionId(thread),workspace,memoryDocumentInteger(input,"max_bytes"))){
                    case Result.Err(error)=>Result<ToolResult>.Err(error)
                    case Result.Ok(content)=>
                        let fields=ArrayList<ValueField>([ValueField("content",textValue(content))])
                        if(tools.contextValidUntilMillis()>0){fields.add(ValueField("valid_until_millis",integerValue(tools.contextValidUntilMillis())))}
                        Result.Ok(ToolResult(callId,objectValue(fields.toArray())))}
            case _=>memoryLiveInvalid("unknown complete Native business tool")
        }
    }
    private func compute(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence"])
        if(!baseReady || parameters.isNone() || output.isSome() || receiptStarted || settlements.size!=expectedReceipts){memoryLiveInvalid("complete original base and whole known prefix required before compute")}
        current();let collected=history.getOrThrow()
        collected.pay(if(sharedCustody){0}else{memoryLiveMul(collected.history.size+collected.rows.size,8192)})
        let turn=nativeMemoryReplayTurn(collected.history.toArray(),now,settlements.toArray(),{journal=>invoke(journal)},
            firstAppearance:collected.order.toArray(),authoritativeCurrent:Some(collected.rows.toArray()),allocate:{bytes=>phaseAllocate(bytes)},streamSnapshots:sharedCustody)
        var transferred=false
        try{
            turn.consume({outcome=>match(outcome){
                case NativeMemoryReplayOutcome.Proposal(group,digest)=>
                    output=Some(MemoryLiveOutput(group.value(),turn,"effect",false,digest,{bytes=>phaseAllocate(bytes)},{=>current()}))
                case NativeMemoryReplayOutcome.Completed(result)=>
                    let data:AgentValue;let isError:Bool
                    match(result){
                        case Result.Ok(tool)=>data=tool.output;isError=tool.isError
                        case Result.Err(error)=>data=memoryLiveRecoverableOutput(error);isError=true}
                    output=Some(MemoryLiveOutput(data,turn,"completed",isError,"",{bytes=>phaseAllocate(bytes)},{=>current()}))
            }})
            transferred=true;current();output.getOrThrow().metadata()
        }finally{if(!transferred){turn.close()}}
    }
    func handle(value:AgentValue):AgentValue{
        // Existing actual RPC frame bound. Business input/history/proposal
        // length is not confused with one transport message or one8MiB ref.
        if(logicalJsonWriteReservationBytes(value,196608)>196608 || memoryDocumentText(value,"schema")!=MEMORY_LIVE_TOOL_DATA_SCHEMA){memoryLiveInvalid("exact bounded live-data frame required")}
        let action=memoryDocumentText(value,"action")
        if(action=="begin"){return begin(value)}
        if(sequence<1 || documentDataInteger(value,"sequence")!=sequence){memoryLiveInvalid("stale private computation sequence")}
        try{
            current();let result:AgentValue=match(action){
                case "append_parameters"=>appendParameters(value)
                case "end_parameters"=>endParameters(value)
                case "append_base"=>appendBase(value)
                case "end_base"=>endBase(value)
                case "append_receipt"=>
                    if(receiptErrorExpected!=0){memoryLiveInvalid("proposal bytes cannot change after full error transfer began")}
                    appendReceipt(value)
                case "end_receipt"=>
                    if(receiptErrorExpected!=0){memoryLiveInvalid("inline error cannot discard an unfinished full error transfer")}
                    endReceipt(value)
                case "begin_receipt_error"=>beginReceiptError289(value)
                case "append_receipt_error"=>appendReceiptError289(value)
                case "end_receipt_error"=>endReceiptError289(value)
                case "end_receipt_streamed"=>endReceiptStreamed289(value)
                case "compute"=>compute(value)
                case "describe"=>
                    memoryDocumentFields(value,["schema","action","sequence","offset","count"])
                    output.getOrThrow().describe(documentDataInteger(value,"offset"),documentDataInteger(value,"count"))
                case "download"=>
                    memoryDocumentFields(value,["schema","action","sequence","slot","offset","max_bytes"])
                    output.getOrThrow().download(memoryDocumentText(value,"slot"),documentDataInteger(value,"offset"),documentDataInteger(value,"max_bytes"))
                case "release"=>
                    memoryDocumentFields(value,["schema","action","sequence"]);close();return objectValue([ValueField("released",boolValue(true))])
                case _=>memoryLiveInvalid("unsupported live-data action")}
            current();result
        }catch(error:Exception){close();throw error}
    }
}
