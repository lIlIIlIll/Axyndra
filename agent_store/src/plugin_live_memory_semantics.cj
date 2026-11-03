package agent_store

import agent_domain.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Data only. Full decoded UTF8 string bytes enter SHA state, while only the
// actual SQL/access labels are retained. Original integer/default/clamp and
// conflictIds string-filter semantics follow memoryV3RecordFromValue exactly.
private let liveMemoryTextFields297=["id","kind","scopeKind","scopeKey","content","context","source","status",
    "correctionOf","replacementId","conflictReason","deletionReason"]
private let liveMemoryIntegerFields297=["importancePermille","expiresAt","createdAt","updatedAt","deletedAt","revision"]
private let liveMemoryRecordFields297=["id","kind","scopeKind","scopeKey","content","context","source",
    "importancePermille","status","expiresAt","correctionOf","replacementId","conflictIds","conflictReason",
    "deletionReason","createdAt","updatedAt","deletedAt","revision"]

func liveMemoryMultiply297(bytes:Int64,factor:Int64):Int64{
    if(bytes<0 || factor<0 || (factor>0 && bytes>Int64.Max/factor)){
        throw LogicalJsonPayloadError("original live metadata accounting overflow")}
    bytes*factor
}

class LiveMemoryScalar297 {
    let name:String
    let kind:String
    private let hash=SHA256()
    private let buffer=ArrayList<Byte>()
    private let retained=ArrayList<Byte>()
    private let keep:Bool
    private let owner:LogicalJsonOwnerReservation
    private let invoice:()->Int64
    var bytes:Int64=0
    var digest=""
    var integer:Int64=0
    var integerValid=false
    var text=""
    init(name:String,kind:String,owner:LogicalJsonOwnerReservation,invoice:()->Int64){
        this.name=name;this.kind=kind;this.owner=owner;this.invoice=invoice
        this.keep=["id","kind","scopeKind","scopeKey","status","operation","schema"].contains(name)
    }
    func append(raw:Array<Byte>):Unit{
        if(raw.isEmpty() || raw.size>4 || raw.size>Int64.Max-bytes){throw IllegalStateException("live original scalar changed its decoded extent")}
        if(keep){
            owner.ensureRetainedPeak(journalStreamAdd(invoice(),journalStreamAdd(2097152,
                liveMemoryMultiply297(journalStreamAdd(retained.size,raw.size),32))))
            retained.add(all:raw)
        }else if(kind=="number" && retained.size<21){
            if(retained.size+raw.size<=21){retained.add(all:raw)}
        }
        bytes+=raw.size
        buffer.add(all:raw)
        if(buffer.size>=65536){flush()}
    }
    private func flush():Unit{if(!buffer.isEmpty()){hash.write(buffer.toArray());buffer.clear()}}
    func finish():Unit{
        flush();digest=logicalJsonEncodeHex(hash.finish())
        if(keep && kind=="string"){text=String.fromUtf8(retained.toArray())}
        if(kind=="number" && bytes<=21){try{integer=Int64.parse(String.fromUtf8(retained.toArray()));integerValid=true}catch(_:Exception){integer=0}}
        retained.clear()
    }
}

class LiveMemorySemanticRecord297 {
    private let owner:LogicalJsonOwnerReservation
    private let retainedPeak:()->Int64
    private let fields=HashMap<String,LiveMemoryScalar297>()
    private let conflicts=SHA256()
    private var conflictCount:Int64=0
    private var activeConflict:?LiveMemoryScalar297=None<LiveMemoryScalar297>
    private var conflictArray=false
    private var closed=false
    private var fingerprint=""
    let rawStart:Int64
    var rawEnd:Int64=0
    var id=""
    var kind=""
    var scopeKind=""
    var scopeKey=""
    var status=""
    var revision:Int64=0
    var updatedAt:Int64=0
    init(rawStart:Int64,owner:LogicalJsonOwnerReservation,retainedPeak:()->Int64){
        this.rawStart=rawStart;this.owner=owner;this.retainedPeak=retainedPeak
        owner.ensureRetainedPeak(journalStreamAdd(retainedPeak(),2097152))
    }
    func retainedLabelBytes():Int64{
        var bytes:Int64=0
        for(name in ["id","kind","scopeKind","scopeKey","status"]){
            match(fields.get(name)){case Some(value)=>bytes=journalStreamAdd(bytes,value.text.size);case None=>()}}
        bytes
    }
    func begin(path:Array<String>,base:Int64,kind:String,start:Int64):Unit{
        if(closed){throw IllegalStateException("live semantic record is already consumed")}
        if(path.size==base+1){
            let name=path[base]
            if(liveMemoryTextFields297.contains(name) || liveMemoryIntegerFields297.contains(name)){
                owner.ensureRetainedPeak(journalStreamAdd(retainedPeak(),2097152+fields.size*1024))
                fields[name]=LiveMemoryScalar297(name,kind,owner,{=>journalStreamAdd(retainedPeak(),liveMemoryMultiply297(retainedLabelBytes(),32))})
            }else if(name=="conflictIds"){conflictArray=kind=="array"}
        }else if(conflictArray && path.size==base+2 && path[base]=="conflictIds" && kind=="string"){
            activeConflict=Some(LiveMemoryScalar297("conflictId",kind,owner,retainedPeak))
        }
    }
    func scalar(path:Array<String>,base:Int64,kind:String,raw:Array<Byte>):Unit{
        if(path.size==base+1){
            match(fields.get(path[base])){case Some(value)=>if(value.kind==kind){value.append(raw)};case None=>()}
        }else if(conflictArray && path.size==base+2 && path[base]=="conflictIds" && kind=="string"){
            match(activeConflict){case Some(value)=>value.append(raw);case None=>throw IllegalStateException("live filtered string lacks its real hash state")}
        }
    }
    func end(path:Array<String>,base:Int64,kind:String,start:Int64,end:Int64):Unit{
        if(path.size==base+1){
            match(fields.get(path[base])){case Some(value)=>value.finish();case None=>()}
        }else if(conflictArray && path.size==base+2 && path[base]=="conflictIds" && kind=="string"){
            let value=activeConflict.getOrThrow();value.finish()
            conflicts.write(journalStreamFrame(value.bytes.toString()).toArray())
            conflicts.write(journalStreamFrame(value.digest).toArray())
            conflictCount=journalStreamAdd(conflictCount,1);activeConflict=None<LiveMemoryScalar297>
        }
    }
    private func text(name:String):String{
        match(fields.get(name)){case Some(value)=>if(value.kind=="string"){value.text}else{""};case None=>""}
    }
    private func number(name:String):Int64{
        match(fields.get(name)){case Some(value)=>if(value.kind=="number"){value.integer}else{0};case None=>0}
    }
    func finish(end:Int64):Unit{
        if(closed || activeConflict.isSome()){throw IllegalStateException("live full semantic record has an unfinished member")}
        rawEnd=end;id=text("id");kind=text("kind");scopeKind=text("scopeKind");scopeKey=text("scopeKey");status=text("status")
        revision=number("revision");updatedAt=number("updatedAt")
        let content=fields.get("content")
        if(id=="" || content.isNone() || content.getOrThrow().kind!="string" || content.getOrThrow().bytes==0 ||
            !["preference","project_fact","decision","constraint","observation"].contains(kind) ||
            !["global","user","workspace","session"].contains(scopeKind) ||
            (scopeKind=="global" && scopeKey!="") || (scopeKind!="global" && scopeKey=="") ||
            !["active","corrected","conflicted","deleted","expired"].contains(status)){
            throw IllegalStateException("original Memory record is incomplete")}
        let hash=SHA256();hash.write("axyndra.memory-record-normalized-fields/v1".toArray())
        for(name in liveMemoryRecordFields297){
            hash.write(journalStreamFrame(name).toArray())
            if(name=="conflictIds"){
                hash.write(journalStreamFrame(conflictCount.toString()).toArray())
                hash.write(journalStreamFrame(logicalJsonEncodeHex(conflicts.finish())).toArray())
            }else if(liveMemoryIntegerFields297.contains(name)){
                let value=number(name)
                hash.write(journalStreamFrame((if(name=="importancePermille"){max(0,min(1000,value))}else{value}).toString()).toArray())
            }else{
                match(fields.get(name)){
                    case Some(value)=>if(value.kind=="string"){
                        hash.write(journalStreamFrame(value.bytes.toString()).toArray());hash.write(journalStreamFrame(value.digest).toArray())
                    }else{hash.write(journalStreamFrame("0").toArray());hash.write(journalStreamFrame(modelPolicySha256Text("")).toArray())}
                    case None=>hash.write(journalStreamFrame("0").toArray());hash.write(journalStreamFrame(modelPolicySha256Text("")).toArray())}
            }
        }
        fingerprint=logicalJsonEncodeHex(hash.finish());closed=true
    }
    func semanticFingerprint():String{if(!closed){throw IllegalStateException("semantic record has not reached its complete record end")};fingerprint}
    func sameNormalizedNumbers(other:LiveMemorySemanticRecord297):Bool{
        if(!closed || !other.closed){throw IllegalStateException("original numeric equality needs two finished records")}
        for(name in liveMemoryIntegerFields297){
            let a=number(name);let b=other.number(name)
            if((if(name=="importancePermille"){max(0,min(1000,a))}else{a})!=
                (if(name=="importancePermille"){max(0,min(1000,b))}else{b})){return false}
        }
        true
    }
    func accessLabels():AgentValue{
        if(!closed){throw IllegalStateException("actual access labels are unfinished")}
        objectValue([ValueField("id",textValue(id)),ValueField("kind",textValue(kind)),
            ValueField("scopeKind",textValue(scopeKind)),ValueField("scopeKey",textValue(scopeKey))])
    }
}
