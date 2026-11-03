package agent_store

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_runtime.*

// Trusted opt-in assembly only, not a Native constructor or permission.
// The default document/window and original v2 stream paths stay delegated to
// their exact existing owner. New v3 reads use only the events-derived view.
public class SqliteOpaqueRowJournalLatestStreamBackend <: PluginDocumentStorageBackend {
    private let original:SqliteOpaqueRowJournalStreamBackend
    private let namespace:String
    private let documentKey:String
    private let access:RowJournalStructuralAccess
    private let view:RowJournalLatestView
    private let storage:JournalLatestStreamStorage
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let configuration:(NormalizedOperationPlan)->Result<() -> Result<Unit>>
    public prop identity:String{get(){original.identity}}
    public init(original:SqliteOpaqueRowJournalStreamBackend,namespace:String,key:String,
        workspace:String,access:RowJournalStructuralAccess,view:RowJournalLatestView,
        allocate:(Int64)->LogicalJsonOwnerReservation,configuration:(NormalizedOperationPlan)->Result<() -> Result<Unit>>){
        if(!httpServicePluginNamespace(namespace) || !documentIdentity(ThreadId("journal"),LaneId("main"),namespace,key)){
            throw IllegalArgumentException("new latest stream requires a valid actual fixed address mapping")}
        this.original=original;this.namespace=namespace;this.documentKey=key;this.access=access;this.view=view
        this.allocate=allocate;this.configuration=configuration
        this.storage=JournalLatestStreamStorage(access,view,workspace,allocate)
    }
    func windowBackend():SqliteOpaqueRowJournalWindowBackend{original.windowBackend()}
    public func read(tx:SqliteTransaction,thread:ThreadId,lane:LaneId,namespace:String,key:String):PluginDocumentSnapshot{
        original.read(tx,thread,lane,namespace,key)}
    public func recordRead(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,value:PluginDocumentSnapshot):Unit{
        original.recordRead(tx,source,plan,value)}
    public func requireParentFence(tx:SqliteTransaction,parent:OperationId,run:RunId,intent:PluginDocumentIntent):Unit{
        original.requireParentFence(tx,parent,run,intent)}
    public func compareExchange(tx:SqliteTransaction,expected:PluginDocumentSnapshot,next:String):PluginDocumentSnapshot{
        original.compareExchange(tx,expected,next)}
    func capture(plan:NormalizedOperationPlan):() -> Result<Unit>{
        let request=plan.canonicalArguments
        if((!pluginDocumentLatestJournalStreamReadRequestValid(request) && !pluginDocumentContextLatestJournalStreamReadRequestValid(request)) ||
            httpIntentText(request.field("binding").getOrThrow(),"namespace")!=namespace ||
            httpIntentText(request,"key")!=documentKey || httpIntentText(request,"access_policy_digest")!=access.digest ||
            httpIntentText(request,"view_policy_digest")!=view.digest){
            throw IllegalStateException("strict v3 read differs from its actual frozen operator mapping")}
        // Only trusted actual assembly can return this witness. It is
        // private to this single executing proof, never a caller DTO, cache,
        // approval, Source or cross-Root permission registry.
        let current=match(configuration(plan)){
            case Result.Err(error)=>throw PluginDocumentGuardFailure(error)
            case Result.Ok(value)=>value}
        journalStreamCheck(current);current
    }
    func owner(bytes:Int64):LogicalJsonOwnerReservation{allocate(bytes)}
    func full(tx:SqliteTransaction,guard:()->Result<Unit>):JournalLatestStreamFence{storage.fence(tx,guard)}
    func fullOwned(tx:SqliteTransaction,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):JournalLatestStreamFence{
        storage.fenceOwned(tx,guard,owner,extraRetained)}
    // Private loan from this exact captured operator-installed backend.
    func withActualLatest304(tx:SqliteTransaction,thread:String,guard:()->Result<Unit>,
        consume:(JournalLatestViewEntry,JournalLatestViewObserved)->Unit):Unit{
        storage.withActualLatest304(tx,thread,guard,consume)
    }

    func emit(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,lane:LaneId,
        state:JournalLatestStreamFence,guard:()->Result<Unit>,consume:?(Int64,Array<Byte>)->Unit):FixedJournalCellObservation{
        storage.emit(tx,source.threadId.value,plan.canonicalArguments,original.annotations(source,lane),state,guard,consume)
    }
}
