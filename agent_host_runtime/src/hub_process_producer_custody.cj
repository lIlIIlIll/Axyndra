package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_domain.LogicalJsonOwnerReservation as HubProcessPaidOwner
import std.collection.*
import std.sync.*

// Private resource task custody. This class has no Source/Receipt factory,
// process launcher, approval API or serialization. Only a separately verified
// actual physical owner can invoke a task after canonical handoff. The original
// same-bank projection must already pay all captured dynamic DATA and this
// registry before reserving these independently charged task/control shares.
enum HostHubProcessProducerPhase { Reserved | Running | Joined | Retired }

public class HostHubProcessProducerCell {
    private let lock=Mutex()
    private var phase=HostHubProcessProducerPhase.Reserved
    private var payment:?HubProcessPaidOwner
    private var action:?()->Unit=None<()->Unit>
    private var worker:?Future<Unit>=None<Future<Unit>>
    private var joining=false
    private var registered=false
    private var originalFailure180:?Exception=None<Exception>
    private var synchronous180=false
    private var cleanupFailures180:?ArrayList<Exception>=Some(ArrayList<Exception>())
    private var cleanupConsumers180:?ArrayList<?OwnedFailureDataConsumer113>=Some(ArrayList<?OwnedFailureDataConsumer113>())
    private var pendingCleanupFailure180:?Exception=None<Exception>
    private var cleanupRegistrationFailure180:?Exception=None<Exception>
    private var prepaidPhysicalFrame180:Int64=65536
    private var generation:Int64
    private var failureConsumer180:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>
    private var storeFailure180:?HubProcessStoreFailure180=None<HubProcessStoreFailure180>
    private var nestedFailure180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    private var captureFailure180:?Exception=None<Exception>
    private var failureBorrowers180:Int64=0

    init(payment:HubProcessPaidOwner,generation!:Int64=0){this.payment=Some(payment);this.generation=generation}
    public func belongsToGeneration180(value:Int64):Bool{lock.lock();try{generation==value}finally{lock.unlock()}}
    func registerBeforeSpawn():Unit {
        lock.lock()
        try{if(registered){throw IllegalStateException("actual process producer was already registered")};registered=true}
        finally{lock.unlock()}
    }
    // The real caller reserves/registers this cell BEFORE allocating the
    // action closure. Unknown spawn/registration does not restore Reserved.
    public func start(value:()->Unit):Unit {
        lock.lock()
        try{
            if(!registered || !reservedLocked() || worker.isSome() || action.isSome()){
                throw IllegalStateException("actual process producer cannot start twice")}
            action=Some(value);phase=HostHubProcessProducerPhase.Running
            try{worker=Some(spawn{invokeActual()})}
            catch(error:Exception){
                // Preserve the exact exception to the still-paid canonical
                // producer caller. There is no absence/return witness here;
                // keep the original action, cell, current state and payment.
                throw error}
        }finally{lock.unlock()}
    }
    public func isPreparedBeforeSpawn180():Bool {
        lock.lock();try{registered && reservedLocked() && action.isNone() && worker.isNone() && !joining}
        finally{lock.unlock()}
    }
    private func reservedLocked():Bool {match(phase){case HostHubProcessProducerPhase.Reserved=>true;case _=>false}}
    private func runningLocked():Bool {match(phase){case HostHubProcessProducerPhase.Running=>true;case _=>false}}
    private func joinedLocked():Bool {match(phase){case HostHubProcessProducerPhase.Joined=>true;case _=>false}}
    private func retiredLocked():Bool {match(phase){case HostHubProcessProducerPhase.Retired=>true;case _=>false}}
    private func invokeActual():Unit {
        let actual=borrowAction()
        try{actual()}catch(error:Exception){
            // Our own carrier transports an already installed paid error set;
            // it is not a second error that can recursively own this cell.
            match(error as HostHubProcessHeldProducerFailure180){case Some(held)=>
                if(refEq(held.producer,this)){return};case None=>()}
            // The real producer wrapper returns normally only after the full
            // throwing action unwound. Its original error remains in this
            // already registered paid cell, never in a short terminal string.
            lock.lock();try{
                if(originalFailure180.isNone()){originalFailure180=Some(error)}
                else if(!refEq(originalFailure180.getOrThrow(),error)){registerCleanupFailureLocked180(error)}
            }finally{lock.unlock()}}
    }
    public func retainFailureBeforeCleanup180(error:Exception):Unit{retainOriginalFailure180(error)}
    private func registerCleanupFailureLocked180(error:Exception):Unit{
        // A strict native helper throws its first preinstalled error and also
        // offers every fixed error slot. Do not duplicate that same primary.
        match(originalFailure180){case Some(previous)=>if(refEq(previous,error)){return};case None=>()}
        for(previous in cleanupFailures180.getOrThrow()){if(refEq(previous,error)){return}}
        match(pendingCleanupFailure180){case Some(previous)=>
            if(refEq(previous,error)){return}
            // This producer stops on unknown registration. Do not continue to
            // another fallible cleanup stage or replace its reachable input.
            throw HostHubProcessHeldProducerFailure180(this)
            case None=>()}
        pendingCleanupFailure180=Some(error)
        try{
            if(cleanupFailures180.getOrThrow().size>(Int64.Max-65536)/1024){
                throw IllegalStateException("actual secondary journal invoice overflow")}
            payment.getOrThrow().ensureRetainedPeak(65536+(cleanupFailures180.getOrThrow().size+1)*1024)
            // Pair insertion is transactional: input remains in its registered
            // pending slot if either backing-array allocation throws.
            cleanupConsumers180.getOrThrow().add(None<OwnedFailureDataConsumer113>)
            cleanupFailures180.getOrThrow().add(error)
            pendingCleanupFailure180=None<Exception>
        }catch(error:Exception){cleanupRegistrationFailure180=Some(error)}
    }
    public func retainActualCleanupFailure180(error:Exception):Unit{
        lock.lock();try{registerCleanupFailureLocked180(error)}finally{lock.unlock()}
    }
    public func secondaryFailureCount180():Int64{
        lock.lock();try{
            let own=match(cleanupFailures180){case Some(value)=>value.size;case None=>0}
            match(nestedFailure180){case Some(value)=>own+value.secondaryFailureCount180();case None=>own}
        }finally{lock.unlock()}
    }
    public func hasUnregisteredSecondary180():Bool{
        lock.lock();try{pendingCleanupFailure180.isSome() || cleanupRegistrationFailure180.isSome()}finally{lock.unlock()}
    }
    private func prepareSecondaryConsumerLocked180(index:Int64):Unit{
        if(cleanupConsumers180.getOrThrow()[index].isSome() || pendingCleanupFailure180.isSome() || cleanupRegistrationFailure180.isSome()){return}
        let error=cleanupFailures180.getOrThrow()[index]
        try{
            match(error as HostHubProcessHeldProducerFailure180){case Some(held)=>
                if(refEq(held.producer,this)){return}
                if(!held.producer.collectReturned()){return}
                let _=held.producer.admitOriginalFailure180({value=>cleanupConsumers180.getOrThrow()[index]=Some(value);true})
                return;case None=>()}
            match(error as HubProcessStoreFailure180){case Some(held)=>
                let _=held.admitFailure180({value=>cleanupConsumers180.getOrThrow()[index]=Some(value);true})
                return;case None=>()}
            match(error as OwnedCanonicalPaidFailure113){case Some(held)=>
                // The paired destination slot/payment already exists. No
                // fallible insertion can follow takeConsumer and lose input.
                cleanupConsumers180.getOrThrow()[index]=Some(held.takeConsumer());return;case None=>()}
            let full=match(error as OwnedCanonicalDataFailure113){case Some(value)=>value.error
                case None=>AgentError(AgentErrorKind.Transport,"hub.process_cleanup_failed",error.message)}
            let paid=payment.getOrThrow()
            match(captureOwnedFailureData113<Unit>(full,{bytes=>
                let derived=paid.deriveRetainedLease()
                try{derived.ensureRetainedPeak(bytes);derived}catch(error:Exception){derived.close();throw error}})){
                case OwnedFailureDataOutcome113.Failure(value)=>cleanupConsumers180.getOrThrow()[index]=Some(value)
                case _=>()}
         }catch(error:Exception){
            // Retain the actual capture/refusal exception as a separate input;
            // primary ACK cannot erase this real producer outcome. A pending
            // registration prevents another capture attempt from overwriting it.
            if(captureFailure180.isNone()){captureFailure180=Some(error)}
            registerCleanupFailureLocked180(error)
        }
    }
    public func admitSecondaryFailure180(index:Int64,accept:(OwnedFailureDataConsumer113)->Bool):Bool{
        let nested:?HostHubProcessProducerCell
        let ownCount:Int64
        lock.lock();try{
            if(!joinedLocked() || joining || failureBorrowers180!=0 || index<0){return false}
            ownCount=cleanupFailures180.getOrThrow().size
            nested=if(index>=ownCount){nestedFailure180}else{None<HostHubProcessProducerCell>}
            if(index>=ownCount && nested.isNone()){return false}
            if(nested.isSome()){failureBorrowers180+=1}
        }finally{lock.unlock()}
        match(nested){case Some(value)=>
            try{return value.admitSecondaryFailure180(index-ownCount,accept)}
            finally{lock.lock();try{failureBorrowers180-=1}finally{lock.unlock()}}
            case None=>()}
        let actual:OwnedFailureDataConsumer113
        lock.lock();try{
            if(!joinedLocked() || joining || index<0 || index>=cleanupFailures180.getOrThrow().size || failureBorrowers180!=0){return false}
            prepareSecondaryConsumerLocked180(index)
            actual=match(cleanupConsumers180.getOrThrow()[index]){case Some(value)=>value;case None=>return false}
            failureBorrowers180+=1
        }finally{lock.unlock()}
        try{return accept(actual)}finally{lock.lock();try{failureBorrowers180-=1}finally{lock.unlock()}}
    }
    public func requirePrepaidPhysicalFrame180(bytes:Int64):Unit{
        lock.lock();try{
            if(bytes<0 || bytes>prepaidPhysicalFrame180 || payment.isNone()){
                throw IllegalStateException("actual Native frame exceeds its pre-launch payment")}
        }finally{lock.unlock()}
    }
    private func retainOriginalFailure180(error:Exception):Unit {
        lock.lock();try{
            if(originalFailure180.isNone()){originalFailure180=Some(error)}
            else if(!refEq(originalFailure180.getOrThrow(),error)){
                // No second producer enters an occupied synchronous/error cell.
                throw IllegalStateException("original process producer failure remains held")}
        }finally{lock.unlock()}
    }
    private func withOriginalFailure180(consume:(Exception)->Unit):Bool {
        lock.lock();try{match(originalFailure180){case Some(error)=>consume(error);true;case None=>false}}
        finally{lock.unlock()}
    }
    // The actual owner calls this full synchronous helper only after its cell
    // has been registered and funded, before constructing the action closure.
    public func invokeSynchronousHelper180(value:()->Unit):Unit {
        lock.lock();try{
            if(!registered || !reservedLocked() || action.isSome() || worker.isSome()){
                throw IllegalStateException("synchronous producer is already retained")}
            action=Some(value);synchronous180=true;phase=HostHubProcessProducerPhase.Running
        }finally{lock.unlock()}
        invokeActual()
    }
    // Only the outer owner invokes this AFTER the preceding whole helper
    // returned. No callback-return flag or cancellation status is involved.
    public func noteSynchronousHelperReturned180():Unit {
        lock.lock();try{
            if(!synchronous180 || !runningLocked() || worker.isSome()){
                throw IllegalStateException("actual synchronous helper return is unavailable")}
            action=None<()->Unit>;phase=HostHubProcessProducerPhase.Joined
        }finally{lock.unlock()}
    }
    public func fundProducerFrameBeforeEffect180(bytes:Int64):Unit {
        lock.lock();try{
            if(!registered || retiredLocked()){throw IllegalStateException("actual producer payment is unavailable")}
            payment.getOrThrow().ensureRetainedPeak(max(65536,bytes));prepaidPhysicalFrame180=max(65536,bytes)
        }finally{lock.unlock()}
    }
    public func fundSynchronousFrame180(bytes:Int64):Unit {
        lock.lock();try{payment.getOrThrow().ensureRetainedPeak(max(prepaidPhysicalFrame180,max(65536,bytes)))}finally{lock.unlock()}
    }
    // This stable Root-paid carrier may be reused after all actual action,
    // Future and failure consumers retired. Unknown scheduler references then
    // hold only this still-paid fixed carrier; no old dynamic action survives.
    func installBeforeNextClosure180(paid:HubProcessPaidOwner,generation:Int64):Unit {
        lock.lock();try{
            if(!retiredLocked() || payment.isSome() || action.isSome() || worker.isSome() ||
                originalFailure180.isSome() || failureConsumer180.isSome() || storeFailure180.isSome() ||
                captureFailure180.isSome() || (pendingCleanupFailure180.isSome() || cleanupRegistrationFailure180.isSome() || !(cleanupFailures180.isNone() || cleanupFailures180.getOrThrow().isEmpty())) || nestedFailure180.isSome() || failureBorrowers180!=0 || joining){
                throw IllegalStateException("actual producer carrier has not retired")}
            payment=Some(paid);this.generation=generation;synchronous180=false
            cleanupFailures180=Some(ArrayList<Exception>())
            cleanupConsumers180=Some(ArrayList<?OwnedFailureDataConsumer113>())
            phase=HostHubProcessProducerPhase.Reserved
        }finally{lock.unlock()}
    }
    private func captureRegisteredFailure180():Unit {
        if(failureConsumer180.isSome() || originalFailure180.isNone() || pendingCleanupFailure180.isSome() || cleanupRegistrationFailure180.isSome()){return}
        let error=originalFailure180.getOrThrow()
        try{
            match(error as HostHubProcessHeldProducerFailure180){case Some(held)=>
                if(refEq(held.producer,this)){throw IllegalStateException("process failure cannot own itself")}
                nestedFailure180=Some(held.producer)
                if(!held.producer.collectReturned()){return}
                let _=held.producer.admitOriginalFailure180({actual=>failureConsumer180=Some(actual);true})
                return
                case None=>()}
            match(error as HubProcessStoreFailure180){case Some(cell)=>
                storeFailure180=Some(cell)
                let _=cell.admitFailure180({actual=>failureConsumer180=Some(actual);true})
                return
                case None=>()}
            match(error as OwnedCanonicalPaidFailure113){case Some(actual)=>
                // The registered destination and independent cell payment
                // precede this transfer; pressure never erases the source.
                failureConsumer180=Some(actual.takeConsumer());return
                case None=>()}
            let full=match(error as OwnedCanonicalDataFailure113){case Some(actual)=>actual.error
                case None=>AgentError(AgentErrorKind.Transport,"hub.process_producer_failed",error.message)}
            let paid=payment.getOrThrow()
            match(captureOwnedFailureData113<Unit>(full,{bytes=>
                let derived=paid.deriveRetainedLease()
                try{derived.ensureRetainedPeak(bytes);derived}catch(error:Exception){derived.close();throw error}})){
                case OwnedFailureDataOutcome113.Failure(actual)=>failureConsumer180=Some(actual)
                case _=>throw IllegalStateException("actual process producer has no failure consumer")}
         }catch(error:Exception){
            // Retain the actual capture/refusal exception as a separate input;
            // primary ACK cannot erase this real producer outcome. A pending
            // registration prevents another capture attempt from overwriting it.
            if(captureFailure180.isNone()){captureFailure180=Some(error)}
            registerCleanupFailureLocked180(error)
        }
    }
    public func admitOriginalFailure180(accept:(OwnedFailureDataConsumer113)->Bool):Bool {
        let actual:OwnedFailureDataConsumer113
        lock.lock();try{
            if(!joinedLocked() || joining || originalFailure180.isNone() || failureBorrowers180!=0){return false}
            captureRegisteredFailure180()
            actual=match(failureConsumer180){case Some(value)=>value;case None=>return false}
            failureBorrowers180+=1
        }finally{lock.unlock()}
        // Encoding/socket output can allocate through the real Root. The
        // cell retains its exact share while this whole loan helper runs,
        // without holding its lock across Root or SQL/output locks.
        try{return accept(actual)}finally{
            lock.lock();try{failureBorrowers180-=1}finally{lock.unlock()}}
    }
    public func hasOriginalFailure180():Bool {
        lock.lock();try{originalFailure180.isSome()}finally{lock.unlock()}
    }
    public func isFullyRetired180():Bool {
        lock.lock();try{retiredLocked() && payment.isNone() && action.isNone() && worker.isNone() && originalFailure180.isNone() &&
            failureConsumer180.isNone() && storeFailure180.isNone() && captureFailure180.isNone() && (pendingCleanupFailure180.isNone() && cleanupRegistrationFailure180.isNone() && (cleanupFailures180.isNone() || cleanupFailures180.getOrThrow().isEmpty())) && nestedFailure180.isNone() && failureBorrowers180==0}
        finally{lock.unlock()}
    }
    private func borrowAction():()->Unit {
        lock.lock();try{action.getOrThrow()}finally{lock.unlock()}
    }
    // Only this whole helper holds a Future alias. Its Bool returns after
    // actual tryGet has returned; a status flag/cancel request is not enough.
    private func tryObserveActualFutureReturned():Bool {
        let actual=borrowActualFuture()
        match(actual){case Some(value)=>value.tryGet().isSome();case None=>false}
    }
    private func borrowActualFuture():?Future<Unit> {
        lock.lock();try{worker}finally{lock.unlock()}
    }
    public func collectReturned():Bool {
        lock.lock()
        try{
            if(retiredLocked() || joinedLocked()){return true}
            if(!runningLocked() || joining){return false}
            joining=true
        }finally{lock.unlock()}
        try{
            // The helper has completely returned BEFORE aliases are cleared.
            // A thrown get/tryGet gives no accepted successful witness and
            // keeps Running/paid. The physical caller must capture its exact
            // failure while its original producer payment remains alive.
            if(!tryObserveActualFutureReturned()){return false}
            lock.lock()
            try{
                action=None<()->Unit>;worker=None<Future<Unit>>
                phase=HostHubProcessProducerPhase.Joined
            }finally{lock.unlock()}
            true
        }finally{lock.lock();try{joining=false}finally{lock.unlock()}}
    }
    // Called by the outer resource owner only AFTER collectReturned itself
    // has returned. No one can release a running/unknown or active join cell.
    private func allActualSecondaryAcksWholeHelper180():Bool{
        for(index in 0..cleanupFailures180.getOrThrow().size){
            match(cleanupConsumers180.getOrThrow()[index]){case Some(value)=>if(!value.isAcknowledged()){return false}
                case None=>return false}
            let error=cleanupFailures180.getOrThrow()[index]
            match(error as HostHubProcessHeldProducerFailure180){case Some(held)=>
                if(!held.producer.retireObservedReturn()){return false};case None=>()}
            match(error as HubProcessStoreFailure180){case Some(held)=>
                if(!held.retireReturnedPayment180()){return false};case None=>()}}
        true
    }
    public func retireObservedReturn():Bool {
        lock.lock()
        try{
            if(retiredLocked()){return true}
            if(!joinedLocked() || joining || action.isSome() || worker.isSome() || failureBorrowers180!=0 ||
                pendingCleanupFailure180.isSome() || cleanupRegistrationFailure180.isSome()){return false}
            if(!allActualSecondaryAcksWholeHelper180()){return false}
            // ACKs are each actual consumer's receipt after its complete loan;
            // no array count or the primary consumer can ACK a secondary.

            if(originalFailure180.isSome()){
                if(failureConsumer180.isNone() || !failureConsumer180.getOrThrow().isAcknowledged()){return false}
                match(storeFailure180){case Some(cell)=>if(!cell.retireReturnedPayment180()){return false};case None=>()}
                match(nestedFailure180){case Some(cell)=>if(!cell.retireObservedReturn()){return false};case None=>()}
                nestedFailure180=None<HostHubProcessProducerCell>
                originalFailure180=None<Exception>;failureConsumer180=None<OwnedFailureDataConsumer113>
                captureFailure180=None<Exception>;storeFailure180=None<HubProcessStoreFailure180>
            }
            cleanupFailures180=None<ArrayList<Exception>>
            cleanupConsumers180=None<ArrayList<?OwnedFailureDataConsumer113>>
            let paid=payment.getOrThrow()
            paid.close()
            payment=None<HubProcessPaidOwner>
            phase=HostHubProcessProducerPhase.Retired
            true
        }finally{lock.unlock()}
    }
    public func retireNeverStartedAfterWholeCaller180():Bool{
        lock.lock();try{
            if(retiredLocked()){return true}
            if(!registered || !reservedLocked() || action.isSome() || worker.isSome() || joining ||
                originalFailure180.isSome() || (pendingCleanupFailure180.isSome() || cleanupRegistrationFailure180.isSome() || !(cleanupFailures180.isNone() || cleanupFailures180.getOrThrow().isEmpty())) || failureBorrowers180!=0){return false}
            phase=HostHubProcessProducerPhase.Joined
        }finally{lock.unlock()}
        retireObservedReturn()
    }
    private func observeActualFutureBlocking180():Bool {
        let actual=borrowActualFuture()
        match(actual){case Some(value)=>value.get();true;case None=>false}
    }
    // Only a different actual physical producer (the monitor/controller) may
    // await this cell. Its full get helper returns before clearing action and
    // Future fields. The monitor never attempts to join its own current cell.
    public func awaitActualReturn180():Bool {
        lock.lock()
        try{if(joinedLocked() || retiredLocked()){return true}
            if(!runningLocked() || joining){return false};joining=true}finally{lock.unlock()}
        try{
            if(!observeActualFutureBlocking180()){return false}
            lock.lock();try{action=None<()->Unit>;worker=None<Future<Unit>>
                phase=HostHubProcessProducerPhase.Joined}finally{lock.unlock()}
            true
        }finally{lock.lock();try{joining=false}finally{lock.unlock()}}
    }
}

// This private registry is DATA custody, not a launch grant. It must be kept
// in the actual named process incarnation record before any producer starts.
// A permanently retained raw caller alias is not refundable through this API.
public class HostHubProcessProducerCustody {
    private let lock=Mutex()
    private let meter:HostPaidValueProjection151
    private let cells=ArrayList<HostHubProcessProducerCell>()
    // A constructor/list/registration failure must not lose its only lease.
    // No capture cell, new Source or potentially running producer is inferred
    // absent merely because allocation or registry insertion threw.
    private var pendingPayment:?HubProcessPaidOwner=None<HubProcessPaidOwner>
    // The original caller cannot construct the lock/list/controller first
    // and invoice them afterward. Preparation funds their retained metadata
    // through the same original meter before invoking this constructor.
    private init(meter:HostPaidValueProjection151){this.meter=meter}
    public static func prepare(meter:HostPaidValueProjection151):HostHubProcessProducerCustody {
        meter.fundAdditional151(4096,8)
        // Establish the actual same-bank parent ledger before any caller
        // measures the prepared registry. Its fixed header stays paid.
        let phase = prepareSharedLedgerFrame204(meter)
        // Only the returned temporary header is released; this helper
        // exported no DATA, action, Future, Source or physical witness.
        phase.close()
        HostHubProcessProducerCustody(meter)
    }
    private static func prepareSharedLedgerFrame204(meter:HostPaidValueProjection151):HubProcessPaidOwner {
        meter.deriveDataPhase151(1024)
    }
    public func reserveProducerBeforeClosure(generation!:Int64=0):HostHubProcessProducerCell {
        lock.lock()
        try{
            if(pendingPayment.isSome()){
                throw IllegalStateException("unregistered process producer payment remains held")}
            // SUM is independent for stdout, stderr, monitor, readiness and
            // each real generation/restart; it is never a maximum reused by
            // concurrent tasks. Original captured graph is separately paid.
            let paid=meter.deriveDataPhase151(65536)
            pendingPayment=Some(paid)
            // Reuse only a cleared, physically retired stable carrier. Its
            // Root-paid metadata remains charged even if the scheduler still
            // retains its empty wrapper; no old DATA/action is refundable by GC.
            for(cell in cells){if(cell.isFullyRetired180()){
                cell.installBeforeNextClosure180(paid,generation)
                pendingPayment=None<HubProcessPaidOwner>;return cell}}
            meter.fundAdditional151(4096,8)
            let cell=HostHubProcessProducerCell(paid,generation:generation)
            cells.add(cell);cell.registerBeforeSpawn()
            pendingPayment=None<HubProcessPaidOwner>
            cell
        }finally{lock.unlock()}
    }
    public func countRegistered():Int64 {lock.lock();try{cells.size}finally{lock.unlock()}}
    public func hasNoReservedOrRegisteredProducers180():Bool {
        lock.lock();try{
            if(pendingPayment.isSome()){return false}
            for(cell in cells){if(!cell.isFullyRetired180()){return false}}
            true
        }finally{lock.unlock()}}

    public func at(index:Int64):HostHubProcessProducerCell {lock.lock();try{cells[index]}finally{lock.unlock()}}
    // A caller walks stable cells without allocating an unpaid snapshot.
    // Actual cells must each observe a real Future return and be retired in
    // a later outer call; countRegistered cannot acknowledge a producer.
}
