package agent_host_runtime

import std.convert.*

import agent_domain.*
import agent_domain as leaseDomain189
import agent_runtime.*
import agent_store.*
import process4cj.*
import process4cj as process
import std.env.*
import tool_runtime.*
import std.sync.*
import agent_domain.LogicalJsonOwnerReservation as HubProcessPhaseOwner180
import yjson.*
import yjson_support.*

// Created only by the actual executing hidden-child admission. This is an
// explicit Derived service lease; it is not a Model grant, Managed job, IPC
// token or deserializable Source. The unchanged Native bank pays the retained
// Source/plan/control graph and every actual process producer independently.
public class HostHubDerivedProcessLease180 {
    private let lock=Mutex()
    private let port:?HubDerivedProcessServicePort180
    private let source:?OperationRootSource
    private let rootPort180:?HubDerivedProcessRootPort180
    private let rootTicket180:?HubProcessRootHandoff180
    private let hostConfiguration180:?HostPrimitiveConfiguration111
    private let parent:OperationId
    private let child:OperationId
    private let run:RunId
    private let thread:ThreadId
    private let epoch:Int64
    private let plan:NormalizedOperationPlan
    private let current:()->Result<Unit>
    private let effect:()->Result<ToolExecutionHandoffLease>
    private let meter:HostPaidValueProjection151
    private let producers:HostHubProcessProducerCustody
    private var revoked=false
    private let revocationEffectLock180=Mutex()
    private var generationRegistration180:?process.CancellationRegistration=None<process.CancellationRegistration>
    private var parentRegistration180:?leaseDomain189.CancellationRegistration=None<leaseDomain189.CancellationRegistration>
    private var revocationProducer180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    private var revocationStarted180=false
    private var revocationCarrier180:?HostHubProcessRevocationCarrier180=None<HostHubProcessRevocationCarrier180>
    private var revocationDisposing180=false
    private var revocationRegistrationsReturned180=false
    private var rootRestrictionCell180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    private var rootRestrictionAction180:?()->Result<Unit>=None<()->Result<Unit>>
    private var rootRestrictionStarted180=false
    private var revocationStoreFailure180:?Exception=None<Exception>
    private var originCurrentBridge180:?HostHubProcessCurrentBridge180=None<HostHubProcessCurrentBridge180>
    private var originWindowPending180:?ToolExecutionHandoffLease=None<ToolExecutionHandoffLease>
    private let remoteCurrentLock180=Mutex()
    private var remoteCurrentPending180:?HubProcessPhaseOwner180=None<HubProcessPhaseOwner180>
    private var remoteCurrentFrame180:?HostHubProcessRemoteCurrent180=None<HostHubProcessRemoteCurrent180>
    private let decodeRootFailure180:(AgentValue)->Result<AgentError>
    private var wirePhase180:?HubProcessPhaseOwner180=None<HubProcessPhaseOwner180>
    private var physicalGeneration:Int64=0
    private var physicalPid:Int64=0
    private var physicalStartIdentity:String=""
    private var launchPending=false
    private var pendingNativeReceipt180:?ProcessNativeFailedStartReceipt180=None<ProcessNativeFailedStartReceipt180>
    private var explicitRestart=false
    private var actualRecordId=""
    private var retiredPid:Int64=0
    private var retiredStartIdentity=""
    private var recoveredRestartSpec180:?AgentValue=None<AgentValue>
    private var rootDispositionKnown180=false
    private var rootRetainedIncarnation180=false

    init(port:HubDerivedProcessServicePort180,source:OperationRootSource,parent:OperationId,
        child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,
        current:()->Result<Unit>,effect:()->Result<ToolExecutionHandoffLease>,meter:HostPaidValueProjection151,configuration:HostPrimitiveConfiguration111){
        this.port=Some(port);this.source=Some(source);this.rootPort180=None<HubDerivedProcessRootPort180>
        this.rootTicket180=None<HubProcessRootHandoff180>;this.hostConfiguration180=Some(configuration)
        this.parent=parent;this.child=child;this.run=run
        this.thread=thread;this.epoch=epoch;this.plan=plan;this.current=current;this.effect=effect;this.meter=meter
        this.producers=HostHubProcessProducerCustody.prepare(meter)
        this.decodeRootFailure180={_=>processLeaseDenied180<AgentError>("hub.process_origin_not_root")}
    }
    public prop operationId:OperationId {get(){child}}
    public prop namespace:String {get(){httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(),"namespace")}}
    public prop rootThread:ThreadId {get(){thread}}
    public func check():Result<Unit>{
        lock.lock();try{if(revoked){return processLeaseDenied180("hub.process_service_revoked")}}finally{lock.unlock()}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(rootTicket180){case Some(ticket)=>
            match(probeActualHostCurrent180(ticket)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            rootPort180.getOrThrow().verifyHubProcessRootHandoff180(ticket)
            case None=>port.getOrThrow().verifyHubProcessService180(source.getOrThrow(),parent,child,run,thread,epoch,plan)}
    }
    public func acquirePhysicalEffect180():Result<ToolExecutionHandoffLease>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let actual=match(effect()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(check()){case Result.Err(error)=>actual.close();return Result.Err(error);case Result.Ok(_)=>()}
        Result<ToolExecutionHandoffLease>.Ok(actual)
    }
    // Issued by the original Host lease while its real Source/configuration
    // and registry effect window remain current. The returned ticket is DATA;
    // it is useful only after the actual Store has durably issued its nonce.
    public func issueActualRootHandoff180(pid:Int64,startIdentity:String,nonce:String):Result<HubProcessRootHandoff180>{
        if(rootTicket180.isSome()){return processLeaseDenied180("hub.process_root_cannot_reissue")}
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let rootPort=match(port.getOrThrow() as HubDerivedProcessRootPort180){case Some(value)=>value
            case None=>return processLeaseDenied180("hub.process_root_store_unavailable")}
        meter.fundAdditional151(65536,32)
        let configuration=hostConfiguration180.getOrThrow().rootProcessConfiguration180(meter)
        let phase=meter.deriveDataPhase151(65536)
        try{
            let invoice=HubProcessPlanInvoice180({bytes=>phase.ensureRetainedPeak(bytes)});invoice.includePlan(plan)
            phase.ensureRetainedPeak(invoice.retainedPeak())
            meter.fundAdditional151(65536+nonce.size+startIdentity.size,32)
            let actual=source.getOrThrow()
            let ticket=HubProcessRootHandoff180(nonce,parent,child,run,thread,epoch,
                actual.itemId(),actual.callId(),actual.toolName(),pid,startIdentity,plan,configuration,
                requireActualCurrentEndpoint180(nonce,pid,startIdentity))
            let window=match(effect()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try{
                match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(rootPort.issueHubProcessRootHandoff180(actual,ticket)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result<HubProcessRootHandoff180>.Ok(ticket)
            }finally{window.close()}
        }finally{phase.close()}
    }
    // Only the concrete existing canonical Store is admitted here. Its nonce
    // was issued by the original live Source, not restored from a history row.
    // The factory also checks THIS process's real PID/start token and original
    // fixed-file operator selection before the one-time same-TX claim.
    public static func claimActualRootHandoff180(store:DurableOperationStore,
        ticket:HubProcessRootHandoff180,meter:HostPaidValueProjection151,
        decodeFailure:(AgentValue)->Result<AgentError>):Result<HostHubDerivedProcessLease180>{
        meter.fundAdditional151(65536,64)
        let pid=getProcessId();let started=processStartTime(pid)
        if(pid!=ticket.brokerPid || started<=0 || started.toString()!=ticket.brokerStartIdentity){
            return processLeaseDenied180("hub.process_root_incarnation_changed")}
        match(hostValidateProcessRootConfiguration180(ticket.configuration,ticket.plan)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(store.claimHubProcessRootHandoff180(ticket)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result<HostHubDerivedProcessLease180>.Ok(HostHubDerivedProcessLease180(store,ticket,meter,decodeFailure))
    }
    private init(store:DurableOperationStore,ticket:HubProcessRootHandoff180,meter:HostPaidValueProjection151,
        decodeFailure:(AgentValue)->Result<AgentError>){
        this.decodeRootFailure180=decodeFailure
        this.port=None<HubDerivedProcessServicePort180>;this.source=None<OperationRootSource>
        this.rootPort180=Some(store);this.rootTicket180=Some(ticket);this.hostConfiguration180=None<HostPrimitiveConfiguration111>
        this.parent=ticket.parent;this.child=ticket.child;this.run=ticket.run
        this.thread=ticket.thread;this.epoch=ticket.epoch;this.plan=ticket.plan;this.meter=meter
        this.current={=>
            let pid=getProcessId();let started=processStartTime(pid)
            if(pid!=ticket.brokerPid || started<=0 || started.toString()!=ticket.brokerStartIdentity){
                return processLeaseDenied180("hub.process_root_incarnation_changed")}
            hostValidateProcessRootConfiguration180(ticket.configuration,ticket.plan)}
        this.effect={=>processLeaseDenied180<ToolExecutionHandoffLease>("hub.process_root_requires_atomic_effect")}
        this.producers=HostHubProcessProducerCustody.prepare(meter)
    }
    public func withPhysicalEffect180(action:()->Result<Unit>):Result<Unit>{
        // Revocation and a short actual physical effect serialize on this
        // real owner. No wait/readiness/stream occurs inside this gate.
        revocationEffectLock180.lock()
        try{return withPhysicalEffectHelper180(action)}finally{revocationEffectLock180.unlock()}
    }
    private func withPhysicalEffectHelper180(action:()->Result<Unit>):Result<Unit>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(rootTicket180){
            case Some(ticket)=>withActualHostCurrentWindow180(ticket,{=>
                rootPort180.getOrThrow().withHubProcessRootEffect180(ticket,{=>
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    action()})})
            case None=>
                let window=match(acquirePhysicalEffect180()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                try{action()}finally{window.close()}}
    }
    public func prepareActualHostCurrentBridge180(path:String,nonce:String,pid:Int64,start:String):Unit{
        if(rootTicket180.isSome()){throw IllegalStateException("a Root cannot mint the originating Host bridge")}
        meter.fundAdditional151(131072+path.size*8+nonce.size*8+start.size*8,64)
        let producer=producers.reserveProducerBeforeClosure(generation:0)
        producer.fundProducerFrameBeforeEffect180(131072)
        let bridge=HostHubProcessCurrentBridge180(this,path,nonce,pid,start,producer)
        lock.lock();try{
            if(originCurrentBridge180.isSome()){throw IllegalStateException("actual current bridge is already registered")}
            originCurrentBridge180=Some(bridge)
        }finally{lock.unlock()}
        bridge.bindActualServer180()
    }
    public func startActualHostCurrentBridge180():Unit{originCurrentBridge180.getOrThrow().startAfterPrivatePermissions180()}
    private func requireActualCurrentEndpoint180(nonce:String,pid:Int64,start:String):String{
        let actual=originCurrentBridge180.getOrThrow()
        if(!actual.matchesActualBinding180(nonce,pid,start)){
            throw IllegalStateException("actual Host bridge does not match this physical Root")}
        actual.endpoint180()
    }
    // This is the original Host gate and effect acquisition, not a grant
    // reconstructed from Root DATA. Its wrapper unlocks only on real close.
    func acquireOriginCurrentWindow180():Result<ToolExecutionHandoffLease>{
        if(rootTicket180.isSome()){return processLeaseDenied180("hub.process_root_cannot_lend_host")}
        revocationEffectLock180.lock()
        try{
            if(originWindowPending180.isSome()){
                revocationEffectLock180.unlock();return processLeaseDenied180("hub.process_original_window_retained")}
            let actual=match(acquirePhysicalEffect180()){case Result.Err(error)=>
                revocationEffectLock180.unlock();return Result.Err(error);case Result.Ok(value)=>value}
            // The actual acquired window remains registered if a later
            // wrapper allocation fails. It cannot be lost from a local.
            originWindowPending180=Some(actual)
            return Result<ToolExecutionHandoffLease>.Ok(HostHubOriginCurrentWindow180(actual,{returned=>
                // A throwing close retains the exact registered actual window.
                // It releases only this scheduling lock, so revocation is not
                // blocked forever and a new effect still sees pending custody.
                if(returned){originWindowPending180=None<ToolExecutionHandoffLease>}
                revocationEffectLock180.unlock()}))
        }catch(error:Exception){revocationEffectLock180.unlock();throw error}
    }
    private func beginRemoteCurrentFrame180(ticket:HubProcessRootHandoff180):Unit{
        if(remoteCurrentPending180.isSome() || remoteCurrentFrame180.isSome()){
            throw IllegalStateException("an actual current frame is still retained")}
        let paid=meter.deriveDataPhase151(65536);remoteCurrentPending180=Some(paid)
        let frame=HostHubProcessRemoteCurrent180(paid);remoteCurrentFrame180=Some(frame)
        frame.beginWholeHelper180(ticket,decodeRootFailure180)
    }
    private func closeRemoteCurrentFrameHelper180():Unit{
        remoteCurrentFrame180.getOrThrow().closeWholeHelper180(decodeRootFailure180)
    }
    private func retireRemoteCurrentFrameAfterHelper180():Unit{
        if(!remoteCurrentFrame180.getOrThrow().retireAfterWholeHelper180()){
            throw IllegalStateException("actual current window has not returned")}
        remoteCurrentFrame180=None<HostHubProcessRemoteCurrent180>;remoteCurrentPending180=None<HubProcessPhaseOwner180>
    }
    private func withActualHostCurrentWindow180(ticket:HubProcessRootHandoff180,action:()->Result<Unit>):Result<Unit>{
        remoteCurrentLock180.lock()
        try{
            beginRemoteCurrentFrame180(ticket)
            try{return action()}
            finally{
                // The throwing effect has already unwound here. A successful
                // whole close helper still retires its independent control
                // DATA; a throwing close keeps the exact frame/payment live.
                closeRemoteCurrentFrameHelper180()
                retireRemoteCurrentFrameAfterHelper180()
            }
        }finally{remoteCurrentLock180.unlock()}
    }
    private func probeActualHostCurrent180(ticket:HubProcessRootHandoff180):Result<Unit>{
        withActualHostCurrentWindow180(ticket,{=>Result<Unit>.Ok(())})
    }
    // Used solely by the private Root entry AFTER its actual handler Future
    // helper and complete error-output loans returned. No public Bool/cancel
    // status can clear a live physical producer or original Host window.
    public func retireReturnedRootRequestControl180():Bool{
        if(rootTicket180.isNone() || !producers.hasNoReservedOrRegisteredProducers180()){return false}
        remoteCurrentLock180.lock()
        try{
            match(remoteCurrentFrame180){case Some(frame)=>
                if(!frame.retireAfterWholeFailedRequest180()){return false}
                remoteCurrentFrame180=None<HostHubProcessRemoteCurrent180>
                remoteCurrentPending180=None<HubProcessPhaseOwner180>
                case None=>if(remoteCurrentPending180.isSome()){return false}}
            wirePhase180.isNone()
        }finally{remoteCurrentLock180.unlock()}
    }
    public func completeNonPersistentCurrentBridge180():Bool{
        let request=plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("request").getOrThrow()
        if(httpIntentText(request,"op")=="start"){return false}
        lock.lock();let retained=try{
            rootRetainedIncarnation180 || (httpIntentText(request,"op")=="restart" && !rootDispositionKnown180)
        }finally{lock.unlock()}
        // An unknown restart transport may already have launched. It cannot
        // close its real origin bridge from the absence of a success response.
        if(retained){return false}
        let actual=originCurrentBridge180.getOrThrow()
        actual.closeActualServerHelper180()
        if(!actual.observeActualProducerReturn180()){return false}
        actual.clearAfterActualProducerReturn180()
    }
    public func noteActualRootDisposition180(retained:Bool):Unit{
        lock.lock();try{
            if(rootTicket180.isSome()){throw IllegalStateException("Root disposition belongs to the original origin")}
            if(rootDispositionKnown180 && retained!=rootRetainedIncarnation180){throw IllegalStateException("actual Root disposition changed")}
            rootDispositionKnown180=true;rootRetainedIncarnation180=retained
        }finally{lock.unlock()}
    }
    public func authorizeRecoveredRestart180(target:AgentValue):Result<Unit>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(rootTicket180.isNone()){return processLeaseDenied180("hub.process_recovery_requires_actual_root")}
        let request=plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("request").getOrThrow()
        fundBorrowedDataBeforeCopy180(target)
        if(httpIntentText(request,"op")!="restart" || canonicalAgentValue(request.field("actual_target").getOrThrow())!=canonicalAgentValue(target)){
            return processLeaseDenied180("hub.process_restart_not_admitted")}
        let spec=target.field("spec").getOrThrow()
        let generation=Int64.parse(target.field("generation").getOrThrow().asNumberText())
        if(spec.unifiedKind!=ValueKind.Object || generation<0 || generation==Int64.Max || httpIntentText(target,"id")==""){
            return processLeaseDenied180("hub.process_incarnation_changed")}
        lock.lock();try{
            if(revoked || launchPending || physicalPid!=0 || physicalGeneration!=0 || recoveredRestartSpec180.isSome()){
                return processLeaseDenied180("hub.process_incarnation_not_retired")}
            meter.fundAdditional151(65536+httpIntentText(target,"id").size*2,32)
            // This reference is the exact request's already-paid frozen spec,
            // not an authority recovered from a database row.
            recoveredRestartSpec180=Some(spec);actualRecordId=httpIntentText(target,"id")
            physicalGeneration=generation;explicitRestart=true;Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    public func authorizeExplicitRestart180(command:HostHubDerivedProcessLease180,target:AgentValue):Result<Unit>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(command.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Both values are actual admission-created private leases. A caller's
        // Bool, serialized Source, history row or target alone grants nothing.
        let request=command.plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("request").getOrThrow()
        if(httpIntentText(request,"op")!="restart" || command.thread.value!=thread.value ||
            command.namespace!=namespace || canonicalAgentValue(request.field("actual_target").getOrThrow())!=canonicalAgentValue(target)){
            return processLeaseDenied180("hub.process_restart_not_admitted")}
        lock.lock()
        try{if(launchPending || physicalPid!=0 || explicitRestart || httpIntentText(target,"id")!=actualRecordId ||
                target.field("generation").getOrThrow().asNumberText()!=physicalGeneration.toString() ||
                target.field("pid").getOrThrow().asNumberText()!=retiredPid.toString() ||
                httpIntentText(target,"start_identity")!=retiredStartIdentity){
                return processLeaseDenied180("hub.process_incarnation_changed")}
            explicitRestart=true;Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    // Claims an actual short physical-launch/effect window. The returned
    // Registry lease must leave the stack BEFORE any wait/readiness/stream.
    public func beginPhysicalLaunch180():Result<Int64>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        try{
            if(revoked || launchPending || physicalPid!=0 || physicalGeneration==Int64.Max){
                return processLeaseDenied180("hub.process_incarnation_not_retired")}
            // Previous successful generations are not new canonical children.
            // They remain bound to this same original admitted restart policy.
            let intent=plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow()
            let request=intent.field("request").getOrThrow()
            let recovered=recoveredRestartSpec180.isSome()
            let spec=if(recovered){recoveredRestartSpec180.getOrThrow()}else{request.field("spec").getOrThrow()}
            if((httpIntentText(request,"op")!="start" && !(httpIntentText(request,"op")=="restart" && recovered)) ||
                (physicalGeneration!=0 && httpIntentText(spec,"restart")=="no" && !explicitRestart)){
                return processLeaseDenied180("hub.process_restart_not_admitted")}
            meter.fundAdditional151(65536,16)
            physicalGeneration+=1;launchPending=true;explicitRestart=false
            Result.Ok(physicalGeneration)
        }finally{lock.unlock()}
    }
    // The caller supplies only its actual opened ManagedProcess PID and the
    // actual /proc start identity. Unknown launch never clears launchPending.
    public func installActualNativeReceiptBeforeEffect180(receipt:ProcessNativeFailedStartReceipt180):Unit{
        lock.lock();try{
            if(!launchPending || physicalPid!=0 || pendingNativeReceipt180.isSome()){
                throw IllegalStateException("actual native launch receipt cannot replace an existing incarnation")}
            pendingNativeReceipt180=Some(receipt)
        }finally{lock.unlock()}
    }
    public func noteActualFailedNativeReturn180(generation:Int64,receipt:ProcessNativeFailedStartReceipt180):Bool{
        // The complete launching caller has returned before Product supplies
        // this same preinstalled opaque witness. No historical PID/receipt is
        // admitted and this transition releases no DATA or error payment.
        if(!receipt.resourcesReturned180()){return false}
        lock.lock();try{
            if(!launchPending || generation!=physicalGeneration || physicalPid!=0 ||
                pendingNativeReceipt180.isNone() || !refEq(pendingNativeReceipt180.getOrThrow(),receipt)){return false}
            launchPending=false;true
        }finally{lock.unlock()}
    }
    public func noteActualPhysicalLaunch180(recordId:String,generation:Int64,pid:Int64,startIdentity:String):Result<Unit>{
        lock.lock()
        try{
            if(!launchPending || generation!=physicalGeneration || pid<=0 || startIdentity==""){
                return processLeaseDenied180("hub.process_incarnation_changed")}
            if(startIdentity.size>Int64.Max/2 || recordId.size>Int64.Max/2-startIdentity.size){
                throw LogicalJsonPayloadError("actual process identity invoice overflow")}
            meter.fundAdditional151((startIdentity.size+recordId.size)*2,4)
            if(actualRecordId!="" && recordId!=actualRecordId){return processLeaseDenied180("hub.process_incarnation_changed")}
            actualRecordId=recordId
            physicalPid=pid;physicalStartIdentity=startIdentity;launchPending=false
            Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    public func checkActualIncarnation180(generation:Int64,pid:Int64,startIdentity:String):Result<Unit>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        try{if(launchPending || generation!=physicalGeneration || pid!=physicalPid ||
                startIdentity=="" || startIdentity!=physicalStartIdentity){
                return processLeaseDenied180("hub.process_incarnation_changed")}
            Result<Unit>.Ok(())}finally{lock.unlock()}
    }
    // A true joined producer registry is required by the physical owner before
    // calling this method; a stop request or a process.status counter is not
    // evidence that stdout/stderr/readiness/monitor aliases have returned.
    public func noteJoinedIncarnation180(generation:Int64,pid:Int64,startIdentity:String):Bool{
        // Every actual producer cell must independently observe its Future;
        // an arbitrary caller Bool, count or process.wait is not sufficient.
        for(index in 0..producers.countRegistered()){
            let cell=producers.at(index)
            if(!cell.belongsToGeneration180(generation)){continue}
            if(!cell.collectReturned()){return false}
            if(!cell.retireObservedReturn()){return false}}
        lock.lock()
        try{
            // A later DATA-copy cleanup may remain Held after the genuine
            // producer join. Reobserving this same retired incarnation grants
            // no new effect and never reuses a changed generation/identity.
            if(!launchPending && generation==physicalGeneration && physicalPid==0 && retiredPid==pid &&
                retiredStartIdentity==startIdentity){return true}
            if(launchPending || generation!=physicalGeneration || pid!=physicalPid ||
                startIdentity!=physicalStartIdentity){return false}
            retiredPid=physicalPid;retiredStartIdentity=physicalStartIdentity
            physicalPid=0;physicalStartIdentity="";pendingNativeReceipt180=None<ProcessNativeFailedStartReceipt180>;true}finally{lock.unlock()}
    }
    // Registered only by the actual hidden-child admission. The callbacks
    // borrow the real generation and parent token; neither DATA configuration
    // nor a returned cancellation-registration object is a current witness.
    func registerActualRevocation180(host:HostJavaScriptPluginHost,generation:UInt64,
        cancellation:leaseDomain189.CancellationToken):Result<Unit>{
        meter.fundAdditional151(8192,16)
        let cell=producers.reserveProducerBeforeClosure(generation:0)
        lock.lock();try{revocationProducer180=Some(cell)}finally{lock.unlock()}
        // Payment and the registered carrier precede both callback closures.
        // The callbacks capture this independently paid carrier, not a hidden
        // unretirable Source/action graph in an unknown scheduler closure.
        let carrier=HostHubProcessRevocationCarrier180(this)
        lock.lock();try{revocationCarrier180=Some(carrier)}finally{lock.unlock()}
        let mounted=match(host.observeServiceRevocationReturning180(namespace,generation,{=>carrier.invokeActualRevocation180()})){
            case Result.Err(error)=>requestActualRevocation180();return Result.Err(error)
            case Result.Ok(value)=>value}
        lock.lock();try{generationRegistration180=Some(mounted)}finally{lock.unlock()}
        let parent=cancellation.onCancelReturning159({_=>carrier.invokeActualRevocation180()})
        lock.lock();try{parentRegistration180=Some(parent)}finally{lock.unlock()}
        check()
    }
    private func disposeActualRevocationRegistrationsHelper180():Bool{
        match(generationRegistration180){case Some(value)=>
            value.dispose();if(!value.callbacksReturned159()){return false};case None=>()}
        match(parentRegistration180){case Some(value)=>
            value.dispose();if(!value.callbacksReturned159()){return false};case None=>()}
        true
    }
    // Nonpersistent operation caller invokes this only after its entire
    // operation producer helper returned and retired. This receipt is solely
    // for actual callback carriers; it never acknowledges Source/IO/error DATA.
    public func collectNonPersistentRevocationReturn180():Bool{
        lock.lock();try{
            let request=plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("request").getOrThrow()
            if(httpIntentText(request,"op")=="start" || launchPending || physicalPid!=0 || originWindowPending180.isSome()){return false}
            if(revocationDisposing180){return false};revocationDisposing180=true
        }finally{lock.unlock()}
        try{
            lock.lock();let registrationsReturned=try{revocationRegistrationsReturned180}finally{lock.unlock()}
            if(!registrationsReturned && !disposeActualRevocationRegistrationsHelper180()){return false}
            // The whole helper (including the registration aliases) returned.
            // The new receipt, not dispose() or a callback count, permits the
            // paid carrier's dynamic Source reference to be removed.
            match(revocationCarrier180){case Some(value)=>value.clearAfterActualCallbacksReturned180();case None=>()}
            lock.lock();try{
                generationRegistration180=None<process.CancellationRegistration>
                parentRegistration180=None<leaseDomain189.CancellationRegistration>
                revocationCarrier180=None<HostHubProcessRevocationCarrier180>
                revocationRegistrationsReturned180=true
            }finally{lock.unlock()}
            match(revocationProducer180){case Some(value)=>
                if(revocationStarted180){if(!value.collectReturned() || !value.retireObservedReturn()){return false}}
                else if(!value.retireNeverStartedAfterWholeCaller180()){return false}
                case None=>()}
            true
        }finally{lock.lock();try{revocationDisposing180=false}finally{lock.unlock()}}
    }
    private func markRevokedBeforeProducer180():Unit{
        revocationEffectLock180.lock()
        try{lock.lock();try{revoked=true}finally{lock.unlock()}}
        finally{revocationEffectLock180.unlock()}
    }
    func requestActualRevocation180():Unit{
        markRevokedBeforeProducer180()
        let cell:HostHubProcessProducerCell
        lock.lock();try{
            if(revocationStarted180){return}
            revocationStarted180=true;cell=revocationProducer180.getOrThrow()
        }finally{lock.unlock()}
        // The original cancellation implementation swallows callback throws.
        // Its full error instead stays in this independently paid cell; the
        // synchronous helper must return before its return state is recorded.
        cell.invokeSynchronousHelper180({=>
            match(revoke()){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
        cell.noteSynchronousHelperReturned180()
        // Callback return/dispose is never DATA ACK or a Source refund.
    }
    // This is only a further restriction of an actual issued ticket. The
    // original lease prepays and registers its destination before the Product
    // closure is constructed; it cannot mint a Source or an execution grant.
    public func prepareRootRestrictionBeforeClosure180():Unit{
        meter.fundAdditional151(8192,16)
        let cell=producers.reserveProducerBeforeClosure(generation:0)
        lock.lock();try{
            if(rootRestrictionCell180.isSome() || revoked){
                throw IllegalStateException("actual Root restriction cannot be installed after revocation")}
            rootRestrictionCell180=Some(cell)
        }finally{lock.unlock()}
    }
    public func installActualRootRestriction180(value:()->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(rootRestrictionCell180.isNone() || rootRestrictionAction180.isSome() || revoked){
                return processLeaseDenied180("hub.process_service_revoked")}
            rootRestrictionAction180=Some(value);Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    public func matchesActualRootNonce180(value:String):Bool{
        lock.lock();try{match(rootTicket180){case Some(ticket)=>ticket.nonce==value;case None=>false}}
        finally{lock.unlock()}
    }
    private func invokeActualRootRestrictionHelper180():Unit{
        let cell:HostHubProcessProducerCell
        let action:()->Result<Unit>
        lock.lock();try{
            if(rootRestrictionAction180.isNone() || rootRestrictionStarted180){return}
            rootRestrictionStarted180=true;cell=rootRestrictionCell180.getOrThrow()
            action=rootRestrictionAction180.getOrThrow()
        }finally{lock.unlock()}
        cell.invokeSynchronousHelper180({=>match(action()){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
        cell.noteSynchronousHelperReturned180()
        // The real transport/codec/socket-close helper returned; its actual
        // exception still requires full consumption, not a callback ACK.
    }
    private func revokeDurableHelper180():Result<Unit>{
        match(rootTicket180){case Some(ticket)=>rootPort180.getOrThrow().revokeHubProcessRootHandoff180(ticket)
            case None=>port.getOrThrow().revokeHubProcessService180(source.getOrThrow(),parent,child,run,thread,epoch,plan)}
    }
    public func revoke():Result<Unit>{
        markRevokedBeforeProducer180()
        let result:Result<Unit>
        try{result=revokeDurableHelper180()}
        catch(error:Exception){
            // Retain the exact SQL producer before the independent Root
            // transport starts. Both failures have distinct prepaid slots.
            lock.lock();try{if(revocationStoreFailure180.isNone()){revocationStoreFailure180=Some(error)}}
            finally{lock.unlock()}
            invokeActualRootRestrictionHelper180();throw error
        }
        invokeActualRootRestrictionHelper180()
        lock.lock();try{match(rootRestrictionCell180){case Some(cell)=>
            if(cell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(cell)};case None=>()}}
        finally{lock.unlock()}
        result
    }
    public func retainData180(bytes:Int64,nodes:Int64):Unit{meter.fundAdditional151(bytes,nodes)}
    // The actual Root ticket may authorize only the complete request frozen
    // in that original canonical child. A valid ticket is not an arbitrary
    // process-service capability for different request arguments.
    public func validateActualRequest180(request:AgentValue):Result<Unit>{
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let phase=meter.deriveDataPhase151(65536)
        try{validateActualRequestHelper180(request,phase)}finally{phase.close()}
    }
    private func validateActualRequestHelper180(request:AgentValue,phase:HubProcessPhaseOwner180):Result<Unit>{
        let expected=plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("request").getOrThrow()
        let invoice=HubProcessPlanInvoice180({bytes=>phase.ensureRetainedPeak(bytes)})
        invoice.includeRequest180(expected);invoice.includeRequest180(request)
        phase.ensureRetainedPeak(invoice.retainedPeak())
        if(canonicalAgentValue(expected)!=canonicalAgentValue(request)){
            return processLeaseDenied180("hub.process_canonical_request_changed")}
        Result<Unit>.Ok(())
    }
    public func reserveRootWireBeforeCodec180(ticket:HubProcessRootHandoff180):Unit{
        lock.lock()
        try{
            if(wirePhase180.isSome()){throw IllegalStateException("process wire producer is already retained")}
            let paid=meter.deriveDataPhase151(65536);wirePhase180=Some(paid)
            let invoice=HubProcessPlanInvoice180({bytes=>paid.ensureRetainedPeak(bytes)})
            invoice.includeRoot(ticket);paid.ensureRetainedPeak(invoice.retainedPeak())
        }finally{lock.unlock()}
    }
    // Only the outer transport adapter calls this after its whole codec,
    // socket and complete response decoder helper has physically returned.
    // The returned ToolResult owns its independent response payment; no wire
    // request, ticket or encoded request String crosses that helper boundary.
    public func retireRootWireAfterTransportHelper180():Unit{
        lock.lock();try{match(wirePhase180){case Some(value)=>value.close();wirePhase180=None<HubProcessPhaseOwner180>;case None=>()}}
        finally{lock.unlock()}
    }

    public func signalActualOpenedProcess180(process:ManagedProcess,signal:String):Unit {
        let cell=producers.reserveProducerBeforeClosure(generation:0)
        cell.invokeSynchronousHelper180({=>process.signalOwnedTree180(signal,{bytes=>cell.fundSynchronousFrame180(bytes)})})
        // The whole native/callback action frame has returned before any
        // exact payment retirement. Original errors remain paid in the cell.
        cell.noteSynchronousHelperReturned180()
        if(!cell.retireObservedReturn()){
            throw HostHubProcessHeldProducerFailure180(cell)}
    }
    public func hasNoProcessProducers180():Bool{producers.hasNoReservedOrRegisteredProducers180()}
    public func fundBorrowedDataBeforeCopy180(value:AgentValue):Unit{
        let shape=meter.measureBorrowedValue151(value)
        if(shape.storageBytes>Int64.Max/2 || shape.nodes>Int64.Max/2){
            throw LogicalJsonPayloadError("actual process data copy invoice overflow")}
        meter.fundAdditional151(shape.storageBytes*2,shape.nodes*2)
    }
    public func temporaryDataPhase180():HubProcessPhaseOwner180{meter.deriveDataPhase151(65536)}
    public func reserveProducerBeforeClosure180():HostHubProcessProducerCell{
        lock.lock();try{producers.reserveProducerBeforeClosure(generation:physicalGeneration)}finally{lock.unlock()}}
    public func reserveControlBeforeClosure180():HostHubProcessProducerCell{producers.reserveProducerBeforeClosure(generation:0)}
    // Stable scalar iteration allocates no unpaid snapshot. Each returned
    // producer needs its own whole Future helper, full error consumer ACK,
    // and a later actual payment close; a count alone never consumes DATA.
    public func registeredProducerCount180():Int64{producers.countRegistered()}
    public func registeredProducerAt180(index:Int64):HostHubProcessProducerCell{producers.at(index)}
    // No public close/refund: an unknown physical launch, scheduler alias or
    // escaping raw resource result remains paid in the actual record. Explicit
    // resource retirement must prove and clear every real alias first.
}
class HostHubOriginCurrentWindow180 <: ToolExecutionHandoffLease{
    private var actual:?ToolExecutionHandoffLease
    private let release:(Bool)->Unit
    init(actual:ToolExecutionHandoffLease,release:(Bool)->Unit){this.actual=Some(actual);this.release=release}
    private func closeActualHelper180():Unit{actual.getOrThrow().close()}
    public func close():Unit{
        if(actual.isNone()){return}
        try{closeActualHelper180()}
        catch(error:Exception){release(false);throw error}
        // Clearing the actual alias follows the complete close helper return.
        actual=None<ToolExecutionHandoffLease>;release(true)
    }
}
func processLeaseDenied180<T>(code:String):Result<T>{
    Result.Err(AgentError(AgentErrorKind.PermissionDenied,code,
        "Hub process lost its original Derived service or physical incarnation"))
}

// An opaque paid producer cell, never a permission or a fabricated error.
public class HostHubProcessHeldProducerFailure180 <: Exception {
    public let producer:HostHubProcessProducerCell
    public init(producer:HostHubProcessProducerCell){
        super("actual process producer failure remains in its original paid cell")
        this.producer=producer
    }
}
