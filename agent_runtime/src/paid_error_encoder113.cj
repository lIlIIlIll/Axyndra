package agent_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Complete error DATA only. The caller supplies its ORIGINAL bank's live
// borrow funding closure. Each invoice is an additional concurrent increment,
// not a new bank, replacement peak, permission, Source, retry or ACK.
// Prefix containers must already be paid before the caller constructs them.
// The result and every captured alias remain under that borrow/consumer until
// their actual output/SQL/display frames retire and the caller acknowledges.
let OWNED_FAILURE_ENCODER_MAX_BYTES113: Int64 = 67108864

private func ownedFailureEncoderPay113(fund:(Int64)->Result<Unit>,bytes:Int64):Unit{
    match(fund(bytes)){case Result.Ok(_)=>();case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)}
}
private func ownedFailureEncoderMultiply113(a:Int64,b:Int64):Int64{
    if(a<0 || b<0 || (b!=0 && a>Int64.Max/b)){throw IllegalStateException("complete error encoding invoice overflow")}
    a*b
}

// The pinned default writer's UTF8 escape extent. rawData borrows existing
// String bytes; no String/toArray/escaped copy is allocated during this walk.
// Only concrete arrays/objects are traversed. Non-open scalar accessors and
// the original scalar writer retain numeric spelling and original rejection.
private class OwnedFailureEncoderExtent113{
    let options:JsonWriteOptions
    let fund:(Int64)->Result<Unit>
    let ancestors=ArrayList<JsonNode>()
    var bytes:Int64=0
    var nodes:Int64=0
    init(fund:(Int64)->Result<Unit>){this.options=JsonWriteOptions.defaults;this.fund=fund}
    func add(amount:Int64):Unit{
        bytes=ownedOuterErrorAdd333(bytes,amount)
        if(bytes>OWNED_FAILURE_ENCODER_MAX_BYTES113){throw IllegalArgumentException("complete error encoding exceeds its original 64MiB bound")}
    }
    func stringBytes(value:String):Unit{
        add(2)
        unsafe{let raw=value.rawData();for(index in 0..raw.size){let byte=Int64(raw[index])
            if(byte==34 || byte==92 || byte==8 || byte==9 || byte==10 || byte==12 || byte==13){add(2)}
            else if(byte<32 || (options.htmlSafe && (byte==38 || byte==39 || byte==60 || byte==61 || byte==62))){add(6)}
            else{add(1)}}}
    }
    func enter(value:JsonNode):Unit{
        for(ancestor in ancestors){if(refEq(value,ancestor)){throw IllegalArgumentException("complete error prefix contains a cycle")}}
        if(ancestors.size>=options.maxDepth){throw IllegalArgumentException("complete error prefix exceeds original writer depth")}
        ancestors.add(value)
    }
    func entryPrefix(depth:Int64):Unit{
        if(!options.indent.isEmpty()){add(ownedOuterErrorAdd333(1,ownedFailureEncoderMultiply113(depth,options.indent.size)))}
    }
    func visit(value:JsonNode):Unit{
        // Pay traversal/path/node metadata before its actual frame/container.
        ownedFailureEncoderPay113(fund,512);nodes=ownedOuterErrorAdd333(nodes,1)
        match(value){
            case array:JsonArray=>
                enter(array);try{add(2);for(index in 0..array.size()){
                    if(index!=0){add(1)};entryPrefix(ancestors.size)
                    visit(array.get(index).getOrThrow())}
                    if(array.size()!=0){entryPrefix(ancestors.size-1)}}
                finally{ancestors.remove(at:ancestors.size-1)}
            case object:JsonObject=>
                enter(object);try{add(2);for(index in 0..object.size()){
                    if(index!=0){add(1)};entryPrefix(ancestors.size)
                    stringBytes(object.nameAt(index));add(1)
                    if(!options.indent.isEmpty()){add(1)}
                    visit(object.valueAt(index))}
                    if(object.size()!=0){entryPrefix(ancestors.size-1)}}
                finally{ancestors.remove(at:ancestors.size-1)}
            case _=>
                let text:?String=try{Some(value.asString())}catch(_:JsonException){None<String>}
                match(text){case Some(actual)=>stringBytes(actual)
                    case None=>
                        let numeric:?String=try{Some(value.asNumberText())}catch(_:JsonException){None<String>}
                        match(numeric){case Some(actual)=>ownedFailureEncoderPay113(fund,
                            ownedOuterErrorAdd333(1024,ownedFailureEncoderMultiply113(actual.size,8)))
                            case None=>()}
                        // Built-in numeric/boolean/null errors use the original
                        // writer. No stringify of an unmeasured whole prefix.
                        let encoded=value.toJson(options:options);add(encoded.size)}
        }
    }
}

private func ownedFailureEncoderBasePeak113(error:?AgentError,prefix:Array<ValueField>,errorField:String):Int64{
    var raw:Int64=errorField.size
    var count:Int64=ownedOuterErrorAdd333(prefix.size,32)
    for(field in prefix){raw=ownedOuterErrorAdd333(raw,field.name.size)}
    match(error){case Some(value)=>
        raw=ownedOuterErrorAdd333(raw,ownedOuterErrorAdd333(value.code.size,value.message.size))
        for(field in value.fields){raw=ownedOuterErrorAdd333(raw,ownedOuterErrorAdd333(field.name.size,field.value.size))}
        count=ownedOuterErrorAdd333(count,ownedFailureEncoderMultiply113(value.fields.size,4))
        case None=>()}
    ownedOuterErrorAdd333(1048576,ownedOuterErrorAdd333(ownedFailureEncoderMultiply113(raw,8),
        ownedFailureEncoderMultiply113(count,1024)))
}
private func ownedFailureEncoderValue113(error:AgentError):AgentValue{
    let fields=ArrayList<AgentValue>()
    for(field in error.fields){fields.add(objectValue([
        ValueField("name",textValue(field.name)),ValueField("value",textValue(field.value))]))}
    objectValue([
        ValueField("kind",textValue(ownedFailureEncoderErrorKindName113(error.kind))),
        ValueField("code",textValue(error.code)),ValueField("message",textValue(error.message)),
        ValueField("retryable",boolValue(error.retryable)),ValueField("fallback_allowed",boolValue(error.fallbackAllowed)),
        ValueField("fields",listValue(fields.toArray())),
        ValueField("attempt_failure",match(error.attemptFailure){case Some(value)=>ownedFailureEncoderAttemptValue113(value);case None=>nullValue()}),
        ValueField("observation",nullValue())])
}
private func ownedFailureEncoderErrorKindName113(value:AgentErrorKind):String{
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
private func ownedFailureEncoderAttemptKindName113(value:AttemptFailureKind):String{
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
private func ownedFailureEncoderProgressKindName113(value:AttemptProgressKind):String{
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
private func ownedFailureEncoderAttemptValue113(value:AttemptFailure):AgentValue{
    let data=value.diagnostics
    objectValue([ValueField("kind",textValue(ownedFailureEncoderAttemptKindName113(value.kind))),
        ValueField("diagnostics",objectValue([
            ValueField("elapsed_millis",integerValue(data.elapsedMillis)),
            ValueField("soft_deadline_millis",integerValue(data.softDeadlineMillis)),
            ValueField("hard_deadline_millis",integerValue(data.hardDeadlineMillis)),
            ValueField("entered_completion_grace",boolValue(data.enteredCompletionGrace)),
            ValueField("last_progress_kind",textValue(ownedFailureEncoderProgressKindName113(data.lastProgressKind))),
            ValueField("last_progress_age_millis",integerValue(data.lastProgressAgeMillis)),
            ValueField("provider_terminal_observed",boolValue(data.providerTerminalObserved)),
            ValueField("open_content_block_count",integerValue(data.openContentBlockCount)),
            ValueField("tool_calls_started",integerValue(data.toolCallsStarted)),
            ValueField("tool_calls_completed",integerValue(data.toolCallsCompleted))]))])
}


private class OwnedFailureEncoderObservationExtent113{var bytes:Int64=0}
private class OwnedFailureEncoderString113{
    var value:?String=None<String>
    func take():String{let actual=value.getOrThrow();value=None<String>;actual}
}
private func ownedFailureEncoderSplice113(source:String,observation:OperationObservation,closing:Int64,
    expected:Int64):String{
    let suffix=if(closing==2){"\"observation\":null}}"}else{"\"observation\":null}"}
    if(!source.endsWith(suffix)){throw IllegalStateException("complete error encoder terminal observation changed")}
    let cut=source.size-4-closing
    let original=source.toArray()
    let head="{\"schema\":\"axyndra.operation-observation/v1\",\"trust\":\"untrusted_data\",\"authorizes_effects\":false,\"content\":".toArray()
    let result=OwnedFailureEncoderString113()
    observation.withFrozenEncodedData113({frozen=>
        let content=frozen.toArray()
        let total=ownedOuterErrorAdd333(ownedOuterErrorAdd333(cut,head.size),ownedOuterErrorAdd333(content.size,closing+1))
        if(total!=expected){throw IllegalStateException("frozen observation extent changed")}
        let bytes=Array<Byte>(total,{index=>
            if(index<cut){original[index]}
            else if(index<cut+head.size){head[index-cut]}
            else if(index<cut+head.size+content.size){content[index-cut-head.size]}
            else{b'}'}})
        result.value=Some(String.fromUtf8(bytes))
    })
    result.take()
}
private func ownedFailureEncoderRoot113(error:?AgentError,prefix:Array<ValueField>,errorField:String,
    wrapped:Bool,fund:(Int64)->Result<Unit>):Result<String>{
    try{
        ownedFailureEncoderPay113(fund,ownedFailureEncoderBasePeak113(error,prefix,errorField))
        // Freeze the same original default writer before reading its options.
        let _=JsonNode.nullValue.toJson()
        let value=match(error){case Some(actual)=>ownedFailureEncoderValue113(actual);case None=>nullValue()}
        let fields=ArrayList<ValueField>(prefix)
        if(wrapped){
            for(field in prefix){if(field.name==errorField){throw IllegalArgumentException("complete error prefix repeats terminal field")}}
            fields.add(ValueField(errorField,value))}
        let root=if(wrapped){objectValue(fields.toArray())}else{value}
        let extent=OwnedFailureEncoderExtent113(fund);extent.visit(root)
        let observation=match(error){case Some(actual)=>actual.observation;case None=>None<OperationObservation>}
        let frozenExtent=OwnedFailureEncoderObservationExtent113()
        match(observation){case Some(actual)=>actual.withFrozenEncodedData113({frozen=>frozenExtent.bytes=frozen.size});case None=>()}
        let observationHead="{\"schema\":\"axyndra.operation-observation/v1\",\"trust\":\"untrusted_data\",\"authorizes_effects\":false,\"content\":"
        let finalBytes=if(observation.isSome()){
            ownedOuterErrorAdd333(extent.bytes-4,ownedOuterErrorAdd333(observationHead.size,frozenExtent.bytes+1))
        }else{extent.bytes}
        if(finalBytes>OWNED_FAILURE_ENCODER_MAX_BYTES113){throw IllegalArgumentException("complete error encoding exceeds its original 64MiB bound")}
        // All whole encodings, independently copied UTF8 arrays, splice output
        // and final String coexist at their real peak. No fixed 65K-node DOM
        // payment is substituted for the immutable encoded observation.
        let encodedPeak=ownedOuterErrorAdd333(1048576,ownedOuterErrorAdd333(
            ownedFailureEncoderMultiply113(extent.bytes,8),ownedFailureEncoderMultiply113(finalBytes,8)))
        ownedFailureEncoderPay113(fund,ownedOuterErrorAdd333(encodedPeak,
            ownedFailureEncoderMultiply113(ownedOuterErrorAdd333(frozenExtent.bytes,observationHead.size),2)))
        let source=encodeAgentValue(root)
        if(source.size!=extent.bytes){throw IllegalStateException("complete error prefix changed during encoding")}
        let answer=match(observation){case Some(actual)=>ownedFailureEncoderSplice113(source,actual,if(wrapped){2}else{1},finalBytes)
            case None=>source}
        if(answer.size!=finalBytes){throw IllegalStateException("complete error encoded extent changed")}
        Result<String>.Ok(answer)
    }catch(failure:OwnedCanonicalDataFailure113){Result<String>.Err(failure.error)}
    catch(failure:Exception){
        // Preserve the real encoder failure under the same live funding loan.
        // No truncated fallback response or ACK follows a payment refusal.
        match(fund(ownedOuterErrorAdd333(8192,ownedFailureEncoderMultiply113(failure.message.size,8)))){
            case Result.Err(error)=>Result<String>.Err(error)
            case Result.Ok(_)=>Result<String>.Err(AgentError(AgentErrorKind.InvalidInput,
                "data.failure_encoding_invalid",String.fromUtf8(failure.message.toArray())))}
    }
}

// Prefix order is unchanged; errorField is appended last. No envelope policy
// is inferred from id/command/ok/event: those are caller-owned DATA fields.
public func encodeOwnedFailureError113(error:AgentError,prefix:Array<ValueField>,errorField:String,
    fund:(Int64)->Result<Unit>):Result<String>{ownedFailureEncoderRoot113(Some(error),prefix,errorField,true,fund)}
public func encodeOwnedFailureError113(error:?AgentError,prefix:Array<ValueField>,errorField:String,
    fund:(Int64)->Result<Unit>):Result<String>{ownedFailureEncoderRoot113(error,prefix,errorField,true,fund)}
public func encodeOwnedFailureError113(error:AgentError,fund:(Int64)->Result<Unit>):Result<String>{
    ownedFailureEncoderRoot113(Some(error),[],"",false,fund)
}
