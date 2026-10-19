package agent_host_runtime

import agent_domain.*
import agent_runtime.{OperationRuntimePort, PluginLivePolicyProposalCursor, PluginLivePolicySettlementCleanupDebt326, PluginLivePolicyOuterErrorDataOwner331, PluginLivePolicyOuterErrorFrame334}
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.fs.*
import std.sync.*
import stdx.crypto.digest.*

// Retained by the existing ContextRead owner before any file can be opened.
// A failed close leaves every actual file/writer/reservation in this same
// bounded owner. This object carries no operation or document read authority.
private class HostLivePolicyInputDescription {
    var bytes:Int64=0
    var digest:String=""
    init(){}
}

private class HostLivePolicyInputReadData {
    var request:?AgentValue=None
    init(){}
}

public class HostDocumentDataSession {
    private let artifacts: HostArtifactStore
    private let lock=Mutex()
    private let fixed: LogicalJsonFixedBufferReservation
    private let metadata: LogicalJsonOwnerReservation
    private var input: ?HostVerifiedArtifactInput=None
    private var latestJournalInput:?HostLatestJournalStreamInputReader=None
    private let writers=ArrayList<HostServiceArtifactWriter>()
    private let approved=HashSet<String>()
    private var started=false
    private var finished=false
    private var closed=false
    private var released=false
    private var workerCleanup: ?() -> Bool = None
    private var resultReservation: ?LogicalJsonOwnerReservation = None
    private var livePolicyToolLease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    // Opt-in full managed terminal data. The original result reservation pays
    // these exact references until their own consumer and physical close ACK.
    private var managedChannelTerminal:?AgentValue=None<AgentValue>
    private var managedChannelTerminalFile:?HostManagedChannelTerminalFile=None<HostManagedChannelTerminalFile>
    private var managedChannelToolLease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    private var managedChannelRetainedPeak:Int64=0
    private var managedChannelClosedLease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    // Opt-in SAME Session proposal IO/debt. None preserves every old path.
    private var livePolicyEffectCursor306:?HostLivePolicyProposalCursor306=None<HostLivePolicyProposalCursor306>
    private var livePolicyOutputOwnerAcknowledged292=false
    private let outputPending=AtomicBool(false)
    private let livePolicyMetadataPending=AtomicBool(false)
    private var livePolicyRetainedMetadata:?AgentValue=None<AgentValue>
    // Distinct actual retained input/policy custody, not a ToolResult or grant.
    private let executionPending=AtomicBool(false)
    private let running=AtomicBool(false)
    private let terminal=AtomicBool(false)
    private let stop=AtomicBool(false)
    // Selected live-parent preparation funds full Prepared data on THIS original Session.
    // These remain conservatively held; old cleanup/collector methods do
    // not pretend that permanent Root/Source/caller aliases have retired.
    // Actual preparation loans stay in this original physical collector.
    // No Source/Prepared/callback lifetime is inferred from a local return.
    private var preparationBackings340:?HostLivePreparationBacking340=None<HostLivePreparationBacking340>
    private var livePolicyInitialCustody332:?OwnedKernelPreparedReferenceCustody=None<OwnedKernelPreparedReferenceCustody>
    private var livePolicyInitialPhysical332:?HostLiveExecutionCustody=None<HostLiveExecutionCustody>
    private var livePolicyInitialBacking332:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private var livePolicyInitialDebt332:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    private var livePolicyDerivedCollector336:?((HostDocumentDataSession)->Result<Unit>)=None<((HostDocumentDataSession)->Result<Unit>)>
    private var livePolicyCapturedPin336:?HostLiveCapturedMetadataPin336=None<HostLiveCapturedMetadataPin336>
    private var livePolicyCapturedBacking336:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private var livePolicyCapturedPhysicalCleared336=false
    public init(artifacts: HostArtifactStore) {
        this.artifacts=artifacts
        fixed=reserveNativeObservationBuffer()
        try {metadata=reserveNativeDocumentPayload(65536)}catch(error:Exception){fixed.close();throw error}
    }
    // A prepaid child of an ACTUAL existing Session allocation; no new
    // logical owner acquisition or pool/floor. Original constructor unchanged.
    init(artifacts:HostArtifactStore,metadata336:LogicalJsonOwnerReservation,
        collector336:(HostDocumentDataSession)->Result<Unit>){
        this.artifacts=artifacts;fixed=reserveNativeObservationBuffer();metadata=metadata336
        livePolicyDerivedCollector336=Some(collector336)
    }
    func ownDerivedDataSessionCollector336(collector:(HostDocumentDataSession)->Result<Unit>):Unit{
        lock.lock();try{
            if(started || closed || livePolicyDerivedCollector336.isSome()){
                throw IllegalStateException("original inert collector binding is single-use")}
            livePolicyDerivedCollector336=Some(collector)
        }finally{lock.unlock()}
    }
    func retainLivePolicyCapturedSuccessorBacking336(previous:AgentValue,next:AgentValue):Result<HostLiveCapturedMetadataPin336>{
        lock.lock();try{
            if(!started || !finished || !terminal.load() || closed || stop.load() || released ||
                !executionPending.load() || !livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isNone() ||
                outputPending.load() || resultReservation.isSome() || workerCleanup.isSome() ||
                input.isSome() || latestJournalInput.isSome() || !writers.isEmpty() ||
                livePolicyCapturedPin336.isSome() || livePolicyCapturedBacking336.isSome() || livePolicyDerivedCollector336.isNone()){
                return hostPluginResourceError("plugin.live_successor_owner_changed","actual completed original captured metadata owner is required")}
            let loan=metadata.deriveRetainedLease()
            livePolicyCapturedBacking336=Some(loan)
            let paidPeak=match(ownedHostJsonOccurrenceInvoice336(loan,livePolicyRetainedMetadata.getOrThrow(),previous,next)){
                case Result.Err(error)=>loan.close();livePolicyCapturedBacking336=None<LogicalJsonOwnerReservation>
                    return Result<HostLiveCapturedMetadataPin336>.Err(error);case Result.Ok(value)=>value}
            let pin=HostLiveCapturedMetadataPin336(this,loan,livePolicyRetainedMetadata.getOrThrow(),previous,next,paidPeak)
            livePolicyCapturedPin336=Some(pin);Result<HostLiveCapturedMetadataPin336>.Ok(pin)
        }catch(_:Exception){hostPluginResourceError("plugin.live_successor_unpaid","original complete metadata and both ledger occurrence invoice was not paid")}
        finally{lock.unlock()}
    }
    // Extract the actual collector BEFORE entering it. No callback/registry
    // executes under the Session's short mechanical ownership mutex.
    func createPaidDataSuccessorSession336(pin:HostLiveCapturedMetadataPin336):Result<HostDocumentDataSession>{
        lock.lock()
        let collector:(HostDocumentDataSession)->Result<Unit>=try{
            if(livePolicyCapturedPin336.isNone() || !refEq(livePolicyCapturedPin336.getOrThrow(),pin) ||
                !pin.matches(this) || livePolicyDerivedCollector336.isNone() || closed || released){
                return hostPluginResourceError<HostDocumentDataSession>("plugin.live_successor_owner_changed","same actual published old-data pin and original collector are required")}
            livePolicyDerivedCollector336.getOrThrow()
        }finally{lock.unlock()}
        let loan=match(pin.prepaySuccessor336()){
            case Result.Err(error)=>return Result<HostDocumentDataSession>.Err(error);case Result.Ok(value)=>value}
        // Full occurrence loan and wrapper payment precede new Session and
        // collector retention. Any failure stays in this original pin.
        let next=try{HostDocumentDataSession(artifacts,loan,collector)}
            catch(_:Exception){return hostPluginResourceError<HostDocumentDataSession>("plugin.live_successor_construct_pending","same original pin keeps actual construction debt")}
        match(pin.adoptSuccessor336(next)){case Result.Err(error)=>return Result<HostDocumentDataSession>.Err(error);case Result.Ok(_)=>()}
        match(collector(next)){case Result.Err(error)=>Result<HostDocumentDataSession>.Err(error);case Result.Ok(_)=>Result.Ok(next)}
    }
    // Complete old data is still retained in the same-bank pin. Only these
    // exact private physical Session fields can be cleared; no caller ACK.
    func clearCapturedLivePolicyPhysicalFields336(pin:HostLiveCapturedMetadataPin336):Result<Unit>{
        lock.lock();try{
            if(livePolicyCapturedPin336.isNone() || !refEq(livePolicyCapturedPin336.getOrThrow(),pin) ||
                !pin.matches(this) || !pin.retainsCompleteData336() || !started || !finished || !terminal.load() ||
                outputPending.load() || resultReservation.isSome() || workerCleanup.isSome() ||
                input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_successor_physical_fields_live","same old paid data pin and actual completed physical fields required")}
            if(livePolicyCapturedPhysicalCleared336){return Result<Unit>.Ok(())}
            if(!executionPending.load() || !livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isNone()){
                return hostPluginResourceError("plugin.live_successor_physical_fields_live","original captured Session fields changed before physical ACK")}
            livePolicyRetainedMetadata=None<AgentValue>;livePolicyMetadataPending.store(false)
            livePolicyCapturedPhysicalCleared336=true;Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    private func cleanup(allowOutputPending!:Bool=false,allowExecutionPending!:Bool=false): Result<Unit> {
        try {
            match(workerCleanup){case Some(dispose)=>
                if(!dispose()){return hostPluginResourceError("plugin.document_query_cleanup_pending","unacknowledged pure worker remains owned")}
                workerCleanup=None
                case None=>()}
            match(latestJournalInput){case Some(value)=>match(value.close()){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>latestJournalInput=None};case None=>()}
            match(input){case Some(value)=>match(value.close()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>input=None};case None=>()}
            var i:Int64=0
            while(i<writers.size){match(writers[i].close()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>writers.remove(at:i)}}
            // The original worker/input/writer loops above already physically
            // ACKed. Cancelled/incomplete data is cleaned, never called Known.
            match(livePolicyEffectCursor306){case Some(cursor)=>
                cursor.retireAfterSessionPhysicalCleanup306();livePolicyEffectCursor306=None<HostLivePolicyProposalCursor306>
                case None=>()}
            if(outputPending.load()){
                if(allowOutputPending){return Result.Ok(())}
                return hostPluginResourceError("plugin.document_result_ack_pending","frozen ToolResult remains owned until consumer acknowledgement")}
            // On an error/explicit output ACK, drop every managed DOM and
            // private artifact reference before refunding its actual owner.
            // The original None/default cleanup is otherwise unchanged.
            if(managedChannelTerminal.isSome()){
                managedChannelTerminal=None;managedChannelTerminalFile=None
                managedChannelToolLease=None;managedChannelRetainedPeak=0
            }
            match(resultReservation){case Some(value)=>value.close();resultReservation=None;case None=>()}
            // An actual captured metadata consumer ACK is distinct from the
            // old private-result ACK. Keep the SAME owner/collector on cancel,
            // close or failed disposal until that real consumer drops it.
            if(livePolicyMetadataPending.load()){
                return hostPluginResourceError("plugin.live_metadata_ack_pending","captured live metadata is still retained by its actual custody")}
            // Actual worker/FD/writer cleanup above must ACK first. Then retain
            // the same input/policy reservation until its terminal custody ACK.
            if(executionPending.load()){
                if(allowExecutionPending){return Result.Ok(())}
                return hostPluginResourceError("plugin.live_execution_ack_pending","retained live input/policy remains owned")}
            if(!released){metadata.close();fixed.close();released=true}
            Result.Ok(())
        }catch(_:Exception){hostPluginResourceError("plugin.document_query_cleanup_pending","document query file remains owned")}
    }
    public func collect(): Bool {
        if(!terminal.load() || outputPending.load() || executionPending.load()){return false}
        lock.lock();try{finished && cleanup().isOk()}finally{lock.unlock()}
    }
    // Opt-in observations of the existing retained execution Session only.
    // No Native bool/DTO/ACK or metadata reference can satisfy these fields.
    func livePolicyTransientResourcesReleased():Bool{
        if(!terminal.load()){return false}
        lock.lock();try{
            finished && terminal.load() && workerCleanup.isNone() &&
                latestJournalInput.isNone() && input.isNone() && writers.isEmpty()
        }finally{lock.unlock()}
    }
    func livePolicyPrivateOutputRetained():Bool{
        if(!terminal.load()){return false}
        lock.lock();try{
            started && finished && terminal.load() && !closed && !stop.load() &&
                !released && executionPending.load() && outputPending.load() && resultReservation.isSome()
        }finally{lock.unlock()}
    }
    public func close(): Result<Unit> {
        stop.store(true)
        if(running.load() && !terminal.load()){return hostPluginResourceError("plugin.document_query_cleanup_pending","active document query still owns its resource")}
        lock.lock();try{closed=true;finished=true;terminal.store(true);cleanup()}finally{lock.unlock()}
    }
    public func run(action: (HostDocumentDataSession)->Result<AgentValue>): Result<AgentValue> {
        lock.lock()
        try {
            if(closed || started || stop.load()){return hostPluginResourceError("plugin.document_query_closed","document query is one-shot")}
            started=true;running.store(true)
            let result=try{action(this)}catch(_:Exception){hostPluginResourceError<AgentValue>("plugin.document_query_failed","pure document preparation failed")}
                finally{finished=true;terminal.store(true)}
            if(result.isError()){outputPending.store(false)}
            match(cleanup(allowOutputPending:result.isOk(),allowExecutionPending:executionPending.load())){case Result.Err(error)=>
                // No decoded value was returned to a consumer. Failed actual
                // writers and its reservation remain in this same owner for
                // retry, without waiting for an impossible output ACK.
                outputPending.store(false);return Result.Err(error);case Result.Ok(_)=>()}
            result
        }finally{lock.unlock()}
    }
    // Package-private construction: actual HostContextReadExecutor adopts the
    // same Session into its existing collector BEFORE obtaining this custody.
    // No extra registry, cleanup claim, Source or decoded callback is accepted.
    func retainExecutionCustody():Result<HostLiveExecutionCustody>{
        lock.lock();try{
            if(closed || started || finished || stop.load() || released || executionPending.load() ||
                outputPending.load() || workerCleanup.isSome() || input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_execution_owner_unavailable","live custody must be retained before this inert query starts")}
            executionPending.store(true);Result.Ok(HostLiveExecutionCustody(this))
        }finally{lock.unlock()}
    }
    func retainLivePolicyPreparationBacking340(physical:HostLiveExecutionCustody):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(!physical.matchesSession332(this) || closed || released || started || finished ||
                running.load() || terminal.load() || stop.load() || !executionPending.load() ||
                input.isSome() || latestJournalInput.isSome() || workerCleanup.isSome() || !writers.isEmpty() ||
                outputPending.load() || resultReservation.isSome()){
                return hostPluginResourceError("plugin.live_preparation_owner_changed","same actual inert Session custody required before preparation copies")}
            let loan=try{metadata.deriveRetainedLease()}catch(_:Exception){
                return hostPluginResourceError("plugin.live_preparation_unpaid","original preparation owner cannot acquire a retained lease")}
            // Attach the actual loan before invoice/closure failures can escape.
            try{loan.ensureRetainedPeak(8192)}catch(_:Exception){loan.close()
                return hostPluginResourceError("plugin.live_preparation_unpaid","original preparation wrapper invoice was refused")}
            preparationBackings340=Some(HostLivePreparationBacking340(loan,preparationBackings340))
            Result<LogicalJsonOwnerReservation>.Ok(loan)
        }finally{lock.unlock()}
    }
    // No callback or IO can run here. Derive only from the actual metadata
    // reservation after SAME Host collector adopted this inert Session and
    // retainExecutionCustody minted its physical custody.8192 is wrappers,
    // NOT a complete Prepared invoice; actual Tools must walk/pay it next.
    func retainLivePolicyInitialPreparedBacking332(actual:OwnedKernelPreparedReferenceCustody,
        physical:HostLiveExecutionCustody,additionalPeak:Int64):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(additionalPeak<8192 || !physical.matchesSession332(this) ||
                closed || released || started || finished || running.load() || terminal.load() || stop.load() ||
                !executionPending.load() || outputPending.load() || livePolicyMetadataPending.load() ||
                input.isSome() || latestJournalInput.isSome() || workerCleanup.isSome() || !writers.isEmpty() || !approved.isEmpty() ||
                resultReservation.isSome() || livePolicyToolLease.isSome() || livePolicyRetainedMetadata.isSome() ||
                managedChannelTerminal.isSome() || managedChannelTerminalFile.isSome() || managedChannelToolLease.isSome() ||
                livePolicyEffectCursor306.isSome() || livePolicyOutputOwnerAcknowledged292 ||
                livePolicyInitialCustody332.isSome() || livePolicyInitialPhysical332.isSome() ||
                livePolicyInitialBacking332.isSome() || livePolicyInitialDebt332.isSome()){
                return hostPluginResourceError("plugin.live_initial_prepared_unavailable",
                    "same actual inert Session and original physical custody are required before full input payment")}
            let child=try{metadata.deriveRetainedLease()}
                catch(_:Exception){return hostPluginResourceError("plugin.live_initial_prepared_unpaid",
                    "same original metadata bank could not retain initial input")}
            try{
                child.ensureRetainedPeak(additionalPeak)
                livePolicyInitialCustody332=Some(actual);livePolicyInitialPhysical332=Some(physical)
                livePolicyInitialBacking332=Some(child);Result<LogicalJsonOwnerReservation>.Ok(child)
            }catch(_:Exception){child.close();hostPluginResourceError("plugin.live_initial_prepared_unpaid",
                "initial input wrapper cells exceed the same actual bank")}
        }finally{lock.unlock()}
    }
    // A debt can only be minted after Tools paid the full actual typed walk.
    // Validate SAME custody and SAME original derived reservation before the
    // actual Native Session may start. No Bool/ID/JSON supplies this debt.
    func adoptLivePolicyInitialPreparedDebt332(actual:OwnedKernelPreparedReferenceCustody,
        physical:HostLiveExecutionCustody,backing:LogicalJsonOwnerReservation,
        debt:OwnedKernelPreparedReferenceDebt):Result<Unit>{
        lock.lock();try{
            if(!physical.matchesSession332(this) || closed || released || started || finished || running.load() || terminal.load() || stop.load() ||
                !executionPending.load() || livePolicyInitialDebt332.isSome() || livePolicyInitialCustody332.isNone() ||
                livePolicyInitialPhysical332.isNone() || livePolicyInitialBacking332.isNone() ||
                !hostSameInitialPreparedCustody335(livePolicyInitialCustody332.getOrThrow(),actual) ||
                !refEq(livePolicyInitialPhysical332.getOrThrow(),physical) ||
                !refEq(livePolicyInitialBacking332.getOrThrow(),backing) ||
                !ownedKernelPreparedReferenceDebtMatchesCustody332(actual,debt)){
                return hostPluginResourceError("plugin.live_initial_prepared_debt_changed",
                    "full Kernel Prepared debt must belong to the exact original Session input custody")}
            livePolicyInitialDebt332=Some(debt);Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    // This check is DATA readiness only. The original current/full Source
    // checks in the actual Native step and Pipeline retain their full order.
    // It admits no legacy run or different Session behind the paid pin.
    func requireLivePolicyInitialPreparedExecution332(actual:OwnedKernelPreparedReferenceCustody,
        physical:HostLiveExecutionCustody,debt:OwnedKernelPreparedReferenceDebt):Result<Unit>{
        lock.lock();try{
            if(!physical.matchesSession332(this) || closed || released || started || finished || running.load() || terminal.load() || stop.load() ||
                !executionPending.load() || outputPending.load() || livePolicyMetadataPending.load() ||
                input.isSome() || latestJournalInput.isSome() || workerCleanup.isSome() || !writers.isEmpty() || !approved.isEmpty() ||
                resultReservation.isSome() || livePolicyToolLease.isSome() || livePolicyRetainedMetadata.isSome() ||
                managedChannelTerminal.isSome() || managedChannelTerminalFile.isSome() || managedChannelToolLease.isSome() ||
                livePolicyEffectCursor306.isSome() || livePolicyInitialCustody332.isNone() || livePolicyInitialPhysical332.isNone() ||
                livePolicyInitialBacking332.isNone() || livePolicyInitialDebt332.isNone() ||
                !hostSameInitialPreparedCustody335(livePolicyInitialCustody332.getOrThrow(),actual) || !refEq(livePolicyInitialPhysical332.getOrThrow(),physical) ||
                !refEq(livePolicyInitialDebt332.getOrThrow(),debt) || !ownedKernelPreparedReferenceDebtMatchesCustody332(actual,debt)){
                return hostPluginResourceError("plugin.live_initial_prepared_debt_required",
                    "the actual first Native run requires its same adopted full Prepared debt")}
            Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }

    func releaseExecutionTransient():Result<Unit>{
        if(running.load() && !terminal.load()){
            return hostPluginResourceError("plugin.document_query_cleanup_pending","active query still owns its transient resources")}
        lock.lock();try{
            if(!executionPending.load() || !finished || !terminal.load()){
                return hostPluginResourceError("plugin.live_execution_owner_unavailable","same retained query has not finished its callback")}
            // Does not clear outputPending, another worker debt, or custody.
            cleanup(allowExecutionPending:true)
        }finally{lock.unlock()}
    }
    func closeExecutionCustody():Result<Unit>{
        stop.store(true)
        if(running.load() && !terminal.load()){
            return hostPluginResourceError("plugin.document_query_cleanup_pending","active query still owns its physical resources")}
        lock.lock();try{
            if(!executionPending.load()){return if(released){Result.Ok(())}else{
                hostPluginResourceError("plugin.live_execution_owner_unavailable","this query has no retained live custody")}}
            // Keep the same custody flag and all phase charges on every failed
            // worker/file/output ACK. Only the completed cleanup may clear it.
            match(cleanup(allowExecutionPending:true)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            executionPending.store(false);closed=true;finished=true;terminal.store(true)
            cleanup()
        }finally{lock.unlock()}
    }
    // Called only by actual Host collector shutdown. An active callback or
    // unconsumed output keeps its same Session/debt in that collector.
    func closeExecutionDataOwner():Result<Unit>{
        if(executionPending.load()){closeExecutionCustody()}else{close()}
    }
    public func acknowledgeOutput():Unit{
        outputPending.store(false)
        lock.lock();try{let _=cleanup()}finally{lock.unlock()}
    }
    public func parameterUploadBytes(value:AgentValue):Result<Array<Byte>>{
        try{
            let bound=logicalJsonWriteReservationBytes(value,ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX)
            if(bound>ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX){
                return hostPluginResourceError("plugin.document_query_input","parameters exceed the existing ordinary message ceiling")}
            // The metadata/phase owner stays live while stringify and its
            // byte copy coexist. Pay their conservative peak in this same
            // original aggregate before either allocation; close owns it.
            metadata.ensureRetainedPeak(16777216+bound*4)
            let encoded=stringifyUnifiedJson(value)
            if(encoded.size>ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX){
                return hostPluginResourceError("plugin.document_query_input","parameters exceed the existing ordinary message ceiling")}
            Result.Ok(encoded.toArray())
        }catch(_:LogicalJsonPayloadError){
            hostPluginResourceError("plugin.document_query_capacity","parameter serialization exhausted the existing shared allocation")}
    }
    // Separate context-only serialization. The original ordinary Tool method
    // retains its exact ceiling and body; this method conveys no read authority.
    public func contextParameterUploadBytes(value:AgentValue):Result<Array<Byte>>{
        try{
            let bound=logicalJsonWriteReservationBytes(value,CONTENT_PAYLOAD_MESSAGE_BYTES)
            if(bound>CONTENT_PAYLOAD_MESSAGE_BYTES){
                return hostPluginResourceError("plugin.document_query_input","context parameters exceed the existing content message ceiling")}
            // Prepay the same actual metadata owner before UTF8 serialization
            // and its byte copy coexist; Session cleanup owns the reservation.
            metadata.ensureRetainedPeak(16777216+bound*4)
            let encoded=stringifyUnifiedJson(value)
            if(encoded.size>CONTENT_PAYLOAD_MESSAGE_BYTES){
                return hostPluginResourceError("plugin.document_query_input","context parameters exceed the existing content message ceiling")}
            Result.Ok(encoded.toArray())
        }catch(_:LogicalJsonPayloadError){
            hostPluginResourceError("plugin.document_query_capacity","context parameter serialization exhausted the existing shared allocation")}
    }
    public func verifyFrozenResult(context:ToolInvocationContext,prepared:PreparedToolInvocation,current:()->Result<Unit>,
        completedChildren!:Bool=false):Result<Unit>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","frozen result validation window is closed")}
        artifacts.verifyDocumentFrozenResult(context,prepared,current,completedChildren:completedChildren)
    }
    // The callback reconstructs the actual canonical executing source before
    // this file is opened. It is not replaceable by a metadata-only reference.
    public func readFrozenResult(reference:PluginDocumentPayloadReference,authorize:()->Result<Unit>,current:()->Result<Unit>,
        retain!:Bool=false):Result<AgentValue>{
        if(closed || !started || finished || input.isSome() || resultReservation.isSome() || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","full frozen result decoder is single use per live read")}
        match(authorize()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let charge=reserveNativeDocumentPayload(reference.bytes)
        var transferred=false
        try{
            // Eight byte extents cover read backing growth, byte/text copies,
            // canonical validation, sink encoding and durable codec copies.
            // Value+field cells are prepaid before full raw/DOM allocation.
            charge.ensureRetainedPeak(reference.bytes*4+1048576)
            match(artifacts.openDocumentDataInput(reference,{file=>input=Some(file);Result.Ok(())})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let bytes=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0);let file=input.getOrThrow()
            let hash=SHA256();var count:Int64=0
            while(true){
                if(stop.load()){return hostPluginResourceError("plugin.document_query_closed","frozen result owner was closed")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(size==0){break}
                if(size>reference.bytes-count){return hostPluginResourceError("plugin.document_result_file_changed","frozen result exceeds its complete size")}
                let part=buffer[..size];hash.write(part);bytes.add(all:part);count+=size}
            if(count!=reference.bytes || hostArtifactHex(hash.finish())!=reference.digest){
                return hostPluginResourceError("plugin.document_result_file_changed","full frozen result hash/size changed")}
            let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
            charge.ensureRetainedPeak(reference.bytes*8+nodes*512+1048576)
            charge.ensureDecoded(raw.size,nodes)
            let value=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
            if(encodeAgentValue(value)!=raw || encodeStoredValue(value).size>8388608){
                return hostPluginResourceError("plugin.document_result_codec_invalid","full frozen result does not match its canonical durable codec")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(file.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>input=None}
            if(!retain){return Result.Ok(nullValue())}
            resultReservation=Some(charge);outputPending.store(true);transferred=true;Result.Ok(value)
        }catch(_:LogicalJsonPayloadError){hostPluginResourceError("plugin.document_result_capacity","full frozen result exceeded its original shared allocation/shape bound")}
        catch(_:Exception){hostPluginResourceError("plugin.document_result_codec_invalid","full frozen result cannot be decoded")}
        finally{if(!transferred){charge.close()}}
    }
    // Every byte is selected by the preceding plural canonical authorization.
    // The existing fixed buffer/file owner and shared payload pool remain sole.
    // A decoded pure output stays in this same paid owner until the caller
    // consumes it and acknowledgesOutput(). Its own private writer/fd is the
    // only input; publishing a metadata-only document grant is unnecessary.
    public func readPrivateContextValue(writer:HostServiceArtifactWriter,maximum:Int64,
        current:()->Result<Unit>):Result<AgentValue>{
        if(closed || !started || finished || resultReservation.isSome() || stop.load() ||
            maximum<1 || maximum>RUN_CONTEXT_SNAPSHOT_MAX_BYTES){
            return hostPluginResourceError("context.document_result_closed","private context value is single use within its original owner")}
        var owned=false
        for(actual in writers where refEq(actual,writer)){owned=true}
        if(!owned){return hostPluginResourceError("context.document_result_owner","private context output belongs to another paid session")}
        let expected=writer.completedArtifact()
        if(expected.bytes<1 || expected.bytes>maximum){
            return hostPluginResourceError("context.document_result_limit","pure context result exceeds its original bounded codec")}
        let charge=reserveNativeDocumentPayload(expected.bytes)
        var transferred=false
        try{
            // Charge all raw backing/copies before either array or fd exists.
            charge.ensureRetainedPeak(expected.bytes*4+1048576)
            let result=match(writer.withPrivateContextResultInput(current,{file,artifact=>
                let bytes=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0)
                let hash=SHA256();var count:Int64=0
                while(true){
                    if(stop.load()){return hostPluginResourceError<AgentValue>("context.document_result_closed","private context owner was closed")}
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>artifact.bytes-count){return hostPluginResourceError<AgentValue>("context.document_result_changed","private context output exceeds its frozen complete size")}
                    let part=buffer[..size];hash.write(part);bytes.add(all:part);count+=size}
                if(count!=artifact.bytes || hostArtifactHex(hash.finish())!=artifact.sha256){
                    return hostPluginResourceError<AgentValue>("context.document_result_changed","private context output changed after its declared hash")}
                let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
                charge.ensureRetainedPeak(artifact.bytes*8+nodes*512+1048576)
                charge.ensureDecoded(raw.size,nodes)
                let value=parseUnifiedJson(raw,maxBytes:maximum,maxDepth:32)
                if(encodeAgentValue(value)!=raw || encodeStoredValue(value).size>maximum){
                    return hostPluginResourceError<AgentValue>("context.document_result_codec","private context output is not its complete canonical codec")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(value)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            resultReservation=Some(charge);outputPending.store(true);transferred=true;Result.Ok(result)
        }catch(_:LogicalJsonPayloadError){hostPluginResourceError("context.document_result_capacity","private context value exhausted its original shared allocation")}
        catch(_:Exception){hostPluginResourceError("context.document_result_codec","private context output cannot be decoded within its original bound")}
        finally{if(!transferred){charge.close()}}
    }

    func readPrivateLiveToolValue(writer:HostServiceArtifactWriter,
        current:()->Result<Unit>):Result<AgentValue>{
        let maximum:Int64=8388608
        if(closed || !started || finished || resultReservation.isSome() || stop.load() || !executionPending.load() || workerCleanup.isSome() ||
            maximum<1 || maximum>8388608){
            return hostPluginResourceError("context.document_result_closed","private context value is single use within its original owner")}
        var owned=false
        for(actual in writers where refEq(actual,writer)){owned=true}
        if(!owned){return hostPluginResourceError("context.document_result_owner","private context output belongs to another paid session")}
        let expected=writer.completedArtifact()
        if(expected.bytes<1 || expected.bytes>maximum){
            return hostPluginResourceError("context.document_result_limit","pure context result exceeds its original bounded codec")}
        let charge=reserveNativeDocumentPayload(expected.bytes)
        var transferred=false
        try{
            // Charge all raw backing/copies before either array or fd exists.
            charge.ensureRetainedPeak(expected.bytes*4+1048576)
            let result=match(writer.withPrivateContextResultInput(current,{file,artifact=>
                let bytes=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0)
                let hash=SHA256();var count:Int64=0
                while(true){
                    if(stop.load()){return hostPluginResourceError<AgentValue>("context.document_result_closed","private context owner was closed")}
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>artifact.bytes-count){return hostPluginResourceError<AgentValue>("context.document_result_changed","private context output exceeds its frozen complete size")}
                    let part=buffer[..size];hash.write(part);bytes.add(all:part);count+=size}
                if(count!=artifact.bytes || hostArtifactHex(hash.finish())!=artifact.sha256){
                    return hostPluginResourceError<AgentValue>("context.document_result_changed","private context output changed after its declared hash")}
                let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
                charge.ensureRetainedPeak(artifact.bytes*8+nodes*512+1048576)
                charge.ensureDecoded(raw.size,nodes)
                let value=parseUnifiedJson(raw,maxBytes:maximum,maxDepth:32)
                if(encodeAgentValue(value)!=raw || encodeStoredValue(value).size>maximum){
                    return hostPluginResourceError<AgentValue>("context.document_result_codec","private context output is not its complete canonical codec")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(value)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            resultReservation=Some(charge);outputPending.store(true);transferred=true;Result.Ok(result)
        }catch(_:LogicalJsonPayloadError){hostPluginResourceError("context.document_result_capacity","private context value exhausted its original shared allocation")}
        catch(_:Exception){hostPluginResourceError("context.document_result_codec","private context output cannot be decoded within its original bound")}
        finally{if(!transferred){charge.close()}}
    }

    // Only this running Session's already-adopted finished writer can enter.
    // This decoder retains the COMPLETE descriptor and output in the one
    // original shared Native pool. No Native memory invoice or new pool exists.
    func readPrivateManagedChannelTerminal(writer:HostServiceArtifactWriter,context:ToolInvocationContext,
        parent:PreparedToolInvocation,current:()->Result<Unit>):Result<AgentValue>{
        let maximum:Int64=8388608
        if(closed || !started || finished || stop.load() || !executionPending.load() || workerCleanup.isSome() ||
            resultReservation.isSome() || managedChannelTerminal.isSome() || managedChannelTerminalFile.isSome()){
            return hostPluginResourceError("managed_channel.terminal_decoder_closed","same actual running output owner is unavailable")}
        var adopted=false
        for(actual in writers where refEq(actual,writer)){adopted=true}
        if(!adopted){return hostPluginResourceError("managed_channel.terminal_writer_changed","terminal writer belongs to another actual Session")}
        let expected=writer.completedArtifact()
        if(expected.bytes<1 || expected.bytes>maximum){
            return hostPluginResourceError("managed_channel.terminal_limit","complete terminal exceeds the original stored result ceiling")}
        let owner=reserveNativeDocumentPayload(1)
        var transferred=false
        try{
            let references=hostManagedChannelTerminalReferencePeak(context,parent)
            owner.ensureRetainedPeak(references+expected.bytes*4+1048576)
            let decoded=match(writer.withPrivateContextResultInput(current,{file,artifact=>
                let bytes=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0);let hash=SHA256();var count:Int64=0
                while(true){
                    if(stop.load()){return hostPluginResourceError<AgentValue>("managed_channel.terminal_cancelled","actual output owner was closed")}
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>artifact.bytes-count){return hostPluginResourceError<AgentValue>("managed_channel.terminal_bytes_changed","complete output exceeded its actual finished writer")}
                    let part=buffer[..size];hash.write(part);bytes.add(all:part);count+=size
                }
                if(count!=artifact.bytes || hostArtifactHex(hash.finish())!=artifact.sha256){
                    return hostPluginResourceError<AgentValue>("managed_channel.terminal_bytes_changed","actual fixed FD did not reach full hash and EOF")}
                let encoded=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(encoded)
                // Original raw backing, both encoder Strings, descriptor DOM,
                // output/protocol subreferences and original Prepared metadata
                // coexist. Prepay their SUM before parse or either encoder.
                owner.ensureRetainedPeak(references+artifact.bytes*16+nodes*1024+1048576)
                owner.ensureDecoded(encoded.size,nodes)
                let descriptor=parseUnifiedJson(encoded,maxBytes:maximum,maxDepth:64)
                if(encodeAgentValue(descriptor)!=encoded ||
                    encodeStoredValue(descriptor.field("output").getOrThrow()).size>maximum ||
                    !hostManagedChannelTerminalDescriptorValid(descriptor,parent)){
                    return hostPluginResourceError<AgentValue>("managed_channel.terminal_codec_changed","terminal changed its complete original codec or precise parent")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(descriptor)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            // Writer verification/close has ACKed before publication. This
            // Host-private carrier is data only and cannot mint a Source.
            let retained=match(artifacts.publishManagedChannelTerminal(writer,current)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let measure=HostManagedGrantRetainedMeasure();measure.add(decoded)
            let peak=references+expected.bytes*16+measure.peak()+1048576
            owner.ensureRetainedPeak(peak)
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            resultReservation=Some(owner);managedChannelTerminal=Some(decoded)
            managedChannelTerminalFile=Some(retained);managedChannelRetainedPeak=peak
            outputPending.store(true);transferred=true;Result.Ok(decoded)
        }catch(_:LogicalJsonPayloadError){hostPluginResourceError("managed_channel.terminal_capacity","complete terminal exhausted the original shared allocation")}
        catch(_:Exception){hostPluginResourceError("managed_channel.terminal_codec_failed","complete terminal could not be captured by the same actual owner")}
        finally{if(!transferred){owner.close()}}
    }

    // The managed terminal keeps its paid output while the same physical
    // worker, FD and writer cleanup ACKs. Original transient entry is unchanged.
    func releaseManagedChannelTerminalTransient():Result<Unit>{
        lock.lock();try{
            if(!finished || !terminal.load() || !executionPending.load() || !outputPending.load() ||
                managedChannelTerminal.isNone() || managedChannelTerminalFile.isNone() || resultReservation.isNone()){
                return hostPluginResourceError("managed_channel.terminal_transient_missing","same completed actual output is not retained")}
            cleanup(allowOutputPending:true,allowExecutionPending:true)
        }finally{lock.unlock()}
    }

    func captureManagedChannelOutputLease(onAck:()->Unit):Result<ToolResultPayloadLease>{
        lock.lock();try{
            if(closed || !finished || !terminal.load() || stop.load() || released || !executionPending.load() ||
                !outputPending.load() || resultReservation.isNone() || managedChannelTerminal.isNone() ||
                managedChannelTerminalFile.isNone() || managedChannelToolLease.isSome() || livePolicyToolLease.isSome() ||
                workerCleanup.isSome() || input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("managed_channel.terminal_lease_missing","same physically finished output cannot transfer another lease")}
            let lease=ToolResultPayloadLease(onAck);managedChannelToolLease=Some(lease);Result.Ok(lease)
        }finally{lock.unlock()}
    }

    func withManagedChannelTerminalOutput(lease:ToolResultPayloadLease,guard:()->Result<Unit>,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        lock.lock();try{
            if(closed || !finished || !terminal.load() || stop.load() || released || !executionPending.load() ||
                !outputPending.load() || resultReservation.isNone() || managedChannelTerminal.isNone() ||
                managedChannelTerminalFile.isNone() || managedChannelToolLease.isNone() ||
                !refEq(managedChannelToolLease.getOrThrow(),lease) || workerCleanup.isSome() || input.isSome() ||
                latestJournalInput.isSome() || !writers.isEmpty() || managedChannelRetainedPeak<1){
                return hostPluginResourceError("managed_channel.terminal_owner_missing","same actual finished output and lease are unavailable")}
            let descriptor=managedChannelTerminal.getOrThrow();let owner=resultReservation.getOrThrow()
            let peak=managedChannelRetainedPeak
            owner.ensureRetainedPeak(peak)
            artifacts.withManagedChannelTerminalFile(managedChannelTerminalFile.getOrThrow(),{reader=>
                if(input.isSome()){return hostPluginResourceError<Unit>("managed_channel.terminal_fd_owned","another actual fixed input is retained")}
                input=Some(reader);Result<Unit>.Ok(())},{reader=>
                if(input.isNone() || !refEq(input.getOrThrow(),reader)){
                    return hostPluginResourceError<Unit>("managed_channel.terminal_fd_changed","terminal fixed FD owner changed")}
                match(reader.close()){case Result.Err(error)=>Result<Unit>.Err(error)
                    case Result.Ok(_)=>input=None;Result<Unit>.Ok(())}},guard,
                {verify=>consume(descriptor,owner,peak,verify)})
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("managed_channel.terminal_owner_unverified","actual retained terminal proof did not complete")}
        finally{lock.unlock()}
    }

    // Canonical Core output aliases remain paid after physical cleanup.
    // This derives actual allocation custody from the COMPLETE decoded result,
    // never the small metadata reservation or an invented capacity promise.
    func retainManagedChannelCanonicalBacking(lease:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(closed || !finished || !terminal.load() || released || !executionPending.load() ||
                !outputPending.load() || resultReservation.isNone() || managedChannelTerminal.isNone() ||
                managedChannelToolLease.isNone() || !refEq(managedChannelToolLease.getOrThrow(),lease) ||
                managedChannelRetainedPeak<1){
                return hostPluginResourceError("managed_channel.canonical_backing_missing",
                    "only this same actual decoded output can retain its original allocation")}
            let original=resultReservation.getOrThrow()
            let backing=original.deriveRetainedLease()
            var transferred=false
            try{
                // SUM includes original Session data and still-visible Core
                // aliases until that Session has acknowledged actual cleanup.
                backing.ensureRetainedPeak(managedChannelRetainedPeak)
                transferred=true;Result.Ok(backing)
            }finally{if(!transferred){backing.close()}}
        }catch(_:Exception){hostPluginResourceError("managed_channel.canonical_backing_capacity",
            "original shared output allocation cannot retain canonical aliases")}
        finally{lock.unlock()}
    }

    // Source/current/deadline are intentionally absent from own cleanup.
    // An already closed Unit lease cannot manufacture or suppress this ACK.
    func acknowledgeManagedChannelTerminal(lease:ToolResultPayloadLease):Result<Unit>{
        lock.lock();try{
            if(released){return if(managedChannelClosedLease.isSome() && refEq(managedChannelClosedLease.getOrThrow(),lease)){
                Result.Ok(())}else{hostPluginResourceError("managed_channel.terminal_cleanup_lease_changed","only the exact released lease may retry its own ACK")}}
            if(managedChannelToolLease.isNone() || !refEq(managedChannelToolLease.getOrThrow(),lease)){
                return hostPluginResourceError("managed_channel.terminal_cleanup_lease_changed","cleanup must use this actual retained output lease")}
            // Clear data references before the original result owner refunds.
            // Retain the exact lease separately for retry after failed FD ACK.
            managedChannelTerminal=None;managedChannelTerminalFile=None;managedChannelRetainedPeak=0
            outputPending.store(false)
            match(cleanup(allowExecutionPending:true)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            executionPending.store(false);closed=true;finished=true;terminal.store(true)
            match(cleanup()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            managedChannelClosedLease=Some(lease);managedChannelToolLease=None
            if(!released || workerCleanup.isSome() || input.isSome() || latestJournalInput.isSome() ||
                !writers.isEmpty() || resultReservation.isSome() || outputPending.load() || executionPending.load()){
                return hostPluginResourceError("managed_channel.terminal_cleanup_pending","same actual resources have not acknowledged complete release")}
            Result.Ok(())
        }catch(_:Exception){hostPluginResourceError("managed_channel.terminal_cleanup_pending","actual terminal owner retains its failed cleanup debt")}
        finally{lock.unlock()}
    }

    // Called only from the same active run callback after Native's physical
    // loan ACK. No descriptor invoice replaces this actual metadata owner.
    func retainLivePolicyParentOutput(context:ToolInvocationContext,parent:PreparedToolInvocation,descriptor:AgentValue,
        writer:HostServiceArtifactWriter,guard:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load() || resultReservation.isNone() || !outputPending.load()){
            return hostPluginResourceError("plugin.live_terminal_owner_missing","actual decoded final output is not retained by this running Session")}
        var adopted=false
        for(actual in writers where refEq(actual,writer)){adopted=true}
        if(!adopted){return hostPluginResourceError("plugin.live_terminal_writer_owner","terminal writer belongs to another Session")}
        let result=HostLivePolicyTerminalUnit250()
        try{
            withLivePolicyRunningMetadata(descriptor,{owner,peak=>
                result.value=artifacts.retainLivePolicyParentOutput(context,parent,descriptor,writer,owner,peak,guard)})
            result.value
        }catch(_:Exception){hostPluginResourceError("plugin.live_terminal_retention_unverified","terminal data pin did not finish with its actual paid owner")}
    }

    // One real resultReservation becomes one allocation lease. It grants no
    // Source or completion authority; the Store still checks every byte and
    // current canonical predicate. Core closes it only after result use/ACK.
    func captureLivePolicyOutputLease():Result<ToolResultPayloadLease>{
        lock.lock();try{
            if(closed || !finished || !terminal.load() || stop.load() || released || !executionPending.load() ||
                resultReservation.isNone() || !outputPending.load() || livePolicyToolLease.isSome() ||
                workerCleanup.isSome() || input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_terminal_lease_missing","same completed Session cannot transfer another output allocation")}
            let lease=ToolResultPayloadLease({=>acknowledgeOutput();let _=closeExecutionDataOwner()})
            livePolicyToolLease=Some(lease);Result.Ok(lease)
        }finally{lock.unlock()}
    }

    // Opt-in final Tool output transient ACK. The original retained context
    // method stays unchanged. The actual output and its payment remain held;
    // only completed worker, fixed input and writer cleanup is acknowledged.
    func releaseLivePolicyOutputTransient292():Result<Unit>{
        if(running.load() && !terminal.load()){
            return hostPluginResourceError("plugin.document_query_cleanup_pending","active query still owns its transient resources")}
        lock.lock();try{
            if(!executionPending.load() || !finished || !terminal.load() || !outputPending.load() || resultReservation.isNone()){
                return hostPluginResourceError("plugin.live_terminal_owner_missing","same retained final output has not completed its callback")}
            cleanup(allowOutputPending:true,allowExecutionPending:true)
        }finally{lock.unlock()}
    }

    // Separate opt-in lease: the old Unit callback is untouched. Unit close
    // propagates cleanup failure, while the retained DataOwner can retry the
    // real Result even after that Unit lease's one-shot released flag is set.
    func captureAcknowledgedLivePolicyOutputLease292():Result<ToolResultPayloadLease>{
        lock.lock();try{
            if(closed || !finished || !terminal.load() || stop.load() || released || !executionPending.load() ||
                resultReservation.isNone() || !outputPending.load() || livePolicyToolLease.isSome() ||
                workerCleanup.isSome() || input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_terminal_lease_missing","same completed Session cannot transfer another output allocation")}
            let lease=ToolResultPayloadLease({=>
                match(closeAcknowledgedLivePolicyOutput292()){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            livePolicyToolLease=Some(lease);Result.Ok(lease)
        }finally{lock.unlock()}
    }

    func closeRetainedLivePolicyOutput292(actual:ToolResultPayloadLease):Result<Unit>{
        lock.lock();try{
            if(livePolicyToolLease.isNone() || !refEq(livePolicyToolLease.getOrThrow(),actual)){
                return hostPluginResourceError("plugin.live_terminal_lease_changed","another allocation lease cannot acknowledge this actual Session")}
            livePolicyOutputOwnerAcknowledged292=true
        }finally{lock.unlock()}
        closeAcknowledgedLivePolicyOutput292()
    }

    private func closeAcknowledgedLivePolicyOutput292():Result<Unit>{
        // Cleanup remains available on cancel/stale/closed Source. It grants
        // no operation authority, creates no Receipt and does no current check.
        lock.lock();try{
            if(livePolicyToolLease.isNone() || !finished || !terminal.load()){
                return hostPluginResourceError("plugin.live_terminal_lease_missing","same completed output lease was never captured")}
            if(released){return Result<Unit>.Ok(())}
            if(!livePolicyOutputOwnerAcknowledged292){
                return hostPluginResourceError("plugin.live_terminal_data_owner_ack_pending","actual retained data owner has not dropped its descriptor handle")}
            if(!executionPending.load()){
                return hostPluginResourceError("plugin.live_execution_owner_unavailable","actual unrefunded output custody changed")}
            // The caller has dropped the large result first. cleanup closes
            // real worker/FD/writers before resultReservation. Failure keeps
            // the SAME execution flag and collector owner for a real retry.
            outputPending.store(false)
            match(cleanup(allowExecutionPending:true)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            executionPending.store(false);closed=true;finished=true;terminal.store(true)
            cleanup()
        }finally{lock.unlock()}
    }

    // Separate opt-in canonical consumer backing. Its ancestor is the SAME
    // paid original Tool decoder reservation, never Session metadata. The
    // shared ledger keeps original allocation/floor/high-water charge alive
    // after physical result ACK until the last actual canonical alias retires.
    func retainLivePolicyCanonicalBacking301(actual:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(closed || released || !finished || !terminal.load() || !executionPending.load() ||
                !outputPending.load() || resultReservation.isNone() || livePolicyToolLease.isNone() ||
                !refEq(livePolicyToolLease.getOrThrow(),actual)){
                return hostPluginResourceError("plugin.live_canonical_backing_unavailable",
                    "canonical backing requires this actual unacknowledged paid Tool output")}
            let child=try{resultReservation.getOrThrow().deriveRetainedLease()}
                catch(_:Exception){return hostPluginResourceError("plugin.live_canonical_backing_unpaid",
                    "same actual output reservation could not retain its canonical consumer")}
            try{
                // Actual per-consumer envelope cells coexist with every live
                // original result/alias peak in this SAME aggregate and slot.
                child.ensureRetainedPeak(8192)
                Result<LogicalJsonOwnerReservation>.Ok(child)
            }catch(_:Exception){
                child.close()
                hostPluginResourceError("plugin.live_canonical_backing_unpaid",
                    "same aggregate cannot pay its additional canonical consumer cells")}
        }finally{lock.unlock()}
    }

    func withLivePolicyTerminalOutput(lease:ToolResultPayloadLease,descriptor:AgentValue,guard:()->Result<Unit>,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        // Full Host/Registry current checks occur outside this borrower in the
        // private DataOwner. Inside are only same-owner state/fixed-file checks.
        let result=HostLivePolicyTerminalUnit250()
        try{
            withLivePolicyFinishedMetadata(descriptor,{owner,peak=>
                if(livePolicyToolLease.isNone() || !refEq(livePolicyToolLease.getOrThrow(),lease)){
                    throw IllegalStateException("terminal lease was not captured from this actual Session")}
                result.value=artifacts.withLivePolicyTerminalFile(descriptor,{reader=>
                    if(input.isSome()){return hostPluginResourceError<Unit>("plugin.live_terminal_fd_owned","another fixed input is still owned")}
                    input=Some(reader);Result<Unit>.Ok(())},{reader=>
                    if(input.isNone() || !refEq(input.getOrThrow(),reader)){
                        return hostPluginResourceError<Unit>("plugin.live_terminal_fd_changed","terminal FD ownership changed")}
                    match(reader.close()){case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>input=None;Result<Unit>.Ok(())}},
                    guard,{verify=>consume(descriptor,owner,peak,verify)})
            })
            result.value
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_terminal_owner_unverified","same finished output owner did not complete its actual proof")}
    }

    public func readWindowManifestPages(reference:PluginDocumentPayloadReference,current:()->Result<Unit>):Result<AgentValue>{
        if(closed || !started || finished || input.isSome() || resultReservation.isSome() || stop.load() ||
            !approved.contains(reference.digest+":"+reference.bytes.toString())){
            return hostPluginResourceError("plugin.document_query_closed","full frozen result decoder is single use per live read")}
        let charge=reserveNativeDocumentPayload(reference.bytes)
        try{
            // Eight byte extents cover read backing growth, byte/text copies,
            // canonical validation, sink encoding and durable codec copies.
            // Value+field cells are prepaid before full raw/DOM allocation.
            charge.ensureRetainedPeak(reference.bytes*4+1048576)
            match(artifacts.openDocumentDataInput(reference,{file=>input=Some(file);Result.Ok(())})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let bytes=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0);let file=input.getOrThrow()
            let hash=SHA256();var count:Int64=0
            while(true){
                if(stop.load()){return hostPluginResourceError("plugin.document_query_closed","frozen result owner was closed")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(size==0){break}
                if(size>reference.bytes-count){return hostPluginResourceError("plugin.document_result_file_changed","frozen result exceeds its complete size")}
                let part=buffer[..size];hash.write(part);bytes.add(all:part);count+=size}
            if(count!=reference.bytes || hostArtifactHex(hash.finish())!=reference.digest){
                return hostPluginResourceError("plugin.document_result_file_changed","full frozen result hash/size changed")}
            let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
            charge.ensureRetainedPeak(reference.bytes*8+nodes*512+1048576)
            charge.ensureDecoded(raw.size,nodes)
            let value=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
            if(encodeAgentValue(value)!=raw || encodeStoredValue(value).size>8388608){
                return hostPluginResourceError("plugin.document_result_codec_invalid","full frozen result does not match its canonical durable codec")}
            // Compute only compact selectors while the complete raw/DOM
            // charge is alive; no large manifest value escapes this owner.
            let pages=match(hostRowJournalPages(value,reference.digest)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(file.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>input=None}
            Result.Ok(pages)
        }catch(_:LogicalJsonPayloadError){hostPluginResourceError("plugin.document_result_capacity","full frozen result exceeded its original shared allocation/shape bound")}
        catch(_:Exception){hostPluginResourceError("plugin.document_result_codec_invalid","full frozen result cannot be decoded")}
        finally{charge.close()}
    }
    // Adopt before any actual stream FD/buffer opens. The default input,
    // worker and final-output owners retain their original cleanup semantics.
    // Constructs an inert owner only. The actual completed fact and private
    // Store proof are checked by ArtifactStore inside its original SQL TX.
    public func createLatestJournalInput(link:ContextReadFactLink,binding:AgentValue,data:AgentValue,
        current:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>,
        end:(Int64)->Result<Bool>):Result<HostLatestJournalStreamInputReader>{
        if(closed || !started || finished || stop.load() || latestJournalInput.isSome()){
            return hostPluginResourceError("plugin.latest_input_closed","actual session cannot adopt another journal input")}
        let reader=artifacts.latestJournalInputReader(link,binding,data,current,consume,end)
        match(retainLatestJournalInput(reader)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(reader)
    }

    public func retainLatestJournalInput(reader:HostLatestJournalStreamInputReader):Result<Unit>{
        if(closed || !started || finished || stop.load() || latestJournalInput.isSome()){
            return hostPluginResourceError<Unit>("plugin.document_query_closed","actual latest input must be adopted in its original live query")}
        latestJournalInput=Some(reader);Result<Unit>.Ok(())
    }
    public func retainWorkerCleanup(dispose:()->Bool):Result<Unit>{
        if(closed || !started || finished || workerCleanup.isSome()){
            return hostPluginResourceError("plugin.document_query_closed","pure worker cleanup must be adopted inside the original query")}
        workerCleanup=Some(dispose);Result.Ok(())
    }
    public func acknowledgeWorkerRelease():Unit{workerCleanup=None}
    // The supplied callback is a Host-private completed-history proof. A
    // serializable reference, metadata row or prepared GC pin cannot supply it.
    public func uploadPrepared(reference:PluginDocumentPayloadReference,authorize:()->Result<Unit>,
        current:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","historical upload window is closed")}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(authorize()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        approved.add(reference.digest+":"+reference.bytes.toString())
        upload(reference,current,consume)
    }
    // An opaque completed-history reader owns read authority and its buffer.
    // This seam transports already-authorized bytes and opens no source.
    public func consumePreparedInput(source:(()->Result<Unit>,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>,
        current:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","historical data transfer window is closed")}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source(current,consume)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        current()
    }
    public func authorize(link:ContextReadFactLink,binding:AgentValue,data:AgentValue,current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || !approved.isEmpty()){return hostPluginResourceError("plugin.document_query_closed","document input authorization is one-shot")}
        match(artifacts.authorizeDocumentDataInput(link,binding,data,current)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        for(item in data.field("documents").getOrThrow().items){
            let reference=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
            approved.add(reference.digest+":"+reference.bytes.toString())}
        Result.Ok(())
    }
    // Canonical Store validation covers every completed fact in order.
    // Metadata and a first-fact reference cannot authorize later pages.
    public func authorizeWindows(links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue,
        current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || !approved.isEmpty() || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","window input authorization is one-shot")}
        match(artifacts.authorizeDocumentWindowDataInput(links,binding,dataList,current)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        for(data in dataList.items){
            for(item in data.field("documents").getOrThrow().items){
                let reference=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
                approved.add(reference.digest+":"+reference.bytes.toString())}}
        Result.Ok(())
    }
    public func authorizeWindowPrefix(links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue,
        current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || !approved.isEmpty() || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","window input authorization is one-shot")}
        match(artifacts.authorizeDocumentWindowPrefix(links,binding,dataList,current)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        for(data in dataList.items){
            for(item in data.field("documents").getOrThrow().items){
                let reference=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
                approved.add(reference.digest+":"+reference.bytes.toString())}}
        Result.Ok(())
    }
    // Synchronous private callback under run(). No file path crosses IPC.
    public func upload(reference: PluginDocumentPayloadReference, current: ()->Result<Unit>,
        consume: (Int64,Array<Byte>)->Result<Unit>): Result<Unit> {
        if(closed || !started || finished || input.isSome() || !approved.contains(reference.digest+":"+reference.bytes.toString())){
            return hostPluginResourceError("plugin.document_query_closed","document upload window has no exact canonical input")}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(artifacts.openDocumentDataInput(reference,{file=>input=Some(file);Result.Ok(())})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        try {
            let file=input.getOrThrow();let buffer=Array<Byte>(65536,repeat:0)
            // Before any byte crosses IPC, verify the complete canonical
            // digest through this same owned fd, then rewind it. Streaming
            // replay retains the original witness and checks every read.
            let verified=SHA256();var verifiedBytes:Int64=0
            while(true){
                if(stop.load()){return hostPluginResourceError("plugin.document_query_closed","document owner was closed")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let count=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(count==0){break}
                if(count>reference.bytes-verifiedBytes){return hostPluginResourceError("plugin.document_payload_file_changed","document input exceeds its frozen size")}
                verified.write(buffer[..count]);verifiedBytes+=count}
            if(verifiedBytes!=reference.bytes || hostArtifactHex(verified.finish())!=reference.digest){
                return hostPluginResourceError("plugin.document_payload_file_changed","document input was not its exact authorized bytes before upload")}
            match(file.rewind()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let hash=SHA256();var offset:Int64=0
            while(true){
                if(stop.load()){return hostPluginResourceError("plugin.document_query_closed","document owner was closed")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let count=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(count==0){break}
                if(count>reference.bytes-offset){return hostPluginResourceError("plugin.document_payload_file_changed","document input exceeds its frozen size")}
                let raw=buffer[..count];hash.write(raw)
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(consume(offset,raw)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                offset+=count
            }
            if(offset!=reference.bytes || hostArtifactHex(hash.finish())!=reference.digest){
                return hostPluginResourceError("plugin.document_payload_file_changed","document input differs from its completed canonical fact")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(file.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>input=None}
            Result.Ok(())
        }catch(_:Exception){hostPluginResourceError("plugin.document_payload_read_failed","document input could not be consumed")}
    }
    public func newWriter(): Result<HostServiceArtifactWriter> {
        if(closed || !started || finished || writers.size>=9){return hostPluginResourceError("plugin.document_query_capacity","document output owner is closed or at capacity")}
        let writer=match(artifacts.openServiceArtifactWriter()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        writers.add(writer)
        match(writer.open()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(writer)
    }
    // Store consumes the complete actual fact/call/prepared data inside
    // its paid Unit phase. Only its strict <=16 KiB read request is copied
    // into this active Session's original metadata owner. This is data,
    // never a retained Source or an approval/execution grant.
    func livePolicyInputReadRequest(parentTool:String,value:AgentValue,guard:()->Result<Unit>):Result<AgentValue>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.live_input_closed","live input binding owner is unavailable")}
        metadata.ensureRetainedPeak(16777216)
        let selected=HostLivePolicyInputReadData()
        let read=artifacts.withLivePolicyInputReadRequest(parentTool,value,guard,{request=>
            let encoded=encodeAgentValue(request)
            if(encoded.size>16384){throw IllegalStateException("actual read request exceeded its original strict bound")}
            selected.request=Some(parseUnifiedJson(encoded,maxBytes:16384))})
        match(read){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        match(selected.request){case Some(request)=>Result<AgentValue>.Ok(request)
            case None=>hostPluginResourceError("plugin.live_input_binding_missing","paid read-request data was not consumed")}
    }

    // Only bounded content identity survives the paid original JSON phase.
    // The same Session metadata owns these fixed cells; the original input
    // remains owned by its canonical caller. No complete String escapes.
    func describeLivePolicyInput(value:AgentValue,guard:()->Result<Unit>):Result<AgentValue>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.live_input_closed","live input description owner is unavailable")}
        metadata.ensureRetainedPeak(16777216)
        let description=HostLivePolicyInputDescription()
        try{
            withPluginLivePolicyInputPayloadEncoding(value,{bytes=>reserveNativeDocumentPayload(bytes)},guard,{encoded=>
                description.bytes=encoded.size;description.digest=modelPolicySha256Text(encoded)})
            Result<AgentValue>.Ok(objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
                ValueField("artifact_ref",textValue(HOST_ARTIFACT_PREFIX+description.digest)),ValueField("encoding",textValue("utf8")),
                ValueField("bytes",integerValue(description.bytes)),ValueField("sha256",textValue(description.digest)),
                ValueField("content_type",textValue(HOST_ARTIFACT_CONTENT_TYPE))]))
        }catch(error:HostArtifactOperationFailure){Result<AgentValue>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_input_encoding","complete live input description could not finish under its original owner")}
    }
    // This is a data-routing choice, never a Source or an execution approval.
    // The exact existing pin is checked before the fixed-path FD is adopted;
    // full EOF/hash/close ACK and the same pin are checked in one read TX.
    func reuseLivePolicyInput(parent:AgentValue,guard:()->Result<Unit>):Result<Bool>{
        if(closed || !started || finished || stop.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_input_closed","live input reuse owner is unavailable")}
        artifacts.reuseLivePolicyInput(parent,{reader=>input=Some(reader);Result<Unit>.Ok(())},
            {reader,expected=>verifyLivePolicyInput(reader,expected,guard)},guard)
    }
    private func verifyLivePolicyInput(reader:HostVerifiedArtifactInput,expected:PluginDocumentPayloadReference,
        guard:()->Result<Unit>):Result<Unit>{
        if(input.isNone() || !refEq(input.getOrThrow(),reader)){
            return hostPluginResourceError("plugin.live_input_reader","live input reader was not actually adopted")}
        try{
            // Original Session fixed-buffer reservation covers the buffer and
            // one bounded hash slice. Neither history nor input enters a DOM.
            let buffer=Array<Byte>(16384,repeat:0);let hasher=SHA256();var count:Int64=0
            while(true){
                if(stop.load()){return hostPluginResourceError("plugin.live_input_closed","live input owner was closed")}
                match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let read=match(reader.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(read==0){break}
                if(read>expected.bytes-count){return hostPluginResourceError("plugin.live_input_changed","live input exceeds its original complete size")}
                hasher.write(buffer[..read]);count+=read}
            if(count!=expected.bytes || hostArtifactHex(hasher.finish())!=expected.digest){
                return hostPluginResourceError("plugin.live_input_changed","live input lost its complete original byte identity")}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(reader.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>input=None}
            Result<Unit>.Ok(())
        }catch(_:Exception){hostPluginResourceError("plugin.live_input_changed","live input fixed file could not be completely verified")}
        // Every failed FD close remains on this same Session for collection.
    }

    // Exact original yjson encoding is paid by the shared Store helper.
    // Its Unit callback owns the complete String/UTF8 copy until all chunks
    // and the finished hash have been consumed. No encoded bytes escape it.
    // Generic content-only preparation input. Caller supplies a child of its
    // ORIGINAL allocation and the captured original graph, never a path or
    // arbitrary readable ref. This Session's existing collector owns the
    // writer BEFORE open and retains failed FD/writer close for real retry.
    func withPreparedBusinessInput111(value:AgentValue,description:AgentValue,
        allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
        consume:(AgentValue)->Result<AgentValue>):Result<AgentValue> {
        if(closed || !started || finished || stop.load()) {
            return hostPluginResourceError("peer.read_input_closed","original preparation input window is unavailable") }
        let expected=match(parsePluginDocumentPayloadReference(description)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        let writer=match(newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try {
            withPluginLivePolicyInputPayloadEncoding(value,allocate,guard,{encoded=>
                if(encoded.size!=expected.bytes || modelPolicySha256Text(encoded)!=expected.digest) {
                    throw IllegalStateException("captured original input changed") }
                let bytes=encoded.toArray();var offset:Int64=0
                while(offset<bytes.size) {
                    match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                    let end=min(bytes.size,offset+16384)
                    match(writer.appendBytes(offset,bytes[offset..end],PLUGIN_DOCUMENT_MAX_BYTES)) {
                        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>() }
                    offset=end
                }
                match(writer.finish(expected.bytes,expected.digest)) {
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>() }})
            let payment=allocate(1048576)
            try {
                // Complete raw buffers, String, decoded nodes and their
                // simultaneous codec copies are paid BEFORE allocation.
                payment.ensureRetainedPeak(expected.bytes*16+1048576)
                writer.withPrivateContextResultInput(guard,{reader,actual=>
                    if(actual.bytes!=expected.bytes || actual.sha256!=expected.digest) {
                        return hostPluginResourceError<AgentValue>("peer.read_input_changed","private writer differs from original input") }
                    let raw=ArrayList<Byte>();let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256()
                    while(true) {
                        match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                        let count=match(reader.read(buffer)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
                        if(count==0){break}
                        if(count>expected.bytes-raw.size) {
                            return hostPluginResourceError<AgentValue>("peer.read_input_changed","private input exceeds its complete original bytes") }
                        raw.add(all:buffer[..count]);hash.write(buffer[..count])
                    }
                    if(raw.size!=expected.bytes || hostArtifactHex(hash.finish())!=expected.digest) {
                        return hostPluginResourceError<AgentValue>("peer.read_input_changed","private input has a different full EOF or hash") }
                    let encoded=String.fromUtf8(raw.toArray())
                    let nodes=logicalJsonNodeCount(encoded)
                    if(nodes>Int64.Max/512){throw IllegalStateException("original input node invoice overflow")}
                    payment.ensureRetainedPeak(expected.bytes*16+nodes*512+1048576)
                    let input=parseUnifiedJson(encoded,maxBytes:PLUGIN_DOCUMENT_MAX_BYTES)
                    if(input.unifiedKind!=ValueKind.Object || encodeAgentValue(input)!=encoded) {
                        return hostPluginResourceError<AgentValue>("peer.read_input_changed","private input is not the original complete JSON") }
                    match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                    // Trusted package-local callback must retain/copy its
                    // escaping data on the same actual caller allocation.
                    consume(input)
                })
            }finally{payment.close()}
        }catch(error:HostArtifactOperationFailure){Result<AgentValue>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("peer.read_input_changed","original input could not be fully verified in its paid owner")}
    }

    func writeLivePolicyInput(value:AgentValue,guard:()->Result<Unit>):Result<HostServiceArtifactWriter>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.live_input_closed","live input serialization owner is unavailable")}
        let writer=match(newWriter()){case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(actual)=>actual}
        try{
            withPluginLivePolicyInputPayloadEncoding(value,{bytes=>reserveNativeDocumentPayload(bytes)},guard,{encoded=>
                let raw=encoded.toArray();var offset:Int64=0
                while(offset<raw.size){
                    match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                    let end=min(raw.size,offset+16384)
                    match(writer.appendBytes(offset,raw[offset..end],PLUGIN_DOCUMENT_MAX_BYTES)){
                        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                    offset=end}
                match(writer.finish(raw.size,modelPolicySha256(raw))){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<HostServiceArtifactWriter>.Ok(writer)
        }catch(error:HostArtifactOperationFailure){Result<HostServiceArtifactWriter>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_input_encoding","complete live input encoding could not finish under its original owner")}
    }
    func retainLivePolicyInput(parent:AgentValue,writer:HostServiceArtifactWriter,
        guard:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.live_input_closed","live input publication owner is unavailable")}
        var owned=false
        for(actual in writers where refEq(actual,writer)){owned=true}
        if(!owned){return hostPluginResourceError("plugin.live_input_writer","live input must use its actual adopted writer")}
        artifacts.retainLivePolicyInput(parent,writer,guard)
    }

    // Live opt-in can produce more than nine immutable fragments over time.
    // It keeps the original nine SIMULTANEOUS writer bound: only a genuinely
    // published/GC-pinned writer with physical close ACK leaves this array.
    func retainLivePolicyStep(context:ToolInvocationContext,parent:PreparedToolInvocation,
        descriptor:AgentValue,selected:Array<HostServiceArtifactWriter>,guard:()->Result<Unit>,streamedSource!:Bool=false):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load() || selected.isEmpty()){
            return hostPluginResourceError("plugin.live_step_session_closed","actual retained live step session is unavailable")}
        for(index in 0..selected.size){
            var adopted=false
            for(writer in writers where refEq(writer,selected[index])){adopted=true}
            if(!adopted){return hostPluginResourceError("plugin.live_step_writer_owner","step data must come from the same adopted Session")}
            for(prior in 0..index){if(refEq(selected[prior],selected[index])){
                return hostPluginResourceError("plugin.live_step_writer_repeated","same writer cannot occupy two step slots")}}
        }
        match(artifacts.retainLivePolicyStep(context,parent,descriptor,selected,guard,streamedSource:streamedSource)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Failed physical cleanup keeps the exact same writer and reservation
        // reachable by the original Session collector. Pin success is never
        // used to acknowledge another writer, worker, output or custody debt.
        for(writer in selected){
            match(writer.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            var index:Int64=0
            while(index<writers.size){if(refEq(writers[index],writer)){writers.remove(at:index);break};index++}
        }
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result<Unit>.Ok(())
    }

    // Invoked inside the original synchronous running callback. Its mutex
    // and executionPending custody stay live until all Store before/after
    // checks return. No new pool, owner, Source or file authority is created.
    func consumeLivePolicyKnownProposalPayloadsNativeAbort328(context:ToolInvocationContext,parent:PreparedToolInvocation,
        sequence:Int64,through:Int64,ledger:AgentValue,retainedOwner:LogicalJsonOwnerReservation,retainedPeak:Int64,
        guard:()->Result<Unit>,
        consume:(AgentValue,PluginDocumentPayloadReference,AgentValue,AgentValue,
            (PluginDocumentPayloadReference,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>)->Unit):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load() ||
            input.isSome() || !refEq(retainedOwner,metadata) || retainedPeak<1){
            return hostPluginResourceError("plugin.live_history_session_closed","same running metadata/FD owner required")}
        let phase=HostLivePolicyHistoryPhase288(retainedPeak)
        metadata.ensureRetainedPeak(hostLiveStepAdd248(retainedPeak,2097152))
        let adopt:(HostVerifiedArtifactInput)->Result<Unit>={reader=>
            if(closed || stop.load() || !running.load() || !executionPending.load() || input.isSome()){
                return hostPluginResourceError("plugin.live_history_input_busy","same Session cannot replace an unacknowledged FD")}
            input=Some(reader);Result<Unit>.Ok(())}
        let rawReader:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,
            (Int64,Array<Byte>)->Result<Unit>)->Result<(Int64,String)>={reader,reference,current,observe=>
            readLivePolicyHistoricalRaw288(reader,reference,current,observe,phase.peak)}
        let indexReader:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,
            (AgentValue)->Unit)->Result<(Int64,String)>={reader,reference,current,use=>
            if(reference.bytes<1 || reference.bytes>8388608){
                return hostPluginResourceError<(Int64,String)>("plugin.live_history_index_bound","original single-Blob index bound required")}
            // ArrayList growth, final Array, UTF8 String and complete DOM
            // coexist. The original message floor remains sixteen MiB.
            let rawPeak=hostLiveStepAdd248(retainedPeak,hostLiveStepAdd248(2097152,reference.bytes*8))
            metadata.ensureRetainedPeak(rawPeak)
            let bytes=ArrayList<Byte>()
            let copied=match(readLivePolicyHistoricalRaw288(reader,reference,current,{_,raw=>bytes.add(all:raw);Result<Unit>.Ok(())},rawPeak)){
                case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
            // Physical close ACK and input=None precede nested member reads.
            if(input.isSome()){return hostPluginResourceError<(Int64,String)>("plugin.live_history_index_ack_missing","original index FD is still retained")}
            let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
            let indexPeak=hostLiveStepAdd248(rawPeak,nodes*512)
            metadata.ensureRetainedPeak(indexPeak)
            let value=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:256)
            if(encodeAgentValue(value)!=raw){
                return hostPluginResourceError<(Int64,String)>("plugin.live_history_index_codec","complete index changed its original JSON writer bytes")}
            match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            phase.peak=indexPeak
            try{use(value)}finally{phase.peak=retainedPeak}
            match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            Result<(Int64,String)>.Ok(copied)}
        artifacts.consumeLivePolicyKnownProposalPayloadsNativeAbort328(context,parent,sequence,through,ledger,metadata,retainedPeak,
            adopt,indexReader,rawReader,guard,consume)
    }

    func consumeLivePolicyKnownProposalPayloads(context:ToolInvocationContext,parent:PreparedToolInvocation,
        sequence:Int64,through:Int64,ledger:AgentValue,retainedOwner:LogicalJsonOwnerReservation,retainedPeak:Int64,
        guard:()->Result<Unit>,
        consume:(AgentValue,PluginDocumentPayloadReference,AgentValue,AgentValue,
            (PluginDocumentPayloadReference,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>)->Unit):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load() ||
            input.isSome() || !refEq(retainedOwner,metadata) || retainedPeak<1){
            return hostPluginResourceError("plugin.live_history_session_closed","same running metadata/FD owner required")}
        let phase=HostLivePolicyHistoryPhase288(retainedPeak)
        metadata.ensureRetainedPeak(hostLiveStepAdd248(retainedPeak,2097152))
        let adopt:(HostVerifiedArtifactInput)->Result<Unit>={reader=>
            if(closed || stop.load() || !running.load() || !executionPending.load() || input.isSome()){
                return hostPluginResourceError("plugin.live_history_input_busy","same Session cannot replace an unacknowledged FD")}
            input=Some(reader);Result<Unit>.Ok(())}
        let rawReader:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,
            (Int64,Array<Byte>)->Result<Unit>)->Result<(Int64,String)>={reader,reference,current,observe=>
            readLivePolicyHistoricalRaw288(reader,reference,current,observe,phase.peak)}
        let indexReader:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,
            (AgentValue)->Unit)->Result<(Int64,String)>={reader,reference,current,use=>
            if(reference.bytes<1 || reference.bytes>8388608){
                return hostPluginResourceError<(Int64,String)>("plugin.live_history_index_bound","original single-Blob index bound required")}
            // ArrayList growth, final Array, UTF8 String and complete DOM
            // coexist. The original message floor remains sixteen MiB.
            let rawPeak=hostLiveStepAdd248(retainedPeak,hostLiveStepAdd248(2097152,reference.bytes*8))
            metadata.ensureRetainedPeak(rawPeak)
            let bytes=ArrayList<Byte>()
            let copied=match(readLivePolicyHistoricalRaw288(reader,reference,current,{_,raw=>bytes.add(all:raw);Result<Unit>.Ok(())},rawPeak)){
                case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
            // Physical close ACK and input=None precede nested member reads.
            if(input.isSome()){return hostPluginResourceError<(Int64,String)>("plugin.live_history_index_ack_missing","original index FD is still retained")}
            let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
            let indexPeak=hostLiveStepAdd248(rawPeak,nodes*512)
            metadata.ensureRetainedPeak(indexPeak)
            let value=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:256)
            if(encodeAgentValue(value)!=raw){
                return hostPluginResourceError<(Int64,String)>("plugin.live_history_index_codec","complete index changed its original JSON writer bytes")}
            match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            phase.peak=indexPeak
            try{use(value)}finally{phase.peak=retainedPeak}
            match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            Result<(Int64,String)>.Ok(copied)}
        artifacts.consumeLivePolicyKnownProposalPayloads(context,parent,sequence,through,ledger,metadata,retainedPeak,
            adopt,indexReader,rawReader,guard,consume)
    }

    private func readLivePolicyHistoricalRaw288(reader:HostVerifiedArtifactInput,reference:PluginDocumentPayloadReference,
        current:()->Result<Unit>,observe:(Int64,Array<Byte>)->Result<Unit>,retainedPeak:Int64):Result<(Int64,String)>{
        if(input.isNone() || !refEq(input.getOrThrow(),reader) || closed || stop.load() || !running.load() || !executionPending.load()){
            return hostPluginResourceError<(Int64,String)>("plugin.live_history_input_owner","historical FD was not actually adopted before open")}
        metadata.ensureRetainedPeak(hostLiveStepAdd248(retainedPeak,2097152))
        let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256();var count:Int64=0
        while(true){
            if(stop.load()){return hostPluginResourceError<(Int64,String)>("plugin.live_history_input_cancelled","same retained historical FD was cancelled")}
            match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            let size=match(reader.read(buffer)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
            if(size==0){break}
            if(size>reference.bytes-count){return hostPluginResourceError<(Int64,String)>("plugin.live_history_input_changed","historical FD exceeded its full actual bytes")}
            let raw=buffer[..size];hash.write(raw)
            match(observe(count,raw)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()};count+=size
        }
        let digest=hostArtifactHex(hash.finish())
        if(count!=reference.bytes || digest!=reference.digest){
            return hostPluginResourceError<(Int64,String)>("plugin.live_history_input_changed","historical fixed FD failed its full hash and EOF")}
        match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
        // Failure leaves this exact FD on the original collector. A DTO or
        // data acknowledgement never clears physical cleanup debt.
        match(reader.close()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>input=None}
        match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
        Result<(Int64,String)>.Ok((count,digest))
    }

    func copyLivePolicyStepPayload(context:ToolInvocationContext,parent:PreparedToolInvocation,ledger:AgentValue,
        payload:PluginDocumentPayloadReference,writer:HostServiceArtifactWriter,guard:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_step_input_closed","same live Session cannot adopt another step FD")}
        var owned=false
        for(actual in writers where refEq(actual,writer)){owned=true}
        if(!owned){return hostPluginResourceError("plugin.live_step_writer_owner","step writer belongs to another actual Session")}
        metadata.ensureRetainedPeak(2097152)
        artifacts.copyLivePolicyStepPayload(context,parent,ledger,payload,{reader=>input=Some(reader);Result<Unit>.Ok(())},
            {reader,reference,current=>
                if(input.isNone() || !refEq(input.getOrThrow(),reader)){
                    return hostPluginResourceError<(Int64,String)>("plugin.live_step_input_owner","fixed input was not physically adopted before open")}
                let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256();var bytes:Int64=0
                while(true){
                    if(stop.load()){return hostPluginResourceError<(Int64,String)>("plugin.live_step_input_closed","step input owner was cancelled")}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    let size=match(reader.read(buffer)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>reference.bytes-bytes){return hostPluginResourceError<(Int64,String)>("plugin.live_step_input_changed","step input exceeded its complete actual bytes")}
                    let raw=buffer[..size];hash.write(raw)
                    match(writer.appendBytes(bytes,raw,8388608)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    bytes+=size
                }
                let digest=hostArtifactHex(hash.finish())
                if(bytes!=reference.bytes || digest!=reference.digest){return hostPluginResourceError<(Int64,String)>("plugin.live_step_input_changed","step input failed whole EOF/hash")}
                match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                match(writer.finish(bytes,digest)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                match(reader.close()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>input=None}
                Result<(Int64,String)>.Ok((bytes,digest))},guard)
    }

    func uploadLivePolicyPinnedInput(context:ToolInvocationContext,parent:PreparedToolInvocation,through:Int64,ledger:AgentValue,
        guard:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>,end:(PluginDocumentPayloadReference)->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_input_closed","same retained live Session cannot adopt another input FD")}
        artifacts.livePolicyPinnedInput(context,parent,through,ledger,{reader=>input=Some(reader);Result<Unit>.Ok(())},
            {reader,reference,current=>
                if(input.isNone() || !refEq(input.getOrThrow(),reader)){
                    return hostPluginResourceError<(Int64,String)>("plugin.live_input_owner_changed","input was not adopted before opening its FD")}
                let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256();var count:Int64=0
                while(true){
                    if(stop.load()){return hostPluginResourceError<(Int64,String)>("plugin.live_input_closed","same input owner was closed")}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    let size=match(reader.read(buffer)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>reference.bytes-count){return hostPluginResourceError<(Int64,String)>("plugin.live_input_changed","input exceeded its actual frozen whole bytes")}
                    let raw=buffer[..size];hash.write(raw)
                    match(consume(count,raw)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()};count+=size
                }
                let digest=hostArtifactHex(hash.finish())
                if(count!=reference.bytes || digest!=reference.digest){return hostPluginResourceError<(Int64,String)>("plugin.live_input_changed","input did not reach its actual full hash and EOF")}
                match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                match(end(reference)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                match(reader.close()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>input=None}
                Result<(Int64,String)>.Ok((count,digest))},guard)
    }

    // Independent opt-in actual live-effect IO. Existing read/cleanup bodies
    // stay unchanged. The synchronous run owns this same Session throughout.
    func executeLivePolicyJournalNativeAbortEffect328(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,operations:OperationRuntimePort,guard:()->Result<Unit>,
        adoptDebt:(PluginLivePolicySettlementCleanupDebt326)->Unit,adoptError:(PluginLivePolicyOuterErrorDataOwner331)->Unit,
        consumeTip:(AgentValue)->Unit):Result<Unit>{
        executeLivePolicyJournalNativeAbortEffectFrame334(context,parent,child,operations,guard,
            None<PluginLivePolicyOuterErrorFrame334>,adoptDebt,adoptError,consumeTip)
    }
    func executeLivePolicyJournalNativeAbortEffectFrame334(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,operations:OperationRuntimePort,guard:()->Result<Unit>,frame:?PluginLivePolicyOuterErrorFrame334,
        adoptDebt:(PluginLivePolicySettlementCleanupDebt326)->Unit,adoptError:(PluginLivePolicyOuterErrorDataOwner331)->Unit,
        consumeTip:(AgentValue)->Unit):Result<Unit>{
        // Actual same original metadata group is lent before Artifact -> SQL.
        // The paid DB debt pin survives this lexical borrower's finally.
        withLivePolicyNativeAbortMetadata325({loan,peak=>
            let progress=artifacts.executeLivePolicyJournalNativeAbortEffectFrame334(context,parent,child,this,operations,guard,loan,peak,consumeTip,frame)
            match(progress.errorData){case Some(data)=>adoptError(data);case None=>()}
            match(progress.cleanupDebt){case Some(debt)=>
                adoptDebt(debt)
                match(progress.result){case Result.Err(error)=>return Result<Unit>.Err(error)
                    case Result.Ok(_)=>return hostPluginResourceError<Unit>("plugin.live_database_cleanup_pending","actual debt cannot publish a Known child")}
                case None=>()}
            progress.result
        })
    }

    func executeLivePolicyJournalEffect307(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,operations:OperationRuntimePort,guard:()->Result<Unit>,
        consumeTip:(AgentValue)->Unit):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load()){
            return hostPluginResourceError("plugin.live_effect_session_closed","original running Session must own the actual effect")}
        artifacts.executeLivePolicyJournalEffect307(context,parent,child,this,operations,guard,consumeTip)
    }

    func adoptLivePolicyEffectInput306(reader:HostVerifiedArtifactInput):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_effect_input_closed","same running Session cannot adopt another effect FD")}
        metadata.ensureRetainedPeak(2097152);input=Some(reader);Result.Ok(())
    }
    func closeLivePolicyEffectInput306(reader:HostVerifiedArtifactInput):Result<Unit>{
        if(input.isNone() || !refEq(input.getOrThrow(),reader)){
            return hostPluginResourceError("plugin.live_effect_input_owner_changed","exact adopted Session FD is required")}
        match(reader.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>input=None}
        Result.Ok(())
    }
    func commitLivePolicyJournal306(proof:SqlitePluginLiveRowJournalCommitProof304,
        open:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<HostVerifiedArtifactInput>):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_effect_session_closed","actual live commit needs its same running Session")}
        let work=metadata.deriveRetainedLease()
        try{
            work.ensureRetainedPeak(4194304)
            let readIndex:LivePolicyHistoricalIndexReader={reference,current,consume=>
                let indexOwner=metadata.deriveRetainedLease()
                try{
                    indexOwner.ensureRetainedPeak(2097152+reference.bytes*8)
                    let file=match(open(reference,current)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let raw=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0);let hash=SHA256();var bytes:Int64=0
                    while(true){
                        match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                        let count=match(file.read(buffer)){
                            case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                        if(count==0){break}
                        if(count>reference.bytes-bytes){return hostPluginResourceError<(Int64,String)>("plugin.live_effect_index_changed","actual index exceeded its original full extent")}
                        let block=buffer[..count];hash.write(block);raw.add(all:block);bytes+=count
                    }
                    let digest=hostArtifactHex(hash.finish())
                    if(bytes!=reference.bytes || digest!=reference.digest){return hostPluginResourceError<(Int64,String)>("plugin.live_effect_index_changed","actual index did not finish its complete EOF/hash")}
                    // The index FD is physically closed before a callback may
                    // open a proposal member or perform any SQLite mutation.
                    match(closeLivePolicyEffectInput306(file)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    let text=String.fromUtf8(raw.toArray());let nodes=logicalJsonNodeCount(text)
                    if(nodes>Int64.Max/512 || bytes>Int64.Max/8 || nodes*512>Int64.Max-2097152-bytes*8){
                        throw IllegalStateException("original live index accounting overflow")}
                    indexOwner.ensureRetainedPeak(2097152+bytes*8+nodes*512)
                    let value=parseUnifiedJson(text,maxBytes:reference.bytes,maxDepth:32)
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    consume(value)
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    Result<(Int64,String)>.Ok((bytes,digest))
                }catch(error:HostArtifactOperationFailure){Result<(Int64,String)>.Err(error.failure)}
                catch(_:Exception){hostPluginResourceError<(Int64,String)>("plugin.live_effect_index_changed","full actual index could not be consumed")}
                finally{indexOwner.close()}
            }
            proof.materialize(readIndex,{members,current=>
                let owner=metadata.deriveRetainedLease()
                try{
                    if(match(livePolicyEffectCursor306){case Some(value)=>!value.isClosed306();case None=>false}){
                        throw IllegalStateException("same Session still retains another actual effect cursor")}
                    let cursor=HostLivePolicyProposalCursor306(members,{reference=>open(reference,current)},
                        {file=>closeLivePolicyEffectInput306(file)},current,owner)
                    livePolicyEffectCursor306=Some(cursor)
                    Result<PluginLivePolicyProposalCursor>.Ok(cursor)
                }
                catch(_:Exception){owner.close();hostPluginResourceError<PluginLivePolicyProposalCursor>("plugin.live_effect_cursor_payment","actual fixed cursor could not retain its full payment")}
            },work,4194304)
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_effect_commit_closed","same actual paid commit owner could not finish")}
        finally{work.close()}
    }
    // The actual running Session lends its ORIGINAL metadata ancestor to
    // Store's native-abort transaction pair. The loan owns no Prepared/Source
    // and does not retire any input alias or acknowledge physical Session IO.
    func withLivePolicyNativeAbortMetadata325(
        consume:(LogicalJsonOwnerReservation,Int64)->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_effect_session_closed","actual native-abort settlement requires its original running Session")}
        let owner=metadata.deriveRetainedLease()
        try{owner.ensureRetainedPeak(4194304);consume(owner,4194304)}
        finally{owner.close()}
    }
    // Distinct unused checked-failure forwarding. The old commit method,
    // readIndex error mapping, physical FD adoption and managed hooks are exact.
    func commitLivePolicyJournalNativeAbort325(proof:SqlitePluginLiveRowJournalCommitProof304,
        open:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<HostVerifiedArtifactInput>):Result<Unit>{
        if(closed || !started || finished || stop.load() || !running.load() || !executionPending.load() || input.isSome()){
            return hostPluginResourceError("plugin.live_effect_session_closed","actual live commit needs its same running Session")}
        let work=metadata.deriveRetainedLease()
        try{
            work.ensureRetainedPeak(4194304)
            let readIndex:LivePolicyHistoricalIndexReader={reference,current,consume=>
                let indexOwner=metadata.deriveRetainedLease()
                try{
                    indexOwner.ensureRetainedPeak(2097152+reference.bytes*8)
                    let file=match(open(reference,current)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let raw=ArrayList<Byte>();let buffer=Array<Byte>(65536,repeat:0);let hash=SHA256();var bytes:Int64=0
                    while(true){
                        match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                        let count=match(file.read(buffer)){
                            case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                        if(count==0){break}
                        if(count>reference.bytes-bytes){return hostPluginResourceError<(Int64,String)>("plugin.live_effect_index_changed","actual index exceeded its original full extent")}
                        let block=buffer[..count];hash.write(block);raw.add(all:block);bytes+=count
                    }
                    let digest=hostArtifactHex(hash.finish())
                    if(bytes!=reference.bytes || digest!=reference.digest){return hostPluginResourceError<(Int64,String)>("plugin.live_effect_index_changed","actual index did not finish its complete EOF/hash")}
                    // The index FD is physically closed before a callback may
                    // open a proposal member or perform any SQLite mutation.
                    match(closeLivePolicyEffectInput306(file)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    let text=String.fromUtf8(raw.toArray());let nodes=logicalJsonNodeCount(text)
                    if(nodes>Int64.Max/512 || bytes>Int64.Max/8 || nodes*512>Int64.Max-2097152-bytes*8){
                        throw IllegalStateException("original live index accounting overflow")}
                    indexOwner.ensureRetainedPeak(2097152+bytes*8+nodes*512)
                    let value=parseUnifiedJson(text,maxBytes:reference.bytes,maxDepth:32)
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    consume(value)
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    Result<(Int64,String)>.Ok((bytes,digest))
                }catch(error:HostArtifactOperationFailure){Result<(Int64,String)>.Err(error.failure)}
                // In this explicit route only, keep the actual Store INSERT
                // exception typed through the same fully paid index frame.
                // All non-INSERT exceptions remain outer failure/debt at Store.
                catch(error:Exception){throw error}
                finally{indexOwner.close()}
            }
            proof.materializeForNativeAbortRecovery324(readIndex,{members,current=>
                let owner=metadata.deriveRetainedLease()
                try{
                    if(match(livePolicyEffectCursor306){case Some(value)=>!value.isClosed306();case None=>false}){
                        throw IllegalStateException("same Session still retains another actual effect cursor")}
                    let cursor=HostLivePolicyProposalCursor306(members,{reference=>open(reference,current)},
                        {file=>closeLivePolicyEffectInput306(file)},current,owner)
                    livePolicyEffectCursor306=Some(cursor)
                    Result<PluginLivePolicyProposalCursor>.Ok(cursor)
                }
                catch(_:Exception){owner.close();hostPluginResourceError<PluginLivePolicyProposalCursor>("plugin.live_effect_cursor_payment","actual fixed cursor could not retain its full payment")}
            },work,4194304)
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(error:Exception){throw error}
        finally{work.close()}
    }
    func inspectLivePolicyWriterMetadata(writer:HostServiceArtifactWriter,current:()->Result<Unit>,
        consume:(AgentValue)->Unit):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load()){
            return hostPluginResourceError("plugin.live_metadata_closed","same retained Session metadata reader is unavailable")}
        var adopted=false
        for(value in writers where refEq(value,writer)){adopted=true}
        if(!adopted){return hostPluginResourceError("plugin.live_metadata_owner","metadata writer belongs to another Session")}
        let expected=writer.completedArtifact()
        if(expected.bytes<1 || expected.bytes>16384){return hostPluginResourceError("plugin.live_metadata_bound","only fixed small policy metadata may be inspected")}
        // Fixed buffer/slices share the original Session transport owner; the
        // actual running metadata borrow prepays the small UTF8/DOM copies.
        metadata.ensureRetainedPeak(2097152)
        writer.withPrivateLivePolicyMetadataInput(current,{file,artifact=>
            let bytes=ArrayList<Byte>();let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256();var count:Int64=0
            while(true){
                match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                let size=match(file.read(buffer)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                if(size==0){break}
                if(size>expected.bytes-count){return hostPluginResourceError<Unit>("plugin.live_metadata_changed","metadata exceeded its actual frozen bytes")}
                let raw=buffer[..size];hash.write(raw);bytes.add(all:raw);count+=size
            }
            if(count!=expected.bytes || hostArtifactHex(hash.finish())!=expected.sha256){return hostPluginResourceError<Unit>("plugin.live_metadata_changed","metadata did not reach full hash/EOF")}
            let raw=String.fromUtf8(bytes.toArray());let nodes=logicalJsonNodeCount(raw)
            metadata.ensureRetainedPeak(1048576+raw.size*8+nodes*512)
            let value=parseUnifiedJson(raw,maxBytes:16384,maxDepth:32)
            if(encodeAgentValue(value)!=raw){return hostPluginResourceError<Unit>("plugin.live_metadata_codec","metadata changed its original complete JSON codec")}
            match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            consume(value)
            current()})
    }
    func describeLivePolicyBaseJournal(context:ToolInvocationContext,parent:PreparedToolInvocation,
        through:Int64,ledger:AgentValue,guard:()->Result<Unit>,
        consume:(AgentValue,PluginDocumentLatestJournalStreamReference)->Unit):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load() || !running.load()){
            return hostPluginResourceError("plugin.live_base_descriptor_closed","actual running Session cannot retain base metadata")}
        // Includes both original request's complete small DOM/string copy and
        // its reference while the Store-owned data callback remains alive.
        metadata.ensureRetainedPeak(1048576+16384*8+16384*512)
        artifacts.describeLivePolicyBaseJournal(context,parent,through,ledger,guard,{request,reference=>
            let raw=encodeAgentValue(request)
            if(raw.size>16384){throw IllegalStateException("original actual read descriptor exceeded its strict bound")}
            consume(parseUnifiedJson(raw,maxBytes:16384,maxDepth:32),reference)},
                retainedMetadataOwner:Some(metadata),retainedMetadataPeak:1048576+16384*8+16384*512)
    }

    func readLivePolicyBaseJournal(context:ToolInvocationContext,parent:PreparedToolInvocation,
        through:Int64,reference:AgentValue,guard:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>,
        end:(Int64)->Result<Bool>,retainedMetadataPeak!:Int64=0):Result<Unit>{
        if(closed || !started || finished || stop.load() || !executionPending.load() || latestJournalInput.isSome()){
            return hostPluginResourceError<Unit>("plugin.live_base_input_session_closed","same retained live Session cannot adopt another base cursor")}
        if(retainedMetadataPeak<0){return hostPluginResourceError<Unit>("plugin.live_base_metadata_peak_missing",
            "actual running Session retained metadata cannot be negative")}
        let reader:HostLatestJournalStreamInputReader=if(retainedMetadataPeak>0){
            metadata.ensureRetainedPeak(retainedMetadataPeak)
            artifacts.livePolicyBaseJournalInput(context,parent,through,reference,guard,consume,end,
                retainedMetadataOwner:Some(metadata),retainedMetadataPeak:retainedMetadataPeak)
        }else{artifacts.livePolicyBaseJournalInput(context,parent,through,reference,guard,consume,end)}
        // Adoption before open/read: failure retains this actual FD/buffer debt
        // in the original collector; no path or handle can be replaced by DTO.
        latestJournalInput=Some(reader)
        match(reader.read()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(reader.close()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>latestJournalInput=None}
        Result<Unit>.Ok(())
    }

    // This Unit borrower is called only from the synchronous run callback,
    // whose original Session mutex already encloses all before/after Store
    // checks. close() cannot dispose this owner while running is true. The
    // callback cannot return a reservation or a decoded result as custody.
    // Its measured value is actual retained small Host metadata, not a Native
    // invoice, spare pool credit, Source, approval or physical cleanup proof.
    func withLivePolicyRunningMetadata(retained:AgentValue,consume:(LogicalJsonOwnerReservation,Int64)->Unit):Unit{
        if(closed || !started || finished || stop.load() || released || !running.load() || terminal.load() ||
            !executionPending.load()){
            throw IllegalStateException("same retained running Session metadata is unavailable")}
        let bytes=logicalJsonWriteReservationBytes(retained,65536)
        let nodes=logicalJsonValueNodeCount(retained)
        if(bytes>65536 || nodes>65536){throw IllegalArgumentException("only bounded actual live metadata can borrow the original owner")}
        let peak=1048576+bytes*8+nodes*512
        metadata.ensureRetainedPeak(peak)
        consume(metadata,peak)
        if(closed || finished || stop.load() || released || !running.load() || terminal.load() || !executionPending.load()){
            throw IllegalStateException("same Session changed during its short metadata borrower")}
    }

    // The finished physical Session retains exactly its paid private output
    // until consumption ACK. This separate Unit borrower takes the original
    // mutex and cannot be entered from run(), nor after owner close/transfer.
    func withLivePolicyFinishedMetadata(retained:AgentValue,consume:(LogicalJsonOwnerReservation,Int64)->Unit):Unit{
        if(running.load() && !terminal.load()){throw IllegalStateException("running Session must use its existing callback scope")}
        lock.lock();try{
            if(closed || !started || !finished || stop.load() || released || !terminal.load() || !executionPending.load() ||
                !outputPending.load() || resultReservation.isNone() || workerCleanup.isSome() || input.isSome() ||
                latestJournalInput.isSome() || !writers.isEmpty()){
                throw IllegalStateException("actual finished Session output or physical ACK is unavailable")}
            let bytes=logicalJsonWriteReservationBytes(retained,65536);let nodes=logicalJsonValueNodeCount(retained)
            if(bytes>65536 || nodes>65536){throw IllegalArgumentException("only bounded actual live metadata can borrow the original owner")}
            let peak=1048576+bytes*8+nodes*512;metadata.ensureRetainedPeak(peak)
            consume(metadata,peak)
        }finally{lock.unlock()}
    }

    // A small Host-private copy moves into this SAME Session's metadata
    // owner. The original private output allocation remains owned until the
    // custody has dropped its original output reference and calls its ACK.
    // This operation conveys data only, not Source, claim or execution rights.
    func captureFinishedLivePolicyMetadata(value:AgentValue,consume:(AgentValue)->Result<Unit>):Result<Unit>{
        let result=HostLivePolicyTerminalUnit250()
        try{
            withLivePolicyFinishedMetadata(value,{owner,peak=>
                if(livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isSome()){
                    throw IllegalStateException("same Session already retains captured live metadata")}
                let bytes=logicalJsonWriteReservationBytes(value,16384)
                let nodes=logicalJsonValueNodeCount(value)
                if(bytes>16384){throw IllegalArgumentException("only the original bounded policy metadata can be captured")}
                // The enclosing actual metadata owner pays both original
                // String and byte/DOM copies before encode or parse.
                owner.ensureRetainedPeak(peak+1048576+bytes*8+nodes*512)
                let encoded=encodeAgentValue(value)
                if(encoded.size>bytes || encoded.size>16384){throw IllegalStateException("captured metadata exceeded its prepaid original writer bound")}
                let copy=parseUnifiedJson(encoded,maxBytes:16384,maxDepth:32)
                livePolicyRetainedMetadata=Some(copy)
                var adopted=false
                try{
                    result.value=consume(copy)
                    if(result.value.isOk()){livePolicyMetadataPending.store(true);adopted=true}
                }finally{if(!adopted){livePolicyRetainedMetadata=None<AgentValue>}}
            })
            result.value
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_metadata_capture_failed","same paid Session did not capture complete bounded metadata")}
    }
    func livePolicyCapturedMetadataRetained():Bool{
        lock.lock();try{
            started && finished && terminal.load() && !closed && !stop.load() && !released &&
                executionPending.load() && livePolicyMetadataPending.load() && livePolicyRetainedMetadata.isSome() &&
                !outputPending.load() && resultReservation.isNone() && workerCleanup.isNone() &&
                input.isNone() && latestJournalInput.isNone() && writers.isEmpty()
        }finally{lock.unlock()}
    }
    // Only a short trusted data consumer runs under this Session lock. No
    // worker, SQL, preparation, execution or publication belongs in this
    // callback. The actual custody retains the allocation outside this loan.
    // The real child output allocation remains owned by the driver until this
    // entire actual Receipt/Source verification succeeds. A null result selects
    // only the distinct full User-no-effect path; it never fabricates a lease.
    // The callback copies bounded data into this SAME captured Session owner.
    func captureKnownLivePolicyChildLedger(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,previous:AgentValue,result:?ToolResult,guard:()->Result<Unit>,
        consume:(AgentValue)->Unit):Result<Unit>{
        let answer=HostLivePolicyTerminalUnit250()
        let pending=HostLiveKnownLedger291()
        let proof=withCapturedLivePolicyMetadataOwner(previous,{owner,peak=>
            let through=hostLivePolicyRPCInteger(previous,"through_sequence")
            if(through==Int64.Max || !pluginLivePolicyLedgerReferenceValid(previous,parent.operationId.value,through) ||
                hostLivePolicyRPCInteger(child.operationPlan.canonicalArguments,"sequence")!=through+1 ||
                canonicalAgentValue(child.operationPlan.canonicalArguments.field("prior_receipts").getOrThrow())!=canonicalAgentValue(previous)){
                throw HostArtifactOperationFailure(AgentError(AgentErrorKind.RecoveryRequired,
                    "plugin.live_known_child_sequence_changed","actual child and original complete preceding prefix changed"))}
            let capture:(AgentValue)->Unit={tip=>
                if(pending.value.isSome()){throw IllegalStateException("actual whole child Receipt tip was replayed")}
                // Before allocation, pay the original tip, independent writer
                // String/DOM and fixed additional ledger fields concurrently.
                let bytes=logicalJsonWriteReservationBytes(tip,16384)
                let nodes=logicalJsonValueNodeCount(tip)
                if(bytes>16384 || nodes>65536){throw IllegalStateException("actual receipt tip exceeded its original strict metadata bound")}
                owner.ensureRetainedPeak(peak+1048576+bytes*8+(nodes+12)*512+parent.operationId.value.size*8)
                let value=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                    ValueField("parent_operation_id",textValue(parent.operationId.value)),
                    ValueField("through_sequence",integerValue(through+1)),ValueField("tip",tip)])
                if(!pluginLivePolicyLedgerReferenceValid(value,parent.operationId.value,through+1) ||
                    httpIntentText(tip,"operation_id")!=child.operationId.value){
                    throw IllegalStateException("actual reserved receipt differs from its independently prepared child")}
                let upper=logicalJsonWriteReservationBytes(value,16384)
                let count=logicalJsonValueNodeCount(value)
                owner.ensureRetainedPeak(peak+1048576+upper*8+count*512)
                let encoded=encodeAgentValue(value)
                if(encoded.size>upper || encoded.size>16384){throw IllegalStateException("actual ledger exceeded its paid original JSON writer bound")}
                let copy=parseUnifiedJson(encoded,maxBytes:16384,maxDepth:32)
                // This Node is data held by this real Session after Unit use.
                // Only the outer successful result may advance the driver.
                pending.value=Some(copy)
            }
            answer.value=match(result){
                case Some(actual)=>artifacts.withLivePolicySettledChildTip(context,parent,child,actual,guard,capture)
                case None=>artifacts.withLivePolicyRejectedChildTip(context,parent,child,guard,capture)}
            match(answer.value){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
        })
        try{
            match(proof){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            let value=match(pending.value){case Some(actual)=>actual
                case None=>return hostPluginResourceError("plugin.live_known_child_tip_missing","actual complete Root Receipt proof returned no tip")}
            // Publish the independently paid data clone only AFTER the real
            // Root before/after checks and same-Session after-check succeeded.
            consume(value);Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_known_child_capture_failed","actual known child ledger consumer failed")}
        finally{pending.value=None<AgentValue>}
    }

    // Unused publication-input backing seam. This derives from the SAME
    // actual captured metadata ancestor, not final resultReservation and not
    // a new owner pool. Tools must invoice ALL actual Prepared aliases on the
    // returned child before constructing/publishing its mutable typed holder.
    // The lease conveys allocation only, no Source, receipt or approval.
    func retainLivePolicyPendingPreparedBacking315(additionalPeak:Int64):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(additionalPeak<8192 || !started || !finished || !terminal.load() || closed || stop.load() || released ||
                !executionPending.load() || !livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isNone() ||
                outputPending.load() || resultReservation.isSome() || workerCleanup.isSome() ||
                input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_pending_backing_unavailable",
                    "actual unconsumed captured Session metadata must retain pending input backing")}
            let child=try{metadata.deriveRetainedLease()}
                catch(_:Exception){return hostPluginResourceError("plugin.live_pending_backing_unpaid",
                    "same original metadata bank could not retain pending publication input")}
            try{child.ensureRetainedPeak(additionalPeak);Result<LogicalJsonOwnerReservation>.Ok(child)}
            catch(_:Exception){child.close();hostPluginResourceError("plugin.live_pending_backing_unpaid",
                "pending input wrapper cells exceed the same actual shared bank")}
        }finally{lock.unlock()}
    }

    func withCapturedLivePolicyMetadata(consume:(AgentValue)->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(!started || !finished || !terminal.load() || closed || stop.load() || released ||
                !executionPending.load() || !livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isNone() ||
                outputPending.load() || resultReservation.isSome() || workerCleanup.isSome() ||
                input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_metadata_owner_changed","same actual captured metadata owner is unavailable")}
            let answer=consume(livePolicyRetainedMetadata.getOrThrow())
            if(closed || stop.load() || released || !executionPending.load() || !livePolicyMetadataPending.load()){
                return hostPluginResourceError("plugin.live_metadata_owner_changed","same actual owner changed during its data loan")}
            answer
        }finally{lock.unlock()}
    }
    // One short trusted metadata/Store phase. The real captured Session
    // retains its original small Node and allocation before, during and
    // after the callback. Borrowing it neither closes nor grants a Source.
    // No registry/Host lock, worker, await or effect may be entered here.
    func withCapturedLivePolicyMetadataOwner(retained:AgentValue,
        consume:(LogicalJsonOwnerReservation,Int64)->Unit):Result<Unit>{
        lock.lock();try{
            if(!started || !finished || !terminal.load() || closed || stop.load() || released ||
                !executionPending.load() || !livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isNone() ||
                outputPending.load() || resultReservation.isSome() || workerCleanup.isSome() ||
                input.isSome() || latestJournalInput.isSome() || !writers.isEmpty()){
                return hostPluginResourceError("plugin.live_metadata_owner_changed","same actual captured metadata owner is unavailable")}
            let original=livePolicyRetainedMetadata.getOrThrow()
            let bytes=logicalJsonWriteReservationBytes(original,16384)
            let nodes=logicalJsonValueNodeCount(original)
            let extraBytes=logicalJsonWriteReservationBytes(retained,16384)
            let extraNodes=logicalJsonValueNodeCount(retained)
            if(bytes>16384 || extraBytes>16384 || nodes>65536 || extraNodes>65536){
                return hostPluginResourceError("plugin.live_metadata_bound","only actual original bounded metadata may share this retained owner")}
            let peak=2097152+(bytes+extraBytes)*8+(nodes+extraNodes)*512
            metadata.ensureRetainedPeak(peak)
            consume(metadata,peak)
            if(closed || stop.load() || released || !executionPending.load() ||
                !livePolicyMetadataPending.load() || livePolicyRetainedMetadata.isNone()){
                return hostPluginResourceError("plugin.live_metadata_owner_changed","same actual captured metadata changed during its paid Unit phase")}
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_metadata_phase_failed","same actual captured metadata phase failed")}
        finally{lock.unlock()}
    }

    func acknowledgeCapturedLivePolicyMetadata():Unit{
        lock.lock();try{
            // The actual custody has already dropped every borrowed reference
            // before this ACK. Cancellation/collector close cannot do it.
            livePolicyRetainedMetadata=None<AgentValue>;livePolicyMetadataPending.store(false)
            let _=cleanup(allowExecutionPending:true)
        }finally{lock.unlock()}
    }

    public func retainReplacement(link:ContextReadFactLink,intent:AgentValue,writer:HostServiceArtifactWriter,current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){return hostPluginResourceError("plugin.document_query_closed","document output retention window is closed")}
        artifacts.retainDocumentPayloadReplacement(link,intent,writer,current)
    }
    public func retainResult(link:ContextReadFactLink,parent:AgentValue,writer:HostServiceArtifactWriter,current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){return hostPluginResourceError("plugin.document_query_closed","document result retention window is closed")}
        artifacts.retainDocumentPureResult(link,parent,writer,current)
    }
    public func retainWindowReplacement(links:Array<ContextReadFactLink>,intent:AgentValue,
        writer:HostServiceArtifactWriter,current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","window output retention is closed")}
        artifacts.retainDocumentWindowPayload(links,intent,writer,current)
    }
    public func retainWindowResult(links:Array<ContextReadFactLink>,parent:AgentValue,
        writer:HostServiceArtifactWriter,current:()->Result<Unit>):Result<Unit>{
        if(closed || !started || finished || stop.load()){
            return hostPluginResourceError("plugin.document_query_closed","window result retention is closed")}
        artifacts.retainDocumentWindowResult(links,parent,writer,current)
    }
}

private class HostLivePolicyHistoryPhase288 {var peak:Int64;init(peak:Int64){this.peak=peak}}

// Resource identity only: value/interface implementations cannot own another
// Session input. No Source, payment, permission, retirement or close authority.
private func hostSameInitialPreparedCustody335(left:OwnedKernelPreparedReferenceCustody,right:OwnedKernelPreparedReferenceCustody):Bool{
    match(left as Object){case Some(leftObject)=>match(right as Object){
        case Some(rightObject)=>refEq(leftObject,rightObject)
        case None=>false}
        case None=>false}
}
