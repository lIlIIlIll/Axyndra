package agent_store

import agent_domain.*
import std.collection.*
import std.convert.*

class LiveMemoryProposalEvent298 {
    let rawStart:Int64
    var rawEnd:Int64=0
    var record:?LiveMemorySemanticRecord297=None<LiveMemorySemanticRecord297>
    var version:?LiveMemoryScalar297=None<LiveMemoryScalar297>
    var operation:?LiveMemoryScalar297=None<LiveMemoryScalar297>
    var digest=""
    init(start:Int64){rawStart=start}
}

// One ORIGINAL appendStates transaction group. Compact descriptors coexist
// in the same actual reservation; there is no extra aggregate/item cap and no
// full content/context/source String, original proposal DOM or canonical copy.
class LiveMemoryProposalGroup298 {
    private let owner:LogicalJsonOwnerReservation
    private let outsidePeak:Int64
    private let rootFields=HashSet<String>()
    private let scalars=HashMap<String,LiveMemoryScalar297>()
    private var eventsArray=false
    private var expectedSeen=false
    private var closed=false
    let events=ArrayList<LiveMemoryProposalEvent298>()
    var expected:?LiveMemorySemanticRecord297=None<LiveMemorySemanticRecord297>
    var ordinal:Int64= -1
    var operation=""
    init(owner:LogicalJsonOwnerReservation,outsidePeak:Int64){
        this.owner=owner;this.outsidePeak=outsidePeak;pay(0)
    }
    private func peak():Int64{
        var bytes:Int64=0
        for(event in events){
            match(event.record){case Some(record)=>bytes=journalStreamAdd(bytes,record.retainedLabelBytes());case None=>()}
            match(event.operation){case Some(value)=>bytes=journalStreamAdd(bytes,value.text.size);case None=>()}
        }
        match(expected){case Some(record)=>bytes=journalStreamAdd(bytes,record.retainedLabelBytes());case None=>()}
        for(name in ["schema","operation"]){match(scalars.get(name)){case Some(value)=>bytes=journalStreamAdd(bytes,value.text.size);case None=>()}}
        return journalStreamAdd(outsidePeak,journalStreamAdd(4194304,journalStreamAdd(
            liveMemoryMultiply297(bytes,32),liveMemoryMultiply297(events.size,8192))))
    }
    private func pay(extra:Int64):Unit{owner.ensureRetainedPeak(journalStreamAdd(peak(),extra))}
    func retainedPeak():Int64{peak()}
    private func event(path:Array<String>):LiveMemoryProposalEvent298{
        let index=Int64.parse(path[1])
        if(index<0 || index>=events.size){throw IllegalStateException("original complete event ordinal was not admitted")}
        events[index]
    }
    func begin(path:Array<String>,kind:String,start:Int64):Unit{
        if(closed){throw IllegalStateException("original live group has already finished")}
        if(path.isEmpty()){
            if(kind!="object"){throw IllegalStateException("original live transaction group is not an object")};return}
        if(path.size==1){
            let name=path[0];rootFields.add(name)
            if(["schema","operation","ordinal"].contains(name)){
                pay(1024);scalars[name]=LiveMemoryScalar297(name,kind,owner,{=>peak()})
            }else if(name=="events"){
                if(kind!="array"){throw IllegalStateException("original transaction events are not a complete array")};eventsArray=true
            }else if(name=="expected_record"){
                expectedSeen=true
                if(kind=="object"){pay(8192);expected=Some(LiveMemorySemanticRecord297(start,owner,{=>peak()}))}
                else if(kind!="null"){throw IllegalStateException("original expected record is neither object nor null")}
            }else{throw IllegalStateException("original group changed its exact five-field schema")}
            return
        }
        if(path[0]=="expected_record"){
            match(expected){case Some(record)=>record.begin(path,1,kind,start);case None=>()};return}
        if(path[0]!="events" || !eventsArray){return}
        if(path.size==2){
            if(kind!="object" || Int64.parse(path[1])!=events.size){throw IllegalStateException("original transaction event order or shape changed")}
            pay(8192);events.add(LiveMemoryProposalEvent298(start));return}
        let current=event(path)
        if(path.size==3 && path[2]=="record"){
            if(kind!="object"){throw IllegalStateException("original event record is not an object")}
            pay(8192);current.record=Some(LiveMemorySemanticRecord297(start,owner,{=>peak()}))
        }else if(path.size==3 && ["version","operation"].contains(path[2])){
            pay(1024);let value=LiveMemoryScalar297(path[2],kind,owner,{=>peak()})
            if(path[2]=="version"){current.version=Some(value)}else{current.operation=Some(value)}
        }else if(path.size>3 && path[2]=="record"){
            match(current.record){case Some(record)=>record.begin(path,3,kind,start);case None=>()}
        }
    }
    func scalar(path:Array<String>,kind:String,raw:Array<Byte>):Unit{
        if(path.size==1){match(scalars.get(path[0])){case Some(value)=>value.append(raw);case None=>()};return}
        if(!path.isEmpty() && path[0]=="expected_record"){
            match(expected){case Some(record)=>record.scalar(path,1,kind,raw);case None=>()};return}
        if(path.size<3 || path[0]!="events"){return}
        let current=event(path)
        if(path.size==3 && path[2]=="version"){match(current.version){case Some(value)=>value.append(raw);case None=>()}}
        else if(path.size==3 && path[2]=="operation"){match(current.operation){case Some(value)=>value.append(raw);case None=>()}}
        else if(path.size>3 && path[2]=="record"){
            match(current.record){case Some(record)=>record.scalar(path,3,kind,raw);case None=>()}
        }
    }
    func end(path:Array<String>,kind:String,start:Int64,end:Int64):Unit{
        if(path.size==1){
            match(scalars.get(path[0])){case Some(value)=>value.finish();case None=>()}
            if(path[0]=="expected_record" && kind=="object"){expected.getOrThrow().finish(end)}
            return
        }
        if(!path.isEmpty() && path[0]=="expected_record"){
            match(expected){case Some(record)=>record.end(path,1,kind,start,end);case None=>()};return}
        if(path.size<2 || path[0]!="events"){return}
        let current=event(path)
        if(path.size==2){current.rawEnd=end}
        else if(path.size==3 && path[2]=="record"){current.record.getOrThrow().finish(end)}
        else if(path.size==3 && path[2]=="version"){current.version.getOrThrow().finish()}
        else if(path.size==3 && path[2]=="operation"){current.operation.getOrThrow().finish()}
        else if(path.size>3 && path[2]=="record"){
            match(current.record){case Some(record)=>record.end(path,3,kind,start,end);case None=>()}
        }
    }
    // Caller invokes only after the scanner's WHOLE group grammar/EOF/SHA and
    // all actual fixed-FD/member close ACKs succeed. This object conveys data;
    // Store independently repeats full Prepared/Root/pin and actual semCAS.
    func finish(sequence:Int64):Unit{
        if(closed || rootFields.size!=5 || !expectedSeen || !eventsArray || events.isEmpty()){
            throw IllegalStateException("original whole transaction group did not complete its five fields")}
        let schema=scalars.get("schema").getOrThrow();let number=scalars.get("ordinal").getOrThrow()
        let operationValue=scalars.get("operation").getOrThrow()
        if(schema.kind!="string" || schema.text!="axyndra.memory-transaction-proposal/v1" ||
            number.kind!="number" || !number.integerValid || number.integer!=sequence-1 || operationValue.kind!="string" || operationValue.text==""){
            throw IllegalStateException("original proposal changed its exact schema/ordinal/operation")}
        ordinal=number.integer;operation=operationValue.text
        for(event in events){
            if(event.rawEnd<=event.rawStart || event.rawEnd-event.rawStart>67108864 || event.record.isNone() ||
                event.version.isNone() || event.version.getOrThrow().kind!="number" || event.version.getOrThrow().integer!=3 ||
                event.operation.isNone() || event.operation.getOrThrow().kind!="string" || event.operation.getOrThrow().text!=operation){
                throw IllegalStateException("original full event codec or group operation changed")}
            let _=event.record.getOrThrow().semanticFingerprint()
        }
        closed=true;pay(0)
    }
}
