package agent_host_runtime

import agent_domain.*
import agent_store.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Private data custody, not a Source. Its immutable original input and all
// escaping descriptor/continuation copies stay on the mounted configuration's
// actual allocation. A digest alone cannot construct or open this owner.
class HostPeerPreparedInput111 {
    private let host:HostJavaScriptPluginHost
    private let configuration:HostPrimitiveConfiguration111
    private let original:AgentValue
    private let description:AgentValue
    init(host:HostJavaScriptPluginHost,configuration:HostPrimitiveConfiguration111,
        original:AgentValue,description:AgentValue) {
        this.host=host;this.configuration=configuration;this.original=original;this.description=description
    }
    func reference():AgentValue {description}
    // Only the original captured graph is encoded. The already-adopted
    // Session writes and reads its own private temporary, validates full EOF
    // and hash on the same verified fd before decoding, then closes that fd.
    // The callback result is copied/funded before its temporary DOM retires.
    func consume(current:()->Result<Unit>,action:(AgentValue)->Result<AgentValue>):Result<AgentValue> {
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let owner=match(host.documentDataSession()) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        let result=owner.run({session=>session.withPreparedBusinessInput111(original,description,
            {bytes=>configuration.inputTemporaryPayment111(bytes)},current,{actual=>
                match(action(actual)){case Result.Err(error)=>Result<AgentValue>.Err(error)
                    case Result.Ok(value)=>Result<AgentValue>.Ok(configuration.copyPreparedPlan(value))}})})
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        result
    }
}

func hostCapturePeerPreparedInput111(host:HostJavaScriptPluginHost,configuration:HostPrimitiveConfiguration111,
    call:ToolCall,current:()->Result<Unit>):Result<HostPeerPreparedInput111> {
    if(call.arguments.unifiedKind!=ValueKind.Object || call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
        return hostPluginResourceError("peer.read_input_invalid","first preparation requires the complete original input") }
    try {
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Fund the complete independent input before capture. This permanent
        // raw Prepared/continuation data has no inferred consumer ACK.
        let frozen=configuration.copyPreparedPlan(call.arguments)
        let _=configuration.retainObservation(4096,64,{=>nullValue()})
        let description=HostPeerInputDescription111()
        withPluginLivePolicyInputPayloadEncoding(frozen,{bytes=>configuration.inputTemporaryPayment111(bytes)},current,
            {encoded=>description.bytes=encoded.size;description.digest=modelPolicySha256Text(encoded)})
        let reference=configuration.retainObservation(4096,64,{=>objectValue([
            ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
            ValueField("artifact_ref",textValue("blob:sha256:"+description.digest)),ValueField("encoding",textValue("utf8")),
            ValueField("bytes",integerValue(description.bytes)),ValueField("sha256",textValue(description.digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])})
        match(parsePluginDocumentPayloadReference(reference)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(HostPeerPreparedInput111(host,configuration,frozen,reference))
    }catch(_:Exception){hostPluginResourceError("peer.read_input_unpaid","original input could not be frozen within its actual allocation")}
}
private class HostPeerInputDescription111 {
    var bytes:Int64=0
    var digest:String=""
    init(){}
}
