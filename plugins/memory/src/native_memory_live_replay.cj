package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// Plugin business continuation only. These inputs are untrusted data; the
// Host must independently reload the precise actual child Receipt before
// supplying them. Neither this object nor its ordinal grants an effect.
class NativeMemoryReplaySettlement {
    let proposalDigest:String
    let error:?AgentError
    init(proposalDigest:String,error!:?AgentError=None){
        if(!httpIntentDigest(proposalDigest)){throw PureProviderError("memory.live_settlement_invalid","exact proposal digest required")}
        this.proposalDigest=proposalDigest;this.error=error
    }
}

public interface NativeMemoryTransactionGate {
    func beforeAppend(operation:String,records:Array<MemoryV3Record>,expected:?MemoryV3Record):Result<Unit>
}

class NativeMemoryLiveYield <: Exception {
    init(){super("Native Memory yielded before its next original transaction")}
}

enum NativeMemoryReplayOutcome {
    Proposal(NativeMemoryTransactionGroup,String)
    | Completed(Result<ToolResult>)
}

// The private turn owns all new proposal/frame cells until the real producer
// has serialized/hashed/downloaded them. Unit consumers must not retain an
// outcome/Node after close; the actual data RPC owns its own returned slots.
class NativeMemoryReplayTurn {
    private var outcome:?NativeMemoryReplayOutcome
    private let owner:LogicalJsonOwnerReservation
    private var consumed=false
    private var closed=false
    init(outcome:NativeMemoryReplayOutcome,owner:LogicalJsonOwnerReservation){this.outcome=Some(outcome);this.owner=owner}
    func consume(action:(NativeMemoryReplayOutcome)->Unit):Unit{
        if(closed || consumed || outcome.isNone()){throw PureProviderError("memory.live_turn_consumed","same paid turn was already consumed")}
        consumed=true;action(outcome.getOrThrow())
    }
    func close():Unit{if(!closed){outcome=None;closed=true;owner.close()}}
}

// Re-executes the ORIGINAL Native tool method with a frozen input/clock and
// known settlement prefix. Completed groups are applied only after their
// exact original proposal matches; a known rejected group returns its actual
// error at the original appendStates call. The first unsettled group yields
// out of the business call instead of masquerading as an append failure.
class NativeMemoryReplayGate <: NativeMemoryTransactionGate {
    private let settlements:Array<NativeMemoryReplaySettlement>
    private let owner:LogicalJsonOwnerReservation
    private var ordinal:Int64=0
    private var proposed:?NativeMemoryReplayOutcome=None
    init(settlements:Array<NativeMemoryReplaySettlement>,owner:LogicalJsonOwnerReservation){
        this.settlements=settlements;this.owner=owner}
    public func beforeAppend(operation:String,records:Array<MemoryV3Record>,expected:?MemoryV3Record):Result<Unit>{
        var cells:Int64=16
        for(record in records){cells+=64+record.conflictIds.size*2}
        match(expected){case Some(record)=>cells+=64+record.conflictIds.size*2;case None=>()}
        // No full payload/canonical string is made. New event objects share
        // their original immutable strings; a bounded streaming hasher below
        // consumes the complete original canonical grammar through EOF.
        owner.ensureRetainedPeak(1048576+131072+cells*512)
        let events=records.map{record:MemoryV3Record=>memoryV3EventValue(operation,record)}
        let group=NativeMemoryTransactionGroup(ordinal,operation,events,expected)
        let digest=nativeMemoryReplayDigest(group.value(),owner)
        if(ordinal<settlements.size){
            let settlement=settlements[ordinal];ordinal+=1
            if(settlement.proposalDigest!=digest){
                throw PureProviderError("memory.live_proposal_changed","replayed original transaction differs from its exact known settled proposal")}
            return match(settlement.error){case Some(error)=>Result<Unit>.Err(error);case None=>Result<Unit>.Ok(())}
        }
        proposed=Some(NativeMemoryReplayOutcome.Proposal(group,digest))
        throw NativeMemoryLiveYield()
    }
    func yielded():NativeMemoryReplayOutcome{proposed.getOrThrow()}
    func requireWholePrefixConsumed():Unit{
        if(ordinal!=settlements.size){throw PureProviderError("memory.live_prefix_extra","known prefix contains a transaction the original tool did not consume")}
    }
}

func nativeMemoryReplayTurn(history:Array<MemoryV3Record>,nowMillis:Int64,
    settlements:Array<NativeMemoryReplaySettlement>,invoke:(NativeMemoryJournal)->Result<ToolResult>,
    firstAppearance!:Array<String>=[],authoritativeCurrent!:?Array<MemoryV3Record>=None,
    allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()},
    streamSnapshots!:Bool=false):NativeMemoryReplayTurn{
    let owner=allocate(1)
    var transferred=false
    try{
        owner.ensureRetainedPeak(1048576+131072)
        let gate=NativeMemoryReplayGate(settlements,owner)
        let journal=NativeMemoryJournal(history,nowMillis,firstAppearance:firstAppearance,
            authoritativeCurrent:authoritativeCurrent,transactionGate:Some(gate),
            snapshotOwner:if(streamSnapshots){Some(owner)}else{None})
        let outcome:NativeMemoryReplayOutcome=try{
            let result=invoke(journal);gate.requireWholePrefixConsumed();NativeMemoryReplayOutcome.Completed(result)
        }catch(_:NativeMemoryLiveYield){gate.yielded()}
        let turn=NativeMemoryReplayTurn(outcome,owner);transferred=true;turn
    }finally{if(!transferred){owner.close()}}
}

// Complete byte-equivalent canonicalAgentValue stream, including the
// original length framing and lexical object-field order. It avoids a full
// canonical string or toArray of a 63 MiB content field. This is correlation
// data only, never a private-row/global-fence digest or permission.
class NativeMemoryReplayCanonicalSink {
    private let hash=SHA256()
    private let buffer=Array<Byte>(65536,repeat:0)
    private var used:Int64=0
    func text(value:String):Unit{for(i in 0..value.size){buffer[used]=value[i];used+=1;if(used==buffer.size){flush()}}}
    private func flush():Unit{if(used>0){hash.write(buffer[..used]);used=0}}
    func finish():String{flush();logicalJsonEncodeHex(hash.finish())}
}

func nativeMemoryReplayCanonicalBytes(value:AgentValue):Int64{
    match(value.unifiedKind){
        case ValueKind.Null=>4
        case ValueKind.Boolean=>if(value.asBool()){4}else{5}
        case ValueKind.Number=>1+nativeMemoryReplayFramedBytes(value.asNumberText().size)
        case ValueKind.Text=>1+nativeMemoryReplayFramedBytes(value.text.size)
        case ValueKind.List=>
            var size:Int64=2;for(item in value.items){size+=nativeMemoryReplayFramedBytes(nativeMemoryReplayCanonicalBytes(item))};size
        case ValueKind.Object=>
            var size:Int64=2;for(field in value.fields){size+=nativeMemoryReplayFramedBytes(field.name.size)+nativeMemoryReplayFramedBytes(nativeMemoryReplayCanonicalBytes(field.value))};size
    }
}
func nativeMemoryReplayFramedBytes(bytes:Int64):Int64{bytes.toString().size+1+bytes}
func nativeMemoryReplayCanonicalWrite(value:AgentValue,sink:NativeMemoryReplayCanonicalSink):Unit{
    match(value.unifiedKind){
        case ValueKind.Null=>sink.text("null")
        case ValueKind.Boolean=>sink.text(if(value.asBool()){"true"}else{"false"})
        case ValueKind.Number=>let text=value.asNumberText();sink.text("n"+text.size.toString()+":");sink.text(text)
        case ValueKind.Text=>let text=value.text;sink.text("s"+text.size.toString()+":");sink.text(text)
        case ValueKind.List=>
            sink.text("[");for(item in value.items){sink.text(nativeMemoryReplayCanonicalBytes(item).toString()+":");nativeMemoryReplayCanonicalWrite(item,sink)};sink.text("]")
        case ValueKind.Object=>
            sink.text("{");let used=Array<Bool>(value.fields.size,repeat:false)
            for(_ in 0..value.fields.size){
                var selected:Int64=-1
                for(index in 0..value.fields.size where !used[index]){
                    if(selected<0 || value.fields[index].name<value.fields[selected].name){selected=index}}
                used[selected]=true;let field=value.fields[selected]
                sink.text(field.name.size.toString()+":");sink.text(field.name)
                sink.text(nativeMemoryReplayCanonicalBytes(field.value).toString()+":");nativeMemoryReplayCanonicalWrite(field.value,sink)
            };sink.text("}")
    }
}
func nativeMemoryReplayDigest(value:AgentValue,owner:LogicalJsonOwnerReservation):String{
    owner.ensureRetainedPeak(1048576+131072+nativeMemoryReplayCells(value)*512)
    let sink=NativeMemoryReplayCanonicalSink();nativeMemoryReplayCanonicalWrite(value,sink);sink.finish()
}
private func nativeMemoryReplayCells(value:AgentValue):Int64{
    match(value.unifiedKind){
        case ValueKind.List=>var cells:Int64=1;for(item in value.items){cells+=nativeMemoryReplayCells(item)};cells
        case ValueKind.Object=>var cells:Int64=1;for(field in value.fields){cells+=2+nativeMemoryReplayCells(field.value)};cells
        case _=>1
    }
}

// The caller's actual history/input custody keeps the immutable record Strings
// alive. A detached record forwards those same Strings; only its conflict-ID
// array and record cells are copied. One paid temporary record DOM at a time
// preserves the original list framing and original record canonical bytes.
// No complete corpus DOM, canonical String or hash input byte array is made.
func nativeMemoryOwnedSnapshotDigest(records:Array<MemoryV3Record>,ancestor:LogicalJsonOwnerReservation):String{
    let scratch=ancestor.deriveRetainedLease()
    try{
        scratch.ensureRetainedPeak(1048576+131072)
        let sink=NativeMemoryReplayCanonicalSink();sink.text("[")
        for(record in records){
            scratch.ensureRetainedPeak(1048576+131072+(128+record.conflictIds.size*4)*512)
            let node=memoryV3RecordValue(record)
            sink.text(nativeMemoryReplayCanonicalBytes(node).toString()+":")
            nativeMemoryReplayCanonicalWrite(node,sink)
        }
        sink.text("]");sink.finish()
    }finally{scratch.close()}
}
