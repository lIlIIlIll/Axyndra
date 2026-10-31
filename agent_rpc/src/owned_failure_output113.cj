package agent_rpc

import agent_domain.*
import agent_core.*
import agent_runtime.*
import agent_product.productBase64Bytes
import std.collection.*
import yjson.*
import yjson_support.*

// The fixed sentinel carries no dynamic error, input or owner reference.
// It bridges the existing Unit loan solely for a refused prepayment. A
// failure leaves the original consumer untouched and cannot become an ACK.
private let RPC_FAILURE_PREPAY_REFUSED113=IllegalStateException("RPC failure control prepayment refused")
private func rpcPrepayFailureControl113(value:OwnedFailureDataConsumer113,amount:Int64):Result<Unit> {
    try {
        value.withError({_,fund=>match(fund(amount)) {
            case Result.Ok(_)=>()
            case Result.Err(_)=>throw RPC_FAILURE_PREPAY_REFUSED113
        }})
    } catch(failure:Exception) {
        if(refEq(failure,RPC_FAILURE_PREPAY_REFUSED113)){Result<Unit>.Err(rpcFailureHeldError113())}
        else{throw failure}
    }
}
class RpcFailureControl113 {
    var answer=Result<Unit>.Ok(())
    var selected:?RpcOwnedFailureDelivery113=None<RpcOwnedFailureDelivery113>
}

enum RpcFailureAlias113 {
    Publication(OwnedFailureRunPublication113) | Data(OwnedFailureDataConsumer113)
    func withError(consume: (AgentError,(Int64)->Result<Unit>)->Result<Unit>): Result<Unit> {
        match(this) {
            case Publication(value) => value.withError(consume)
            case Data(value) =>
                match(rpcPrepayFailureControl113(value,4096)) {
                    case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                let control=RpcFailureControl113()
                let borrowed=value.withError({error,fund=>control.answer=consume(error,fund)})
                match(borrowed){case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>control.answer}
        }
    }
    func retain(): Result<RpcFailureAlias113> {
        match(this) {
            case Publication(value) => match(value.retainConsumer()) {
                case Result.Err(error)=>Result<RpcFailureAlias113>.Err(error)
                case Result.Ok(child)=>Result.Ok(RpcFailureAlias113.Publication(child)) }
            case Data(value) => match(value.retainConsumer()) {
                case Result.Err(error)=>Result<RpcFailureAlias113>.Err(error)
                case Result.Ok(child)=>Result.Ok(RpcFailureAlias113.Data(child)) }
        }
    }
    func acknowledge(): Result<Unit> { match(this) {
        case Publication(value)=>value.acknowledgeAfterConsumption()
        case Data(value)=>value.acknowledgeAfterConsumption() } }
    func acknowledged(): Bool { match(this) {
        case Publication(value)=>value.isAcknowledged();case Data(value)=>value.isAcknowledged() } }
    func capture(error: AgentError): OwnedFailureDataConsumer113 {
        let captured=match(this) {
            case Publication(value)=>value.captureFailure113<Unit>(error)
            case Data(value)=>value.captureFailure113<Unit>(error) }
        match(captured){case OwnedFailureDataOutcome113.Failure(value)=>value
            case _=>throw IllegalStateException("failure capture did not retain its actual error")}
    }
    func write(output: OwnedRpcFailureOutput113,
        render:(AgentError,(Int64)->Result<Unit>)->Result<String>):OwnedFailureDataOutcome113<Unit> {
        match(this){case Publication(value)=>output.writeFailureFrame113(value,render)
            case Data(value)=>output.writeFailureFrame113(value,render)}
    }
}

// The queue owns the original input. Stdio receives a DIFFERENT paid output
// child; its ACK cannot refund these still-live request/event metadata aliases.
// Nodes are paid before construction/linking and are never retried after offer.
class RpcOwnedFailureDelivery113 {
    var next: ?RpcOwnedFailureDelivery113 = None<RpcOwnedFailureDelivery113>
    private var source: ?RpcFailureAlias113
    private var outputChild: ?RpcFailureAlias113 = None<RpcFailureAlias113>
    private var queuedSecondary113: ?RpcFailureAlias113 = None<RpcFailureAlias113>
    private var queuedSecondaryOutput113: ?RpcFailureAlias113 = None<RpcFailureAlias113>
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var requestId: String
    private var command: String
    private var runId: String
    private let sequence: Int64
    private let isEvent: Bool
    private let protocolVersion: Int64
    private var offered=false
    private var returned=false
    private var succeeded=false
    init(source:RpcFailureAlias113,id:String,command:String,run:String,sequence:Int64,
        event:Bool,protocol:Int64) {
        this.source=Some(source)
        this.requestId=String.fromUtf8(id.toArray());this.command=String.fromUtf8(command.toArray())
        this.runId=String.fromUtf8(run.toArray());this.sequence=sequence
        this.isEvent=event;this.protocolVersion=protocol
    }
    func installQueuedSecondary113(value: OwnedFailureDataConsumer113): Unit {
        if (offered || queuedSecondary113.isSome()) { throw IllegalStateException("queued secondary registration changed") }
        queuedSecondary113 = Some(RpcFailureAlias113.Data(value))
    }
    func offer(output:?OwnedRpcFailureOutput113,nextChunkId:()->String):Unit {
        if(offered){return}
        // Unsupported output stays in this actual registered queue. No raw
        // String or short diagnostic is substituted for the complete failure.
        let target=match(output){case None=>return;case Some(value)=>value}
        offered=true
        try {
            let child=match(source.getOrThrow().retain()) {
                case Result.Err(error)=>secondary=Some(source.getOrThrow().capture(error));return
                case Result.Ok(value)=>value }
            outputChild=Some(child)
            match (queuedSecondary113) {
                case Some(actual) => match (actual.retain()) {
                    case Result.Err(error) => secondary=Some(actual.capture(error)); return
                    case Result.Ok(retained) => queuedSecondaryOutput113=Some(retained) }
                case None => () }
            rpcOwnedFailureOfferFrame113(this,child,target,nextChunkId)
        } finally { returned=true }
    }
    func canRetire():Bool {
        returned && succeeded && secondary.isNone() && outputChild.isSome() &&
            outputChild.getOrThrow().acknowledged()
    }
    func render(error:AgentError,fund:(Int64)->Result<Unit>,nextChunkId:()->String):Result<String> {
        let strings=ownedOuterErrorAdd333(requestId.size,ownedOuterErrorAdd333(command.size,runId.size))
        match(fund(ownedOuterErrorAdd333(65536,ownedOuterErrorMultiply333(strings,8)))) {
            case Result.Err(error)=>return Result<String>.Err(error);case Result.Ok(_)=>() }
        let prefix=ArrayList<ValueField>()
        if(isEvent) {
            prefix.add(ValueField("type",textValue("agent_event")))
            prefix.add(ValueField("sequence",integerValue(sequence)))
            prefix.add(ValueField("runId",textValue(runId)))
        } else {
            // Preserve the original error String and false response status;
            // the additional error_data is the complete shared eight-field
            // codec, never a Tool event or a successful ordinary result.
            match(fund(ownedOuterErrorMultiply333(error.message.size,8))) {
                case Result.Err(error)=>return Result<String>.Err(error);case Result.Ok(_)=>() }
            prefix.add(ValueField("type",textValue("response")))
            if(requestId!=""){prefix.add(ValueField("id",textValue(requestId)))}
            prefix.add(ValueField("command",textValue(command)))
            prefix.add(ValueField("success",boolValue(false)))
            prefix.add(ValueField("error",textValue(error.message)))
        }
        // Fixed dependency: Runtime's shared paid codec also backs the new
        // Persistence113 writer. No second kind/attempt/observation codec.
        let logical=match(encodeOwnedFailureError113(error,prefix.toArray(),if(isEvent){"event"}else{"error_data"},fund)) {
            case Result.Err(error)=>return Result<String>.Err(error);case Result.Ok(value)=>value }
        let complete = match (queuedSecondaryOutput113) {
            case Some(actual) => match (rpcRenderQueuedSecondary113(logical, actual, fund)) {
                case Result.Err(error) => return Result<String>.Err(error)
                case Result.Ok(value) => value }
            case None => logical }
        rpcOwnedFailureFraming113(complete,protocolVersion,fund,nextChunkId)
    }
    func noteAnswer(answer:OwnedFailureDataOutcome113<Unit>):Unit {
        match(answer) {
            case OwnedFailureDataOutcome113.Value(_)=>succeeded=true
            // Captured by the actual producer while its error/IO frame was
            // still live; do not recover an unpaid raw Err after that frame.
            case OwnedFailureDataOutcome113.Failure(error)=>secondary=Some(error)
        }
    }
    // No generated frame/error metadata escapes this helper. It only moves
    // the original paid input after true output ACK and the write stack return.
    func acknowledgeQueuedSecondaryOutput113(): Bool {
        if (!canRetire()) { return false }
        match (queuedSecondaryOutput113) {
            case Some(value) => if (!value.acknowledged()) {
                match (value.acknowledge()) { case Result.Err(_) => return false; case Result.Ok(_) => () } }
            case None => () }
        true
    }
    func detachQueuedSecondaryInput113(): ?RpcFailureAlias113 {
        if (!canRetire() || !acknowledgeQueuedSecondaryOutput113()) { return None<RpcFailureAlias113> }
        queuedSecondaryOutput113=None<RpcFailureAlias113>
        let actual=queuedSecondary113;queuedSecondary113=None<RpcFailureAlias113>;actual
    }
    func detachAfterActualOutput113():?RpcFailureAlias113 {
        if(!canRetire()){return None<RpcFailureAlias113>}
        outputChild=None<RpcFailureAlias113>
        requestId="";command="";runId=""
        let actual=source;source=None<RpcFailureAlias113>;actual
    }
}

// Access is serialized by ProductJsonlRpcServer.frameLock. The queue never
// lends its nodes to a caller, retries a partly written frame or substitutes
// an ordinary Unit callback for the concrete output contract.
class RpcOwnedFailureQueue113 {
    private var first:?RpcOwnedFailureDelivery113=None<RpcOwnedFailureDelivery113>
    private var last:?RpcOwnedFailureDelivery113=None<RpcOwnedFailureDelivery113>
    private var retiring:?RpcFailureAlias113=None<RpcFailureAlias113>
    private var retiringQueuedSecondary113:?RpcFailureAlias113=None<RpcFailureAlias113>
    func append(value:RpcOwnedFailureDelivery113):Unit {
        match(last){case Some(prior)=>prior.next=Some(value);case None=>first=Some(value)}
        last=Some(value)
    }
    func pending():Bool { first.isSome() || retiring.isSome() || retiringQueuedSecondary113.isSome() }
    func offer(output:?OwnedRpcFailureOutput113,nextChunkId:()->String):Unit {
        // This call returns from the whole output/renderer helper before
        // retirement sees it. An unacknowledged predecessor blocks successors.
        if(retiring.isSome() || retiringQueuedSecondary113.isSome()){return}
        match(first){case Some(value)=>value.offer(output,nextChunkId);case None=>()}
    }
    private func detachCompletedHead():?RpcFailureAlias113 {
        let current=match(first){case Some(value)=>value;case None=>return None<RpcFailureAlias113>}
        if (!current.acknowledgeQueuedSecondaryOutput113()) { return None<RpcFailureAlias113> }
        retiringQueuedSecondary113=current.detachQueuedSecondaryInput113()
        let source=current.detachAfterActualOutput113()
        if(source.isNone()){return source}
        first=current.next;current.next=None<RpcOwnedFailureDelivery113>
        if(first.isNone()){last=None<RpcOwnedFailureDelivery113>}
        source
    }
    func collect():Bool {
        if(retiring.isNone() && retiringQueuedSecondary113.isNone()){retiring=detachCompletedHead()}
        // The complete rendered two-error frame and every node/helper alias
        // returned before either original input can be acknowledged.
        match (retiringQueuedSecondary113) { case Some(value) =>
            match (value.acknowledge()) { case Result.Err(_) => return false
                case Result.Ok(_) => retiringQueuedSecondary113=None<RpcFailureAlias113> }
            case None => () }
        // detachCompletedHead's node/string/renderer references have returned;
        // a refused original ACK remains owned here for later DATA collection.
        match(retiring){case Some(value)=>
            match(value.acknowledge()){case Result.Ok(_)=>retiring=None<RpcFailureAlias113>;true
                case Result.Err(_)=>false}
            case None=>false}
    }
}

private func rpcOwnedFailureOfferFrame113(delivery:RpcOwnedFailureDelivery113,child:RpcFailureAlias113,
    output:OwnedRpcFailureOutput113,nextChunkId:()->String):Unit {
    // This complete helper (including renderer closure and Result alias)
    // returns before delivery.returned becomes true or its original can ACK.
    delivery.noteAnswer(child.write(output,{error,fund=>delivery.render(error,fund,nextChunkId)}))
}

func rpcFailureMetadata113(id:String,command:String,run:String):Int64 {
    ownedOuterErrorAdd333(16384,ownedOuterErrorMultiply333(
        ownedOuterErrorAdd333(id.size,ownedOuterErrorAdd333(command.size,run.size)),8))
}

func rpcPrepareFailurePublication113(value:OwnedFailureRunPublication113,id:String,command:String,
    event:Bool,protocol:Int64):Result<RpcOwnedFailureDelivery113> {
    match(value.withError({_,fund=>fund(4096)})) {
        case Result.Err(error)=>return Result<RpcOwnedFailureDelivery113>.Err(error);case Result.Ok(_)=>()}
    let control=RpcFailureControl113()
    let loan=if(event) {
        value.withDiagnostic({actual,fund=>
            match(actual.payload){case AgentEventPayload.Diagnostic(_)=>()
                case _=>return ownedRpcOutputError("rpc.failure_event_kind_changed")}
            match(fund(rpcFailureMetadata113(id,command,actual.runId.value))) {
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>() }
            control.selected=Some(RpcOwnedFailureDelivery113(RpcFailureAlias113.Publication(value),id,command,
                actual.runId.value,actual.sequence,true,protocol))
            Result<Unit>.Ok(())
        })
    } else {
        value.withError({_,fund=>
            match(fund(rpcFailureMetadata113(id,command,""))) {
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>() }
            control.selected=Some(RpcOwnedFailureDelivery113(RpcFailureAlias113.Publication(value),id,command,"",0,false,protocol))
            Result<Unit>.Ok(())
        })
    }
    match(loan){case Result.Err(error)=>Result<RpcOwnedFailureDelivery113>.Err(error)
        case Result.Ok(_)=>Result.Ok(control.selected.getOrThrow())}
}
func rpcPrepareFailureData113(value:OwnedFailureDataConsumer113,id:String,command:String,
    protocol:Int64):Result<RpcOwnedFailureDelivery113> {
    match(rpcPrepayFailureControl113(value,4096)) {
        case Result.Err(error)=>return Result<RpcOwnedFailureDelivery113>.Err(error);case Result.Ok(_)=>()}
    let control=RpcFailureControl113()
    let loan=value.withError({_,fund=>
        control.answer=fund(rpcFailureMetadata113(id,command,""))
        if(control.answer.isOk()){control.selected=Some(RpcOwnedFailureDelivery113(RpcFailureAlias113.Data(value),id,command,"",0,false,protocol))}
    })
    match(loan){case Result.Err(error)=>return Result<RpcOwnedFailureDelivery113>.Err(error);case Result.Ok(_)=>()}
    match(control.answer){case Result.Err(error)=>Result<RpcOwnedFailureDelivery113>.Err(error)
        case Result.Ok(_)=>Result.Ok(control.selected.getOrThrow())}
}

// Exact existing v1/v2 wire limits. A v1 oversize or reassembly overflow is a
// HELD complete failure, never a truncated replacement followed by source ACK.
private func rpcOwnedFailureFraming113(logical:String,protocol:Int64,fund:(Int64)->Result<Unit>,
    nextChunkId:()->String):Result<String> {
    let raw=unsafe{logical.rawData()}
    if(raw.size+1<=1048576){return Result.Ok(logical)}
    if(protocol!=2){return Result<String>.Err(rpcFailureHeldError113())}
    if(raw.size>67108864){return Result<String>.Err(rpcFailureHeldError113())}
    let chunkBytes:Int64=262144
    let count=(raw.size+chunkBytes-1)/chunkBytes
    // Complete current logical String, encoded chunks, growable builder,
    // final joined String and fixed per-frame metadata coexist. The shared
    // owner's original cap may reject; no new bank, truncation or cap increase.
    match(fund(ownedOuterErrorAdd333(2097152,ownedOuterErrorAdd333(
        ownedOuterErrorMultiply333(raw.size,8),ownedOuterErrorMultiply333(count,32768))))) {
        case Result.Err(error)=>return Result<String>.Err(error);case Result.Ok(_)=>() }
    let chunkId=nextChunkId();let output=StringBuilder()
    for(index in 0..count) {
        if(index!=0){output.append("\n")}
        let start=index*chunkBytes;let end=minInt(raw.size,start+chunkBytes)
        output.append(encodeAgentValue(objectValue([
            ValueField("type",textValue("rpc_chunk")),ValueField("chunkId",textValue(chunkId)),
            ValueField("index",integerValue(index)),ValueField("count",integerValue(count)),
            ValueField("byteLength",integerValue(raw.size)),
            ValueField("data",textValue(productBase64Bytes(raw[start..end])))])))
    }
    Result.Ok(output.toString())
}

let RPC_FAILURE_HELD113=AgentError(AgentErrorKind.RecoveryRequired,"rpc.owned_failure_pending",
    "the complete failure is retained until actual output and alias retirement")
func rpcFailureHeldError113():AgentError { RPC_FAILURE_HELD113 }

class ProductRpcFailureSink113 <: OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    // This concrete RPC admission only transfers or refuses the original
    // publication. Output failures are already retained in its queue node.
    private let admit:(OwnedFailureRunPublication113)->Bool
    init(admit:(OwnedFailureRunPublication113)->Bool){this.admit=admit}
    public func admitOwnedFailure113(value:OwnedFailureRunPublication113):OwnedFailureEventAdmissionOutcome113 {
        if(admit(value)){OwnedFailureEventAdmissionOutcome113.Accepted}
        else{OwnedFailureEventAdmissionOutcome113.Held}
    }
    public func emitOwnedFailure113(value:OwnedFailureRunPublication113):Result<Unit> {
        if(admit(value)){Result<Unit>.Ok(())}else{Result<Unit>.Err(rpcFailureHeldError113())}
    }
    public func emitOwnedFailureOutcome113(value:OwnedFailureRunPublication113):OwnedFailureDataOutcome113<Unit> {
        if(admit(value)){OwnedFailureDataOutcome113<Unit>.Value(())}
        else{value.captureFailure113<Unit>(rpcFailureHeldError113())}
    }
}

// The original paid codec renders both complete errors, including frozen
// observations. This only joins their generated JSON at its exact terminal
// error_data boundary; it never parses/copies the errors into a second DOM.
private class RpcQueuedSecondaryEncoding113 {
    var encoded: ?String = None<String>
    var answer = Result<Unit>.Ok(())
}
private func rpcRenderQueuedSecondary113(primary: String, secondary: RpcFailureAlias113,
    fund: (Int64) -> Result<Unit>): Result<String> {
    match (fund(4096)) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
    let control = RpcQueuedSecondaryEncoding113()
    let borrowed = secondary.withError({ error, pay =>
        match (encodeOwnedFailureError113(error, pay)) {
            case Result.Err(error) => control.answer = Result<Unit>.Err(error)
            case Result.Ok(value) => control.encoded = Some(value)
        }
        control.answer
    })
    match (borrowed) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
    let encoded = control.encoded.getOrThrow()
    if (!primary.endsWith("}}") || !encoded.startsWith("{") || !encoded.endsWith("}")) {
        return ownedRpcOutputError<String>("rpc.queued_failure_generated_shape_changed") }
    let suffix = ",\"secondary_errors\":["
    let bytes = ownedOuterErrorAdd333(primary.size, ownedOuterErrorAdd333(encoded.size, suffix.size + 1))
    if (bytes > 67108864) {
        return ownedRpcOutputError<String>("rpc.queued_complete_failure_extent_exceeded") }
    match (fund(ownedOuterErrorAdd333(65536, ownedOuterErrorMultiply333(bytes, 8)))) {
        case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
    let original = primary.toArray(); let appended = encoded.toArray(); let middle = suffix.toArray()
    let cut = original.size - 2
    let total = ownedOuterErrorAdd333(cut, ownedOuterErrorAdd333(middle.size, appended.size + 3))
    let joined = Array<Byte>(total, { index =>
        if (index < cut) { original[index] }
        else if (index < cut + middle.size) { middle[index - cut] }
        else if (index < cut + middle.size + appended.size) { appended[index - cut - middle.size] }
        else if (index == total - 3) { b']' } else { b'}' }
    })
    Result<String>.Ok(String.fromUtf8(joined))
}

func rpcPrepareQueuedFailureData113(primary: OwnedFailureDataConsumer113,
    secondary: ?OwnedFailureDataConsumer113, id: String, command: String,
    protocol: Int64): Result<RpcOwnedFailureDelivery113> {
    let delivery = match (rpcPrepareFailureData113(primary, id, command, protocol)) {
        case Result.Err(error) => return Result<RpcOwnedFailureDelivery113>.Err(error)
        case Result.Ok(value) => value }
    match (secondary) {
        case Some(value) => match (rpcPrepayFailureControl113(value, 4096)) {
            case Result.Err(error) => return Result<RpcOwnedFailureDelivery113>.Err(error)
            case Result.Ok(_) => delivery.installQueuedSecondary113(value) }
        case None => () }
    Result<RpcOwnedFailureDelivery113>.Ok(delivery)
}
