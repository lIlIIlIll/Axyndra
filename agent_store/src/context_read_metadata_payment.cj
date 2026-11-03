package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// All names/SQL below are closed Store-owned metadata readers. They measure
// actual same-TX cells, never a Native invoice, Source or read permission.
class ContextReadMetadataCell {
    let bytes:Int64
    let nodes:Int64
    init(bytes:Int64,nodes:Int64){this.bytes=bytes;this.nodes=nodes}
}
func contextReadMetadataPeak(bytes:Int64,nodes:Int64):Int64{
    if(bytes<0 || nodes<0 || bytes>Int64.Max/8 || nodes>Int64.Max/512){throw IllegalStateException("canonical metadata payment overflow")}
    journalStreamAdd(1048576,journalStreamAdd(bytes*8,nodes*512))
}
func contextReadMetadataRawPeak(bytes:Int64):Int64{
    if(bytes<0 || bytes>(Int64.Max-1048576)/4){throw IllegalStateException("canonical metadata raw payment overflow")}
    1048576+bytes*4
}
func withContextReadMetadataCell<T>(tx:SqliteTransaction,lengthSql:String,valueSql:String,
    parameters:Array<SqlParameter>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(String,StoredValuePaymentMeter)->T):T{
    journalStreamCheck(guard)
    let lengths=tx.query(lengthSql,parameters)
    if(lengths.size!=1){throw IllegalStateException("canonical metadata cell is missing or duplicated")}
    let bytes=journalStreamInteger(lengths[0].required(0))
    if(bytes<1 || bytes>8388608){throw IllegalStateException("stored value exceeds its original 8 MiB codec")}
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(contextReadMetadataRawPeak(bytes))
        let rows=tx.query(valueSql,parameters)
        if(rows.size!=1 || rows[0].required(0).size!=bytes){throw IllegalStateException("canonical metadata extent changed")}
        let meter=StoredValuePaymentMeter(rows[0].required(0),owner);let _=meter.complete()
        journalStreamCheck(guard);let result=consume(rows[0].required(0),meter);journalStreamCheck(guard);result
    }finally{owner.close()}
}
func contextReadMetadataMeasure(tx:SqliteTransaction,column:String,suffix:String,parameters:Array<SqlParameter>,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):ContextReadMetadataCell{
    withContextReadMetadataCell(tx,"SELECT length(CAST("+column+" AS BLOB))"+suffix,"SELECT "+column+suffix,
        parameters,allocate,guard,{raw,meter=>ContextReadMetadataCell(raw.size,meter.nodeCount())})
}
func withContextReadMetadataStage<T>(cells:Array<ContextReadMetadataCell>,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:()->T):T{
    var bytes:Int64=0;var nodes:Int64=0
    for(cell in cells){bytes=journalStreamAdd(bytes,cell.bytes);nodes=journalStreamAdd(nodes,cell.nodes)}
    let charge=allocate(65536)
    try{charge.ensureRetainedPeak(contextReadMetadataPeak(bytes,nodes));journalStreamCheck(guard)
        let result=consume();journalStreamCheck(guard);result}finally{charge.close()}
}

// One bounded result at a time; every ignored body byte still reaches the
// ORIGINAL Store framing EOF. No turn array, count cap or aggregate invoice.
func withContextReadToolResultPaid(tx:SqliteTransaction,rowid:Int64,thread:String,turn:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(ThreadItemContent)->Unit):Unit{
    let suffix=" FROM items WHERE rowid=? AND thread_id=? AND turn_id=? AND kind='tool_result'"
    let parameters=[SqlParameter.Int64Value(rowid),SqlParameter.Text(thread),SqlParameter.Text(turn)]
    withContextReadMetadataCell(tx,"SELECT length(CAST(payload AS BLOB))"+suffix,"SELECT payload"+suffix,
        parameters,allocate,guard,{_,meter=>consume(decodeStoredThreadContent(encodeStoredValue(meter.consumptionHeader())))})
}
func eachContextReadToolResultPaid(tx:SqliteTransaction,thread:String,turn:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(ThreadItemContent)->Unit):Unit{
    var after:?Int64=None
    while(true){
        journalStreamCheck(guard)
        let rows=match(after){
            case None=>tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result' ORDER BY rowid LIMIT 1",
                [SqlParameter.Text(thread),SqlParameter.Text(turn)])
            case Some(last)=>tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result' AND rowid>? ORDER BY rowid LIMIT 1",
                [SqlParameter.Text(thread),SqlParameter.Text(turn),SqlParameter.Int64Value(last)])}
        if(rows.isEmpty()){break};let rowid=journalStreamInteger(rows[0].required(0))
        withContextReadToolResultPaid(tx,rowid,thread,turn,allocate,guard,consume);after=Some(rowid)
    }
    journalStreamCheck(guard)
}


// Explicit borrowed scanner. No fake allocation callback, separate floor,
// close, refund or owner adoption. Every complete original byte/UTF8/frame/
// count/duplicate/depth/node/EOF check stays in StoredValuePaymentMeter.
func withContextReadMetadataCellOwned<T>(tx:SqliteTransaction,lengthSql:String,valueSql:String,
    parameters:Array<SqlParameter>,owner:LogicalJsonOwnerReservation,extraRetained:Int64,guard:()->Result<Unit>,
    consume:(String,StoredValuePaymentMeter)->T):T{
    if(extraRetained<0){throw IllegalStateException("borrowed cell retained peak is negative")}
    journalStreamCheck(guard)
    let lengths=tx.query(lengthSql,parameters)
    if(lengths.size!=1){throw IllegalStateException("canonical metadata cell is missing or duplicated")}
    let bytes=journalStreamInteger(lengths[0].required(0))
    if(bytes<1 || bytes>8388608){throw IllegalStateException("stored value exceeds its original 8 MiB codec")}
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,contextReadMetadataRawPeak(bytes)))
    let rows=tx.query(valueSql,parameters)
    if(rows.size!=1 || rows[0].required(0).size!=bytes){throw IllegalStateException("canonical metadata extent changed")}
    let meter=StoredValuePaymentMeter(rows[0].required(0),owner,extraRetained:extraRetained);let _=meter.complete()
    journalStreamCheck(guard);let result=consume(rows[0].required(0),meter);journalStreamCheck(guard);result
}
func contextReadMetadataMeasureOwned(tx:SqliteTransaction,column:String,suffix:String,parameters:Array<SqlParameter>,
    owner:LogicalJsonOwnerReservation,extraRetained:Int64,guard:()->Result<Unit>):ContextReadMetadataCell{
    withContextReadMetadataCellOwned(tx,"SELECT length(CAST("+column+" AS BLOB))"+suffix,"SELECT "+column+suffix,
        parameters,owner,extraRetained,guard,{raw,meter=>ContextReadMetadataCell(raw.size,meter.nodeCount())})
}
func eachContextReadToolResultOwned(tx:SqliteTransaction,thread:String,turn:String,
    owner:LogicalJsonOwnerReservation,extraRetained:Int64,guard:()->Result<Unit>,consume:(ThreadItemContent)->Unit):Unit{
    var after:?Int64=None
    while(true){
        journalStreamCheck(guard)
        let rows=match(after){
            case None=>tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result' ORDER BY rowid LIMIT 1",
                [SqlParameter.Text(thread),SqlParameter.Text(turn)])
            case Some(last)=>tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result' AND rowid>? ORDER BY rowid LIMIT 1",
                [SqlParameter.Text(thread),SqlParameter.Text(turn),SqlParameter.Int64Value(last)])}
        if(rows.isEmpty()){break};let rowid=journalStreamInteger(rows[0].required(0))
        let suffix=" FROM items WHERE rowid=? AND thread_id=? AND turn_id=? AND kind='tool_result'"
        let parameters=[SqlParameter.Int64Value(rowid),SqlParameter.Text(thread),SqlParameter.Text(turn)]
        withContextReadMetadataCellOwned(tx,"SELECT length(CAST(payload AS BLOB))"+suffix,"SELECT payload"+suffix,
            parameters,owner,extraRetained,guard,{_,meter=>
                consume(decodeStoredThreadContent(encodeStoredValue(meter.consumptionHeader())))})
        after=Some(rowid)
    }
    journalStreamCheck(guard)
}

class ContextReadBorrowedProjectionCapture {var value=""}
class ContextReadBorrowedParentProjectedNodes {var head:Int64=0;var provenance:Int64=0}

class ContextReadPaidParent {
    let row:SqliteRow
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let guard:()->Result<Unit>
    private let provenance:ContextReadMetadataCell
    private let skill:ContextReadMetadataCell
    private let phaseStage:?((ContextReadMetadataCell,()->Unit)->Unit)
    init(row:SqliteRow,provenance:ContextReadMetadataCell,skill:ContextReadMetadataCell,
        allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
        phaseStage!:?((ContextReadMetadataCell,()->Unit)->Unit)=None){
        this.row=row;this.provenance=provenance;this.skill=skill;this.allocate=allocate;this.guard=guard
        this.phaseStage=phaseStage}
    func projection():String{
        match(phaseStage){case Some(stage)=>
            let captured=ContextReadBorrowedProjectionCapture()
            stage(skill,{=>captured.value=contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(row.required(6))))})
            return captured.value
            case None=>()}
        withContextReadMetadataStage([skill],allocate,guard,
            {=>contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(row.required(6))))})
    }
    func withProvenance(consume:(ItemProvenance)->Unit):Unit{
        match(phaseStage){case Some(stage)=>stage(provenance,{=>consume(decodeStoredProvenance(row.required(1)))});return
            case None=>()}
        withContextReadMetadataStage([provenance],allocate,guard,{=>consume(decodeStoredProvenance(row.required(1)))})
    }
}

// The only permanent charge holds private ORIGINAL Source/canonical strings
// for SQL equality polling plus the small strict read plan/fact returned to
// the proof. Full Origin/Continuation/parent/turn DOM owns separate phases.
class ContextReadCompletedMetadataPayment {
    private let tx:SqliteTransaction
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let guard:()->Result<Unit>
    private let charge:LogicalJsonOwnerReservation
    private let link:ContextReadFactLink
    private var original:Array<String>=[]
    private var sourceCells:Array<ContextReadMetadataCell>=[]
    private var auditCells:Array<ContextReadMetadataCell>=[]
    private var skill:?ContextReadMetadataCell=None
    private var continuation:Array<ContextReadMetadataCell>=[]
    private let borrowedPhases:Bool
    private let knownCommitStreamingResults:Bool
    private let externalRetained:Int64
    private var permanentPeak:Int64=0
    private var activePhasePeak:Int64=0
    private var borrowedClosed=false
    init(tx:SqliteTransaction,link:ContextReadFactLink,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
        phaseOwner!:?LogicalJsonOwnerReservation=None,extraRetained!:Int64=0,knownCommitStreamingResults!:Bool=false){
        this.tx=tx;this.link=link;this.allocate=allocate;this.guard=guard
        if(extraRetained<0){throw IllegalStateException("canonical metadata retained payment is negative")}
        this.borrowedPhases=phaseOwner.isSome();this.externalRetained=extraRetained
        this.knownCommitStreamingResults=knownCommitStreamingResults
        let owner=match(phaseOwner){case Some(actual)=>actual;case None=>allocate(65536)}
        this.charge=owner
        try{
            let parameters=[SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)]
            let source=" FROM operations o JOIN runs r ON r.id=o.run_id JOIN items call ON call.id=o.tool_call_item_id "+
                "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id "+
                "JOIN operation_receipts receipt ON receipt.id=e.reserved_receipt_id AND receipt.operation_id=o.id "+
                "JOIN items result ON result.id=e.reserved_result_item_id WHERE o.id=? AND o.run_id=?"
            let cells=ArrayList<ContextReadMetadataCell>();var bytes:Int64=0;var escapingNodes:Int64=0
            for(column in ["o.normalized_plan","call.payload","call.provenance","receipt.detail","result.payload"]){
                let cell=measureMetadataCell(owner,column,source,parameters)
                cells.add(cell);bytes=journalStreamAdd(bytes,cell.bytes);escapingNodes=journalStreamAdd(escapingNodes,cell.nodes)}
            this.sourceCells=cells.toArray();let audits=ArrayList<ContextReadMetadataCell>();let auditBytes=ArrayList<String>()
            for(kind in ["context_read_admitted","operation_execution_handoff","plugin_document_latest_journal_observed"]){
                let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND kind=?"
                let params=[SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value),SqlParameter.Text(kind)]
                let cell=measureMetadataCell(owner,"payload",suffix,params)
                if(kind=="plugin_document_latest_journal_observed" && cell.bytes>65536){throw IllegalStateException("journal observation exceeds its original metadata ceiling")}
                audits.add(cell);bytes=journalStreamAdd(bytes,cell.bytes)
                payPermanent(owner,journalStreamAdd(contextReadMetadataRawPeak(bytes),escapingNodes*1024))
                let actual=tx.query("SELECT payload"+suffix,params)
                if(actual.size!=1 || actual[0].required(0).size!=cell.bytes){throw IllegalStateException("actual audit extent changed")}
                auditBytes.add(actual[0].required(0))}
            this.auditCells=audits.toArray()
            let runParameters=[SqlParameter.Text(link.runId.value)]
            let skill=measureMetadataCell(owner,"skill_snapshot"," FROM runs WHERE id=?",runParameters)
            this.skill=Some(skill);bytes=journalStreamAdd(bytes,skill.bytes)
            payPermanent(owner,journalStreamAdd(contextReadMetadataRawPeak(bytes),escapingNodes*1024))
            let captured=tx.query("SELECT o.normalized_plan,call.payload,call.provenance,receipt.detail,result.payload,r.skill_snapshot"+source,parameters)
            if(captured.size!=1){throw IllegalStateException("canonical completed metadata capture is not unique")}
            let originals=ArrayList<String>();for(index in 0..6){originals.add(captured[0].required(index))}
            for(raw in auditBytes){originals.add(raw)};this.original=originals.toArray()

            let continuation=ArrayList<ContextReadMetadataCell>()
            let initial=" FROM runs r JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id "+
                "JOIN items i ON i.id=t.user_item_id AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id WHERE r.id=?"
            let initiators=tx.query("SELECT i.kind"+initial,runParameters)
            if(initiators.size!=1){throw IllegalStateException("canonical Run initiator is missing")}
            if(initiators[0].required(0)!="user_message"){
                for(column in ["i.payload","i.provenance","r.budget"]){continuation.add(measureMetadataCell(owner,column,initial,runParameters))}
                continuation.add(measureMetadataCell(owner,"payload"," FROM audit_events WHERE run_id=? AND kind='host_continuation_claim_consumed_v1'",runParameters))
                continuation.add(measureMetadataCell(owner,"payload"," FROM composition_snapshots WHERE id=?",[SqlParameter.Text("composition-"+link.runId.value)]))}
            this.continuation=continuation.toArray();journalStreamCheck(guard)
        }catch(error:Exception){if(!borrowedPhases){owner.close()};throw error}
    }
    private func measureMetadataCell(owner:LogicalJsonOwnerReservation,column:String,suffix:String,parameters:Array<SqlParameter>):ContextReadMetadataCell{
        if(!borrowedPhases){return contextReadMetadataMeasure(tx,column,suffix,parameters,allocate,guard)}
        contextReadMetadataMeasureOwned(tx,column,suffix,parameters,owner,
            journalStreamAdd(externalRetained,permanentPeak),guard)
    }
    private func payPermanent(owner:LogicalJsonOwnerReservation,peak:Int64):Unit{
        if(!borrowedPhases){owner.ensureRetainedPeak(peak);return}
        permanentPeak=max(permanentPeak,peak)
        owner.ensureRetainedPeak(journalStreamAdd(externalRetained,permanentPeak))
    }
    private func phaseRetained():Int64{
        journalStreamAdd(externalRetained,journalStreamAdd(permanentPeak,activePhasePeak))
    }
    private func withPaidMetadataStage<T>(cells:Array<ContextReadMetadataCell>,consume:()->T):T{
        if(!borrowedPhases){return withContextReadMetadataStage(cells,allocate,guard,consume)}
        if(borrowedClosed){throw IllegalStateException("borrowed metadata phase is closed")}
        var bytes:Int64=0;var nodes:Int64=0
        for(cell in cells){bytes=journalStreamAdd(bytes,cell.bytes);nodes=journalStreamAdd(nodes,cell.nodes)}
        withRetainedMetadataStage(contextReadMetadataPeak(bytes,nodes),consume)
    }
    private func withRetainedMetadataStage<T>(peak:Int64,consume:()->T):T{
        if(!borrowedPhases || borrowedClosed || peak<0){throw IllegalStateException("retained metadata phase requires its live borrowed owner")}
        let prior=activePhasePeak
        activePhasePeak=journalStreamAdd(prior,peak)
        try{
            // Permanent raw/escaping plan+fact AND every still-live outer DOM
            // phase remain included. Reservation only grows; leaving a scope
            // changes bookkeeping, never refunds a borrowed reservation.
            charge.ensureRetainedPeak(phaseRetained());journalStreamCheck(guard)
            let result=consume();journalStreamCheck(guard);result
        }finally{activePhasePeak=prior}
    }
    func withBorrowedObservation<T>(consume:(LogicalJsonOwnerReservation,Int64)->T):T{
        if(!borrowedPhases || borrowedClosed){throw IllegalStateException("observation requires its actual live borrowed phase owner")}
        withPaidMetadataStage([auditCells[2]],{=>consume(charge,phaseRetained())})
    }
    func close():Unit{
        if(borrowedPhases){borrowedClosed=true;return}
        charge.close()
    }
    func fact():ContextReadFact{
        let cells=ArrayList<ContextReadMetadataCell>();for(cell in sourceCells){cells.add(cell)};for(cell in auditCells){cells.add(cell)}
        // The base charge already prepaid the small escaping plan/output
        // node count BEFORE the actual original canonical fact is decoded.
        withPaidMetadataStage(cells.toArray(),{=>requireContextReadFact(tx,link.operationId,link.runId)})
    }
    func withObservation<T>(consume:()->T):T{
        withPaidMetadataStage([auditCells[2]],consume)
    }
    func plan():NormalizedOperationPlan{
        if(borrowedPhases && borrowedClosed){throw IllegalStateException("borrowed metadata phase is closed")}
        // Exact original source and full fact link checked by the caller;
        // no second fact reconstruction/large turn array is needed here.
        decodeOperationPlan(original[0])
    }
    func origin(itemId:ItemId):Unit{
        withPaidMetadataStage([sourceCells[1],sourceCells[2]],{=>
            let rows=tx.query("SELECT item.thread_id,item.turn_id,item.ordinal,item.payload,item.provenance,item.created_at_millis,r.epoch "+
                "FROM items item JOIN runs r ON r.id=? WHERE item.id=? AND item.thread_id=r.thread_id AND item.turn_id=r.turn_id",
                [SqlParameter.Text(link.runId.value),SqlParameter.Text(itemId.value)])
            if(rows.size!=1){throw IllegalStateException("context read canonical enclosure missing")}
            let row=rows[0];let item=ThreadItem(itemId,ThreadId(row.required(0)),SemanticTurnId(row.required(1)),
                parseStoreInt(row.required(2),"context read ordinal"),decodeStoredThreadContent(row.required(3)),
                decodeStoredProvenance(row.required(4)),createdAtMillis:parseStoreInt(row.required(5),"context read time"))
            if(item.provenance.operationId.isNone() || item.provenance.operationId.getOrThrow().value!=link.operationId.value ||
                item.provenance.runId.isNone() || item.provenance.runId.getOrThrow().value!=link.runId.value){throw IllegalStateException("context read exact Operation binding changed")}
            let origin=match(item.provenance.directOrigin){case Some(DirectCallOrigin.ContextRead(value))=>value
                case _=>throw IllegalStateException("context read has no typed origin")}
            if(item.kind!=ItemKind.ToolCall || item.provenance.source!="direct_tool" || item.provenance.runId.isNone() || item.provenance.operationId.isNone()){
                throw IllegalStateException("context read has no exact canonical Operation source")}
            let epoch=parseStoreInt(row.required(6),"context read epoch")
            withPaidMetadataStage([skill.getOrThrow()],{=>
                let enclosure=tx.query("SELECT r.epoch,r.skill_snapshot FROM runs r JOIN threads t ON t.id=r.thread_id "+
                    "JOIN turns turn ON turn.id=r.turn_id JOIN items initial ON initial.id=turn.user_item_id "+
                    "WHERE r.id=? AND r.thread_id=? AND r.turn_id=? AND r.epoch=? AND r.state IN ('running') "+
                    "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active'",
                    [SqlParameter.Text(link.runId.value),SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value),SqlParameter.Int64Value(epoch)])
                if(enclosure.size!=1 || contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(enclosure[0].required(1))))!=origin.projectionDigest){
                    throw IllegalStateException("context read no longer owns the same Run projection")}})
            // Snapshot DOM is already released before validating the complete
            // immutable continuation request/launch/claim/composition.
            if(continuation.isEmpty()){requireUserOrConsumedContinuation(tx,item.threadId,item.turnId,link.runId,epoch)}
            else{withPaidMetadataStage(continuation,
                {=>requireUserOrConsumedContinuation(tx,item.threadId,item.turnId,link.runId,epoch)})}
            let expected=encodeStoredValue(contextReadEvidence(item,epoch))
            let rows2=tx.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='context_read_admitted'",
                [SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value),SqlParameter.Text(item.threadId.value)])
            if(rows2.size!=1 || rows2[0].required(0)!=expected){throw IllegalStateException("context read admission changed or was never committed")}})
    }
    func eachToolResult(thread:String,turn:String,consume:(ThreadItemContent)->Unit):Unit{
        if(borrowedPhases && borrowedClosed){throw IllegalStateException("borrowed metadata phase is closed")}
        if(borrowedPhases && knownCommitStreamingResults){
            eachContextReadToolResultKnownCommitOwned(tx,thread,turn,charge,phaseRetained(),guard,consume);return}
        if(borrowedPhases){eachContextReadToolResultOwned(tx,thread,turn,charge,phaseRetained(),guard,consume);return}
        eachContextReadToolResultPaid(tx,thread,turn,allocate,guard,consume)
    }
    func withParent(operation:OperationId,run:RunId,parentItem:ItemId,consume:(ContextReadPaidParent)->Unit):Unit{
        if(borrowedPhases && borrowedClosed){throw IllegalStateException("borrowed metadata phase is closed")}
        if(borrowedPhases){withBorrowedParent(operation,run,parentItem,consume);return}
        let parameters=[SqlParameter.Text(run.value),SqlParameter.Text(parentItem.value),SqlParameter.Text(operation.value)]
        let suffix=" FROM items item JOIN runs r ON item.thread_id=r.thread_id AND item.turn_id=r.turn_id "+
            "JOIN threads thread ON thread.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
            "WHERE r.id=? AND item.id=? AND item.kind='tool_call' AND r.state IN ('running','waiting_external') "+
            "AND r.finished_at_millis IS NULL AND thread.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active' "+
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions child WHERE child.operation_id=?)"
        let headers=tx.query("SELECT item.ordinal,r.thread_id,r.turn_id,r.epoch"+suffix,parameters)
        if(headers.size!=1){throw IllegalStateException("context read consumption requires its active canonical root")}
        let parent=allocate(65536)
        try{
            let head=withContextReadMetadataCell(tx,"SELECT length(CAST(item.payload AS BLOB))"+suffix,"SELECT item.payload"+suffix,
                parameters,allocate,guard,{_,meter=>let value=encodeStoredValue(meter.consumptionHeader());parent.ensureRetainedPeak(contextReadMetadataRawPeak(value.size));value})
            let provenance=withContextReadMetadataCell(tx,"SELECT length(CAST(item.provenance AS BLOB))"+suffix,"SELECT item.provenance"+suffix,
                parameters,allocate,guard,{_,meter=>let value=encodeStoredValue(meter.topProjection(["source","run_id","operation_id","direct_origin","continuation_origin","continuation_history"]));
                    parent.ensureRetainedPeak(contextReadMetadataRawPeak(journalStreamAdd(head.size,value.size)));value})
            // The unchanged snapshot itself remains private raw storage;
            // pay its DOM only when the original projection predicate runs.
            parent.ensureRetainedPeak(contextReadMetadataRawPeak(journalStreamAdd(head.size,journalStreamAdd(provenance.size,skill.getOrThrow().bytes))))
            let rows=tx.query("SELECT r.skill_snapshot"+suffix,parameters)
            if(rows.size!=1 || rows[0].required(0)!=original[5]){throw IllegalStateException("canonical parent projection changed")}
            let provMeter=StoredValuePaymentMeter(provenance,parent);let provNodes=provMeter.complete()
            let headMeter=StoredValuePaymentMeter(head,parent);let headNodes=headMeter.complete()
            parent.ensureRetainedPeak(journalStreamAdd(contextReadMetadataRawPeak(journalStreamAdd(head.size,journalStreamAdd(provenance.size,skill.getOrThrow().bytes))),headNodes*512))
            let row=SqliteRow([Some(head),Some(provenance),headers[0][0],headers[0][1],headers[0][2],headers[0][3],rows[0][0]])
            let paid=ContextReadPaidParent(row,ContextReadMetadataCell(provenance.size,provNodes),skill.getOrThrow(),allocate,guard)
            consume(paid);journalStreamCheck(guard)
        }finally{parent.close()}
    }
    private func withBorrowedParent(operation:OperationId,run:RunId,parentItem:ItemId,consume:(ContextReadPaidParent)->Unit):Unit{
        let parameters=[SqlParameter.Text(run.value),SqlParameter.Text(parentItem.value),SqlParameter.Text(operation.value)]
        let suffix=" FROM items item JOIN runs r ON item.thread_id=r.thread_id AND item.turn_id=r.turn_id "+
            "JOIN threads thread ON thread.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
            "WHERE r.id=? AND item.id=? AND item.kind='tool_call' AND r.state IN ('running','waiting_external') "+
            "AND r.finished_at_millis IS NULL AND thread.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active' "+
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions child WHERE child.operation_id=?)"
        let headers=tx.query("SELECT item.ordinal,r.thread_id,r.turn_id,r.epoch"+suffix,parameters)
        if(headers.size!=1){throw IllegalStateException("context read consumption requires its active canonical root")}
        let parent=charge;let projectedNodes=ContextReadBorrowedParentProjectedNodes()
        try{
            let head=withContextReadMetadataCellOwned(tx,"SELECT length(CAST(item.payload AS BLOB))"+suffix,"SELECT item.payload"+suffix,
                parameters,parent,phaseRetained(),guard,{_,meter=>let projected=meter.consumptionHeader()
                projectedNodes.head=livePolicyStoredExtent(projected).nodes
                let value=encodeStoredValue(projected)
                parent.ensureRetainedPeak(journalStreamAdd(phaseRetained(),journalStreamAdd(contextReadMetadataRawPeak(value.size),projectedNodes.head*512)));value})
            let provenance=withContextReadMetadataCellOwned(tx,"SELECT length(CAST(item.provenance AS BLOB))"+suffix,"SELECT item.provenance"+suffix,
                parameters,parent,journalStreamAdd(phaseRetained(),journalStreamAdd(contextReadMetadataRawPeak(head.size),projectedNodes.head*512)),guard,{_,meter=>let projected=meter.topProjection(["source","run_id","operation_id","direct_origin","continuation_origin","continuation_history"])
                    projectedNodes.provenance=livePolicyStoredExtent(projected).nodes
                    let value=encodeStoredValue(projected)
                    parent.ensureRetainedPeak(journalStreamAdd(phaseRetained(),journalStreamAdd(contextReadMetadataRawPeak(journalStreamAdd(head.size,value.size)),
                        journalStreamAdd(projectedNodes.head,projectedNodes.provenance)*512)));value})
            // The unchanged snapshot itself remains private raw storage;
            // pay its DOM only when the original projection predicate runs.
            parent.ensureRetainedPeak(journalStreamAdd(phaseRetained(),journalStreamAdd(contextReadMetadataRawPeak(journalStreamAdd(head.size,journalStreamAdd(provenance.size,skill.getOrThrow().bytes))),
                journalStreamAdd(projectedNodes.head,projectedNodes.provenance)*512)))
            let rows=tx.query("SELECT r.skill_snapshot"+suffix,parameters)
            if(rows.size!=1 || rows[0].required(0)!=original[5]){throw IllegalStateException("canonical parent projection changed")}
            let provMeter=StoredValuePaymentMeter(provenance,parent,extraRetained:journalStreamAdd(phaseRetained(),contextReadMetadataRawPeak(journalStreamAdd(head.size,skill.getOrThrow().bytes))));let provNodes=provMeter.complete()
            let headMeter=StoredValuePaymentMeter(head,parent,extraRetained:journalStreamAdd(phaseRetained(),contextReadMetadataRawPeak(journalStreamAdd(provenance.size,skill.getOrThrow().bytes))));let headNodes=headMeter.complete()
            if(provNodes!=projectedNodes.provenance || headNodes!=projectedNodes.head){throw IllegalStateException("canonical parent projection node extent changed")}
            let retained=journalStreamAdd(contextReadMetadataRawPeak(journalStreamAdd(head.size,journalStreamAdd(provenance.size,skill.getOrThrow().bytes))),headNodes*512)
            withRetainedMetadataStage(retained,{=>
                let row=SqliteRow([Some(head),Some(provenance),headers[0][0],headers[0][1],headers[0][2],headers[0][3],rows[0][0]])
                let paid=ContextReadPaidParent(row,ContextReadMetadataCell(provenance.size,provNodes),skill.getOrThrow(),allocate,guard,
                    phaseStage:Some({cell,action=>withPaidMetadataStage([cell],action)}))
                consume(paid);journalStreamCheck(guard)})
        }finally{}
    }
    func current(binding:AgentValue):Result<Unit>{
        if(borrowedPhases && borrowedClosed){throw IllegalStateException("borrowed metadata phase is closed")}
        journalStreamCheck(guard)
        let epoch=journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText())
        if(requirePluginDocumentLane(tx,ThreadId(httpIntentText(binding,"thread_id")),link.runId,epoch).value!=httpIntentText(binding,"lane_id")){
            throw IllegalStateException("completed input lost its original current lane")}
        let rows=tx.query("SELECT o.id FROM operations o JOIN runs r ON r.id=o.run_id "+
            "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
            "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.normalized_plan=o.normalized_plan "+
            "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
            "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id "+
            "JOIN operation_receipts receipt ON receipt.id=e.reserved_receipt_id AND receipt.operation_id=o.id "+
            "JOIN items result ON result.id=e.reserved_result_item_id AND result.thread_id=r.thread_id AND result.turn_id=r.turn_id "+
            "JOIN audit_events handoff ON handoff.operation_id=o.id AND handoff.run_id=r.id AND handoff.thread_id=r.thread_id AND handoff.kind='operation_execution_handoff' "+
            "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND receipt.outcome='completed' AND call.id=? AND result.id=? "+
            "AND receipt.id=? AND call.kind='tool_call' AND result.kind='tool_result' AND r.epoch=? AND r.state='running' "+
            "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active' "+
            "AND o.normalized_plan=? AND call.payload=? AND call.provenance=? AND receipt.detail=? AND result.payload=? AND r.skill_snapshot=? "+
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions d WHERE d.operation_id=o.id) "+
            "AND NOT EXISTS(SELECT 1 FROM decision_operations d WHERE d.operation_id=o.id) "+
            "AND NOT EXISTS(SELECT 1 FROM canonical_decision_items c WHERE c.item_id=call.id) "+
            "AND (SELECT count(*) FROM audit_events a WHERE a.operation_id=o.id AND a.run_id=r.id AND a.thread_id=r.thread_id AND a.kind='context_read_admitted' AND a.payload=?)=1 "+
            "AND handoff.payload=? "+
            "AND (SELECT count(*) FROM audit_events a WHERE a.operation_id=o.id AND a.run_id=r.id AND a.thread_id=r.thread_id AND a.kind='plugin_document_latest_journal_observed' AND a.payload=?)=1",
            [SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value),SqlParameter.Text(link.sourceItemId.value),
                SqlParameter.Text(link.resultItemId.value),SqlParameter.Text(link.receiptId),SqlParameter.Int64Value(epoch),
                SqlParameter.Text(original[0]),SqlParameter.Text(original[1]),SqlParameter.Text(original[2]),
                SqlParameter.Text(original[3]),SqlParameter.Text(original[4]),SqlParameter.Text(original[5]),
                SqlParameter.Text(original[6]),SqlParameter.Text(original[7]),SqlParameter.Text(original[8])])
        if(rows.size!=1){throw IllegalStateException("completed input current actual Source/fact changed")}
        journalStreamCheck(guard);Result<Unit>.Ok(())
    }
}
