package agent_rpc

import agent_domain.*
import agent_runtime.*
import agent_product.*
import agent_store.*
import tool_runtime.*
import std.convert.*
import logical_json_payload.LogicalJsonOwnerReservation as RpcQueuedLease113
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These controls use the actual Product/SQLite/Core queue path. An ordinary
// callback below witnesses the complete worker return, never a StdOut ACK.
private class RpcQueuedCanonicalGate113 {
    let entered=AtomicBool(false)
    let released=AtomicBool(false)
    func emit(value:String):Unit {
        if (!value.contains("\"type\":\"prompt_result\"")) { return }
        entered.store(true)
        let end=MonoTime.now()+Duration.second*5
        while (!released.load() && MonoTime.now()<end) { sleep(Duration.millisecond*2) }
        if (!released.load()) { throw IllegalStateException("queued canonical fixture output is still active") }
    }
}
private func rpcQueuedWait113(condition:()->Bool):Bool {
    let end=MonoTime.now()+Duration.second*5
    while (!condition() && MonoTime.now()<end) { sleep(Duration.millisecond*2) }
    condition()
}
private func rpcQueuedRoot113():String {
    if (!exists(Path("target"))) { Directory.create("target",recursive:true) }
    Directory.createTemp("target").toString()
}
private func rpcQueuedProduct113(root:String):ProductRuntime {
    openProduct(config:ProductConfig(workspaceRoot:root,settingsRoot:root+"/settings",
        stateRoot:root+"/state",fixture:true,asyncEnabled:false,
        approvalMode:ApprovalMode.Yolo)).value().getOrThrow()
}
private func rpcQueuedCount113(db:SqliteDatabase,sql:String,parameters:Array<SqlParameter>):Int64 {
    let rows=db.query(sql,parameters)
    @Expect(rows.size,1)
    Int64.parse(rows[0].required(0))
}
private class RpcQueuedActualInputs113 {
    let payment:RpcQueuedLease113
    var primary:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>
    var secondary:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>
    var store:?RpcQueuedStoreFailure113=None<RpcQueuedStoreFailure113>
    func retainStore(cell:RpcQueuedStoreFailure113):Unit { cell.previous113=store;store=Some(cell) }
    private func takeReturnedStorePaymentHelper():?RpcQueuedLease113 {
        var previous:?RpcQueuedStoreFailure113=None<RpcQueuedStoreFailure113>
        var cursor=store
        while(cursor.isSome()) {
            let cell=cursor.getOrThrow();let next=cell.previous113
            let paid=cell.takeRetirementPaymentAfterReturned113()
            if(paid.isSome()) {
                match(previous){case Some(actual)=>actual.previous113=next;case None=>store=next}
                return paid
            }
            previous=cursor;cursor=next
        }
        None<RpcQueuedLease113>
    }
    func retireReturnedStores():Unit {
        while(true) {
            let paid=takeReturnedStorePaymentHelper()
            match(paid){case Some(actual)=>actual.close();case None=>return}
        }
    }
    init(payment:RpcQueuedLease113) { this.payment=payment }
    func pay(bytes:Int64):Result<Unit> {
        payment.ensureRetainedPeak(65536+bytes*64)
        Result<Unit>.Ok(())
    }
    func allocate(bytes:Int64):RpcQueuedLease113 {
        let child=payment.deriveRetainedLease()
        try { child.ensureRetainedPeak(bytes);child }
        catch (error:Exception) { child.close();throw error }
    }
    func capture(error:AgentError):Unit {
        match (captureOwnedFailureData113<Unit>(error,{bytes=>allocate(bytes)})) {
            case OwnedFailureDataOutcome113.Failure(value)=>primary=Some(value)
            case _=>throw IllegalStateException("actual primary error was not captured") }
    }
}
private func rpcQueuedTake113(session:ApplicationSession,paid:RpcQueuedActualInputs113):QueuedInteraction {
    session.takeRpcQueuedAtReturnedBoundaryWithDataPayment113(
        Result<ApplicationResponse>.Ok(ApplicationResponse(false)),
        {bytes=>paid.pay(bytes)}).value().getOrThrow().getOrThrow()
}
private func rpcQueuedOrigin113(session:ApplicationSession,value:QueuedInteraction,
    paid:RpcQueuedActualInputs113):QueuedRunInitiatorData113 {
    session.prepareRpcQueuedInitiator113(value,{bytes=>paid.pay(bytes)}).value().getOrThrow()
}
private func rpcQueuedInvoke113(session:ApplicationSession,value:QueuedInteraction,
    origin:QueuedRunInitiatorData113,paid:RpcQueuedActualInputs113):Result<ApplicationResponse> {
    session.handleRpcQueuedAtReturnedBoundary113(value,origin,{bytes=>paid.allocate(bytes)},
        {error=>paid.capture(error)},paid.payment,{cell=>paid.retainStore(cell)})
}

@Test
class ActualRpcQueuedCanonical113Tests {
    @TestCase
    func OriginalQueuedEntryBecomesActualUserItemAndStepZeroThenReopenCannotReplay():Unit {
        let root=rpcQueuedRoot113();let product=rpcQueuedProduct113(root)
        let session=product.applicationSession();let thread=ThreadId(session.id().value)
        let gate=RpcQueuedCanonicalGate113()
        let server=ProductJsonlRpcServer(session,{frame=>gate.emit(frame)})
        let first=spawn { server.handle("{\"id\":\"durable-first\",\"type\":\"prompt\",\"message\":\"hello actual first turn\"}") }
        try {
            @Expect(rpcQueuedWait113({=>gate.entered.load()}))
            let beforeCalls=product.fixtureProbe.getOrThrow().observedCallCount11318()
            @Expect(session.enqueue("actual-durable-correlation","follow_up","hello durable original entry").isOk())
            let original=scopedInboxEntryId(thread,LaneId("main"),"actual-durable-correlation")
            let db=SqliteDatabase(root+"/state/state.db")
            try {
                @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? AND status='queued'",
                    [SqlParameter.Text(original.value)]),1)
                server.beginRunWorkerShutdown113()
                @Expect(server.collectRunWorkerRetirement113(),false)
                gate.released.store(true)
                @Expect(first.get().contains("\"success\":true"))
                @Expect(rpcQueuedWait113({=>server.collectRunWorkerRetirement113()}))
                @Expect(session.queuedCount(),0)
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),beforeCalls+1)
                let rows=db.query("SELECT inbox.status,inbox.claimed_step_id,step.id,step.input_entry_id,"+
                    "step.accepted_item_id,step.ordinal,item.payload,run.thread_id,lane.lane_id "+
                    "FROM lane_inbox_entries inbox JOIN step_records step ON step.input_entry_id=inbox.id "+
                    "JOIN items item ON item.id=step.accepted_item_id JOIN runs run ON run.id=step.run_id "+
                    "JOIN run_lane_bindings lane ON lane.run_id=run.id WHERE inbox.id=?",
                    [SqlParameter.Text(original.value)])
                @Expect(rows.size,1)
                @Expect(rows[0].required(0),"applied")
                @Expect(rows[0].required(1),rows[0].required(2))
                @Expect(rows[0].required(3),original.value)
                @Expect(rows[0].required(4),original.value)
                @Expect(rows[0].required(5),"0")
                @Expect(rows[0].required(6),encodeStoredThreadContent(
                    ThreadItemContent.UserMessage([ThreadMessagePart.Text("hello durable original entry")])))
                @Expect(rows[0].required(7),thread.value)
                @Expect(rows[0].required(8),"main")
                @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=?",
                    [SqlParameter.Text(original.value)]),1)
                let restored=product.applicationSession(sessionId:Some(session.id()))
                @Expect(restored.queuedCount(),0)
                @Expect(restored.resumeStartup().value().getOrThrow().isNone())
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),beforeCalls+1)
            } finally { db.close() }
            let reopened=SqliteDatabase(root+"/state/state.db")
            try {
                @Expect(rpcQueuedCount113(reopened,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? AND status='applied'",
                    [SqlParameter.Text(original.value)]),1)
                @Expect(rpcQueuedCount113(reopened,"SELECT COUNT(*) FROM step_records WHERE input_entry_id=? AND ordinal=0",
                    [SqlParameter.Text(original.value)]),1)
            } finally { reopened.close() }
        } finally {
            gate.released.store(true);let _=first.get();server.close()
            product.close().value().getOrThrow();remove(root,recursive:true)
        }
        // The worker retired; actual public canonical history still has its
        // independent paid input share. This does not claim Native Root zero.
    }

    @TestCase
    func ChangedActualInboxPayloadRejectsBeforeModelAndBeforeAnyNewRunItemOrStep():Unit {
        let root=rpcQueuedRoot113();let product=rpcQueuedProduct113(root)
        let session=product.applicationSession()
        let payment=reserveProductControlMetadata113(65536)
        let paid=RpcQueuedActualInputs113(payment)
        let db=SqliteDatabase(root+"/state/state.db")
        try {
            @Expect(session.enqueue("changed-original","follow_up","must not reach the model").isOk())
            let value=rpcQueuedTake113(session,paid);let origin=rpcQueuedOrigin113(session,value,paid)
            let runs=db.scalarInt("SELECT COUNT(*) FROM runs")
            let items=db.scalarInt("SELECT COUNT(*) FROM items")
            let steps=db.scalarInt("SELECT COUNT(*) FROM step_records")
            let calls=product.fixtureProbe.getOrThrow().observedCallCount11318()
            db.execute("UPDATE lane_inbox_entries SET payload='{}' WHERE id=?",[SqlParameter.Text(origin.entryId.value)])
            try { let _=rpcQueuedInvoke113(session,value,origin,paid)
                throw IllegalStateException("changed actual row must not be accepted") }
            catch (failure:RpcQueuedStoreFailure113) {
                @Expect(failure.admitConsumer113({consumer=>paid.secondary=Some(consumer);true})) }
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),calls)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM runs"),runs)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM items"),items)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM step_records"),steps)
            @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? AND payload='{}' AND status='queued' AND claimed_step_id IS NULL",
                [SqlParameter.Text(origin.entryId.value)]),1)
            @Expect(paid.secondary.getOrThrow().withError({error,_=>
                @Expect(error.kind,AgentErrorKind.RecoveryRequired)
                @Expect(error.code,"inbox.rpc_queued_settlement_failed")
                @Expect(error.fields.size,1)
                @Expect(error.fields[0].name,"inbox_entry_id")
                @Expect(error.fields[0].value,origin.entryId.value)
            }).isOk())
            @Expect(paid.secondary.getOrThrow().isAcknowledged(),false)
            @Expect(paid.secondary.getOrThrow().acknowledgeAfterConsumption().isOk())
            paid.secondary=None<OwnedFailureDataConsumer113>
        } finally { paid.retireReturnedStores();db.close();product.close().value().getOrThrow();payment.close();remove(root,recursive:true) }
    }

    @TestCase
    func RealProcessingReservationSurvivesReopenWithoutInventingModelStepOrReplay():Unit {
        let root=rpcQueuedRoot113();let product=rpcQueuedProduct113(root)
        let session=product.applicationSession();let id=session.id()
        let payment=reserveProductControlMetadata113(65536)
        let paid=RpcQueuedActualInputs113(payment)
        let db=SqliteDatabase(root+"/state/state.db")
        try {
            @Expect(session.enqueue("processing-original","follow_up","/dump").isOk())
            let value=rpcQueuedTake113(session,paid);let origin=rpcQueuedOrigin113(session,value,paid)
            let calls=product.fixtureProbe.getOrThrow().observedCallCount11318()
            let steps=db.scalarInt("SELECT COUNT(*) FROM step_records")
            SqliteInboxStepStore(db).prepareActualRpcQueuedInput113(origin,true,{bytes=>paid.allocate(bytes)},{cell=>paid.retainStore(cell)})
            @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? AND status='processing' AND claimed_step_id IS NULL",
                [SqlParameter.Text(origin.entryId.value)]),1)
            let restored=product.applicationSession(sessionId:Some(id))
            @Expect(restored.queuedCount(),0)
            let recovery=restored.resumeStartup()
            @Expect(recovery.isError())
            @Expect(recovery.error().getOrThrow().code,"inbox.rpc_processing_recovery_required")
            @Expect(db.scalarInt("SELECT COUNT(*) FROM step_records"),steps)
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),calls)
            // Only the actual known handler return is eligible to settle the
            // reserved input. Reopen itself cannot manufacture that return.
            @Expect(session.handle("/dump").isOk())
            SqliteInboxStepStore(db).completeReturnedRpcInput113(origin,true,true,{bytes=>paid.allocate(bytes)},{cell=>paid.retainStore(cell)})
            @Expect(SqliteInboxStepStore(db).actualRpcQueuedInputTerminal113(origin,{bytes=>paid.allocate(bytes)},{cell=>paid.retainStore(cell)}))
            @Expect(db.scalarInt("SELECT COUNT(*) FROM step_records"),steps)
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),calls)
        } finally { paid.retireReturnedStores();db.close();product.close().value().getOrThrow();payment.close();remove(root,recursive:true) }
    }
}

private class RpcQueuedSqlPressure113 {
    let inputs: RpcQueuedActualInputs113
    let pressure: RpcQueuedLease113
    init(inputs: RpcQueuedActualInputs113, pressure: RpcQueuedLease113) {
        this.inputs=inputs;this.pressure=pressure
    }
    func retainBeforeSql(cell: RpcQueuedStoreFailure113): Unit {
        inputs.retainStore(cell)
        @Expect(inputs.payment.retainedCustodyUsage113()[0]>16777216)
        let used=productControlMetadataUsage113()[1]
        let own=pressure.retainedCustodyUsage113()[1]
        @Expect(used<=134217728)
        pressure.ensureRetainedPeak(134217728-used+own)
        @Expect(productControlMetadataUsage113()[1],134217728)
    }
}

@Test
class ActualRpcQueuedSqlCustody113Tests {
    @TestCase
    func OversizedActualPayloadIsComparedInsideSqlWithoutNewRunOrModelDispatch(): Unit {
        let fixture=reserveProductControlMetadata113(2097152)
        try { rpcQueuedOversizedPredicateBody113() }
        finally { fixture.close() }
    }
    @TestCase
    func SqlOriginalErrorSurvivesSameBankRefusalThenFullConsumerLoanAndTrueAck(): Unit {
        let fixture=reserveProductControlMetadata113(4194304)
        try { rpcQueuedSqlPressureBody113() }
        finally { fixture.close() }
    }
}
private func rpcQueuedOversizedPredicateBody113(): Unit {
    let root=rpcQueuedRoot113();let product=rpcQueuedProduct113(root)
    let payment=reserveProductControlMetadata113(65536)
    let paid=RpcQueuedActualInputs113(payment)
    let session=product.applicationSession();let db=SqliteDatabase(root+"/state/state.db")
    try {
        @Expect(session.enqueue("large-original-row","follow_up","tiny original input").isOk())
        let value=rpcQueuedTake113(session,paid);let origin=rpcQueuedOrigin113(session,value,paid)
        let runs=db.scalarInt("SELECT COUNT(*) FROM runs")
        let steps=db.scalarInt("SELECT COUNT(*) FROM step_records")
        let calls=product.fixtureProbe.getOrThrow().observedCallCount11318()
        // The actual fixture root prepays both native SQL zeroblob/record
        // buffers. No 1 MiB Cj String or array is seeded into the consumer.
        db.execute("UPDATE lane_inbox_entries SET payload=zeroblob(1048576) WHERE id=?",
            [SqlParameter.Text(origin.entryId.value)])
        try { let _=rpcQueuedInvoke113(session,value,origin,paid)
            throw IllegalStateException("oversized modified row must fail its full predicate") }
        catch (failure:RpcQueuedStoreFailure113) {
            @Expect(refEq(failure,paid.store.getOrThrow()))
            @Expect(failure.admitConsumer113({consumer=>paid.secondary=Some(consumer);true}))
        }
        @Expect(db.scalarInt("SELECT COUNT(*) FROM runs"),runs)
        @Expect(db.scalarInt("SELECT COUNT(*) FROM step_records"),steps)
        @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),calls)
        @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? " +
            "AND length(CAST(payload AS BLOB))=1048576 AND status='queued' AND claimed_step_id IS NULL",
            [SqlParameter.Text(origin.entryId.value)]),1)
        @Expect(paid.secondary.getOrThrow().withError({error,_=>
            @Expect(error.code,"inbox.rpc_queued_settlement_failed")
            @Expect(error.message,"actual queued input identity/content/status changed")
            @Expect(error.fields[0].value,origin.entryId.value)
        }).isOk())
        @Expect(paid.secondary.getOrThrow().acknowledgeAfterConsumption().isOk())
        paid.secondary=None<OwnedFailureDataConsumer113>
        paid.retireReturnedStores()
        @Expect(paid.store.isNone())
    } finally { db.close();product.close().value().getOrThrow();payment.close();remove(root,recursive:true) }
}
private func rpcQueuedSqlPressureBody113(): Unit {
    let root=rpcQueuedRoot113();let product=rpcQueuedProduct113(root)
    let payment=reserveProductControlMetadata113(65536)
    let paid=RpcQueuedActualInputs113(payment)
    let pressure=reserveProductControlMetadata113(65536)
    let fill=RpcQueuedSqlPressure113(paid,pressure)
    let session=product.applicationSession();let db=SqliteDatabase(root+"/state/state.db")
    try {
        let input="/dump "+String.fromUtf8(Array<Byte>(204800,repeat:b'x'))
        @Expect(session.enqueue("sql-original-pressure","follow_up",input).isOk())
        let value=rpcQueuedTake113(session,paid);let origin=rpcQueuedOrigin113(session,value,paid)
        let steps=db.scalarInt("SELECT COUNT(*) FROM step_records")
        let calls=product.fixtureProbe.getOrThrow().observedCallCount11318()
        db.execute("CREATE TRIGGER rpc_queued_original_failure BEFORE UPDATE ON lane_inbox_entries " +
            "WHEN NEW.status='processing' BEGIN SELECT RAISE(ABORT,'actual original queued SQL failure'); END")
        try {
            SqliteInboxStepStore(db).prepareActualRpcQueuedInput113(origin,true,
                {bytes=>paid.allocate(bytes)},{cell=>fill.retainBeforeSql(cell)})
            throw IllegalStateException("actual SQL trigger must produce its original error")
        } catch (failure:RpcQueuedStoreFailure113) {
            @Expect(refEq(failure,paid.store.getOrThrow()))
            failure.withOriginal113({error=>
                @Expect(error.message.contains("actual original queued SQL failure"))
                @Expect(error.message.contains("logical JSON"),false)
            })
            @Expect(failure.admitConsumer113({consumer=>paid.secondary=Some(consumer);true}),false)
            @Expect(paid.secondary.isNone())
            @Expect(failure.takeRetirementPaymentAfterReturned113().isNone())
            // Only pressure is released. No SQL retry, status change, fake
            // receipt or ACK occurs before the complete original error loan.
            pressure.close()
            @Expect(failure.admitConsumer113({consumer=>paid.secondary=Some(consumer);true}))
        }
        @Expect(db.scalarInt("SELECT COUNT(*) FROM step_records"),steps)
        @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),calls)
        @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? " +
            "AND status='queued' AND claimed_step_id IS NULL",[SqlParameter.Text(origin.entryId.value)]),1)
        @Expect(paid.secondary.getOrThrow().withError({error,_=>
            @Expect(error.kind,AgentErrorKind.RecoveryRequired)
            @Expect(error.code,"inbox.rpc_queued_settlement_failed")
            @Expect(error.message.contains("actual original queued SQL failure"))
            @Expect(error.retryable,false);@Expect(error.fallbackAllowed,false)
            @Expect(error.fields.size,1);@Expect(error.fields[0].name,"inbox_entry_id")
            @Expect(error.fields[0].value,origin.entryId.value)
            @Expect(error.attemptFailure.isNone());@Expect(error.observation.isNone())
            @Expect(paid.secondary.getOrThrow().acknowledgeAfterConsumption().isError())
        }).isOk())
        @Expect(paid.secondary.getOrThrow().isAcknowledged(),false)
        @Expect(paid.secondary.getOrThrow().acknowledgeAfterConsumption().isOk())
        paid.secondary=None<OwnedFailureDataConsumer113>
        paid.retireReturnedStores()
        @Expect(paid.store.isNone())
    } finally {
        pressure.close();db.close();product.close().value().getOrThrow()
        payment.close();remove(root,recursive:true)
    }
}

// One explicit Support fixture retains refused output debt for the lifetime of
// this test process. It never ACKs, retries SQL or reports a Native Root refund.
private class RpcQueuedRoutingGate113 {
    let firstEntered=AtomicBool(false)
    let firstReleased=AtomicBool(false)
    let writerEntered=AtomicBool(false)
    let writerReleased=AtomicBool(false)
    let queuedFrames=AtomicInt64(0)
    func emit(frame:String):Unit {
        if(frame.contains("\"id\":\"sql-routing-held\"")){queuedFrames.fetchAdd(1)}
        if(!frame.contains("\"type\":\"prompt_result\"") ||
            !frame.contains("\"id\":\"sql-routing-first\"")){return}
        firstEntered.store(true)
        let end=MonoTime.now()+Duration.second*5
        while(!firstReleased.load() && MonoTime.now()<end){sleep(Duration.millisecond*2)}
        if(!firstReleased.load()){throw IllegalStateException("queued routing first output is still active")}
    }
    func holdWriter(transaction:SqliteTransaction):Unit {
        // Actual BEGIN IMMEDIATE already owns the original SQLite write lock.
        writerEntered.store(true)
        let end=MonoTime.now()+Duration.second*5
        while(!writerReleased.load() && MonoTime.now()<end){sleep(Duration.millisecond*2)}
        if(!writerReleased.load()){throw IllegalStateException("queued routing SQL writer is still active")}
    }
}
private class RpcQueuedRoutingPressureBlock113 {
    let payment:LogicalJsonFixedBufferReservation
    var bytes:?Array<Byte>
    init(payment:LogicalJsonFixedBufferReservation){
        this.payment=payment;bytes=Some(Array<Byte>(65536,repeat:0))
    }
    private func clearBytes():Unit{bytes=None<Array<Byte>>}
    func close():Unit{clearBytes();payment.close()}
}
private class RpcQueuedRoutingFixture113 {
    let payment:RpcQueuedLease113
    let gate=RpcQueuedRoutingGate113()
    let pressure=ArrayList<RpcQueuedRoutingPressureBlock113>()
    var server:?ProductJsonlRpcServer=None<ProductJsonlRpcServer>
    var first:?Future<String>=None<Future<String>>
    var writer:?Future<Unit>=None<Future<Unit>>
    init(payment:RpcQueuedLease113){this.payment=payment}
    func releasePressure():Unit{
        for(block in pressure){block.close()}
        pressure.clear()
    }
    func drainFixtureFutures():Unit{
        match(writer){case Some(actual)=>actual.get();case None=>()}
        match(first){case Some(actual)=>let _=actual.get();case None=>()}
        writer=None<Future<Unit>>;first=None<Future<String>>
    }
}
// Null until caller prepayment precedes construction of the actual fixture.
// This explicit unsafe Support holder has no production registration/fallback.
private var rpcQueuedHeldRoutingFixture113:?RpcQueuedRoutingFixture113=None<RpcQueuedRoutingFixture113>

@Test
class ActualRpcQueuedOutputPressure113Tests {
    @TestCase
    func OriginalSqlFailureUnderActualRpcPressureHasNoShortFallbackAndRemainsHeld():Unit {
        @Expect(rpcQueuedHeldRoutingFixture113.isNone())
        let payment=reserveProductControlMetadata113(4194304)
        let fixture=RpcQueuedRoutingFixture113(payment)
        // Retain before any fallible producer or actual worker admission.
        rpcQueuedHeldRoutingFixture113=Some(fixture)
        rpcQueuedRoutingPressureBody113(fixture)
        // The held source and fixture owner intentionally remain reachable.
        // No successful StdOut, error ACK, Root-zero or process-exit ACK claim.
    }
}
private func rpcQueuedRoutingPressureBody113(fixture:RpcQueuedRoutingFixture113):Unit {
    let root=rpcQueuedRoot113();let product=rpcQueuedProduct113(root)
    let session=product.applicationSession();let gate=fixture.gate
    let db=SqliteDatabase(root+"/state/state.db")
    let writerDb=SqliteDatabase(root+"/state/state.db")
    let server=ProductJsonlRpcServer(session,{frame=>gate.emit(frame)})
    fixture.server=Some(server)
    try {
        fixture.first=Some(spawn {server.handle("{\"id\":\"sql-routing-first\",\"type\":\"prompt\",\"message\":\"/dump\"}")})
        @Expect(rpcQueuedWait113({=>gate.firstEntered.load()}))
        let calls=product.fixtureProbe.getOrThrow().observedCallCount11318()
        // Real retained 200 KiB UTF8 input is ignored only by the original
        // /dump builtin. Its complete paid copies make worker SUM >16 MiB.
        let input="/dump "+String.fromUtf8(Array<Byte>(204800,repeat:b'x'))
        @Expect(session.enqueue("sql-routing-held","follow_up",input).isOk())
        let original=scopedInboxEntryId(ThreadId(session.id().value),LaneId("main"),"sql-routing-held")
        let steps=db.scalarInt("SELECT COUNT(*) FROM step_records")
        db.execute("CREATE TRIGGER rpc_queued_routing_failure BEFORE UPDATE ON lane_inbox_entries "+
            "WHEN NEW.status='processing' BEGIN SELECT RAISE(ABORT,'actual original routing SQL failure'); END")
        fixture.writer=Some(spawn {writerDb.transaction<Unit>({transaction=>gate.holdWriter(transaction)})})
        @Expect(rpcQueuedWait113({=>gate.writerEntered.load()}))
        gate.firstReleased.store(true)
        @Expect(rpcQueuedWait113({=>server.observedQueuedSqlCustody113()[0]==1}))
        @Expect(fixture.writer.getOrThrow().tryGet().isNone())
        let live=server.observedWorkerJoinState113()
        @Expect(live[2]>16777216)
        @Expect(live[3],live[2])
        @Expect(server.observedQueuedSqlCustody113()[1],0)
        @Expect(server.observedQueuedSqlCustody113()[2],false)
        let before=productControlMetadataUsage113()
        var denied=false
        // Original 128 MiB /64 KiB arithmetic; no additional pool or cap.
        for(_ in 0..2048){
            let paid=try{reserveProductObservationBuffer113()}
                catch(_:Exception){denied=true;break}
            try{fixture.pressure.add(RpcQueuedRoutingPressureBlock113(paid))}
            catch(error:Exception){paid.close();throw error}
        }
        @Expect(denied)
        @Expect(!fixture.pressure.isEmpty())
        let full=productControlMetadataUsage113()
        @Expect(full[0],before[0]+fixture.pressure.size)
        @Expect(full[1],before[1]+fixture.pressure.size*65536)
        @Expect(134217728-full[1]<65536)
        gate.writerReleased.store(true)
        fixture.writer.getOrThrow().get()
        @Expect(fixture.first.getOrThrow().get().contains("\"success\":true"))
        // This reads the real Future.tryGet witness after the complete
        // runPrompts/publish/takeNext helper returned, not endpoint success.
        @Expect(rpcQueuedWait113({=>server.observedQueuedSqlCustody113()[2]}))
        let held=server.observedQueuedSqlCustody113()
        @Expect(held[0],1)
        @Expect(held[1],1) // Exact original Exception exists; consumer absent.
        @Expect(held[2])
        @Expect(held[3]) // Recognized source, unadmitted complete output.
        @Expect(gate.queuedFrames.load(),0)
        @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(),calls)
        @Expect(db.scalarInt("SELECT COUNT(*) FROM step_records"),steps)
        @Expect(rpcQueuedCount113(db,"SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? "+
            "AND status='queued' AND claimed_step_id IS NULL",[SqlParameter.Text(original.value)]),1)
        fixture.releasePressure()
        server.beginRunWorkerShutdown113()
        @Expect(server.collectRunWorkerRetirement113(),false)
        @Expect(server.observedQueuedSqlCustody113()[1],1)
        @Expect(gate.queuedFrames.load(),0)
    } finally {
        gate.firstReleased.store(true);gate.writerReleased.store(true)
        fixture.releasePressure();fixture.drainFixtureFutures()
        writerDb.close();db.close()
        // Product close is not an error consumption ACK. The server/session
        // and exact original SQL cell remain in the explicit Support holder.
        product.close().value().getOrThrow();remove(root,recursive:true)
    }
}
