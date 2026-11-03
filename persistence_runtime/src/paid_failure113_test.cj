package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class Failure113Estimator <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
class Failure113Fixture {
    let directory:String
    var database:SqliteDatabase
    var repository:SqliteRunRepository
    let run=RunId("paid-failure113-run")
    let thread=ThreadId("paid-failure113-thread")
    init(){
        directory=Directory.createTemp("/tmp").toString()
        database=SqliteDatabase(directory+"/failure.sqlite")
        let sink=SqliteThreadCommitSink(database)
        let coordinator=ThreadCoordinator(sink.createThread(thread,directory),sink)
        let runtime=AgentThreadRuntime(coordinator,ContextProjector("failure113",Failure113Estimator()),{=>10})
        let lane=ModelLane(ModelLaneRole.Main,"provider","model","responses",ModelLaneCapabilitiesSnapshot(),
            100,10,5,"estimator","retry","cache",ToolSetSnapshot("tools",[]),"system")
        runtime.startTurn(SemanticTurnId("paid-failure113-turn"),run,ItemId("paid-failure113-user"),
            ThreadItemContent.UserMessage(textMessageParts("actual failure data consumer")),lane,
            InvocationContextProjection()).value().getOrThrow()
        repository=SqliteRunRepository(database)
    }
    func reopen():Unit{database.close();database=SqliteDatabase(directory+"/failure.sqlite");repository=SqliteRunRepository(database)}
    func close():Unit{database.close();remove(directory,recursive:true)}
}
func failureOriginalData113(observation:String):AgentError{
    AgentError(AgentErrorKind.Provider,"original.failure113",String.fromUtf8(Array<Byte>(300000,repeat:b'e'))+"雪\u{0}🙂",
        retryable:true,fallbackAllowed:true,fields:[ErrorField("field\u{0}","雪🙂")],
        attemptFailure:Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
            diagnostics:AttemptFailureDiagnostics(elapsedMillis:3,softDeadlineMillis:5,hardDeadlineMillis:7,
                enteredCompletionGrace:true,lastProgressKind:AttemptProgressKind.ToolArgumentProgress,
                lastProgressAgeMillis:11,providerTerminalObserved:true,openContentBlockCount:13,
                toolCallsStarted:17,toolCallsCompleted:19))),observation:Some(OperationObservation(observation)))
}
func failurePublicationData113(pool:LogicalJsonOwnerBudget,run:RunId,thread:ThreadId):OwnedFailureRunPublication113{
    let owner=pool.acquire(1);owner.ensureRetainedPeak(16777216)
    try{failurePublicationFrame113(pool,run,thread)}finally{owner.close()}
}
func failurePublicationFrame113(pool:LogicalJsonOwnerBudget,run:RunId,thread:ThreadId):OwnedFailureRunPublication113{
    let error=failureOriginalData113("{\"unicode\":\"雪\\u0000🙂\",\"number\":-0,\"nested\":[null,true,false,1e2]}")
    let original=match(captureOwnedFailureData113<Unit>(error,{bytes=>pool.acquire(bytes)})){
        case OwnedFailureDataOutcome113.Failure(v)=>v
        case _=>throw IllegalStateException("original paid failure absent")}
    try{OwnedFailureRunPublication113(original,RunSnapshot(run,SessionId(thread.value),RunState.Failed,
        sequence:1),EventMeta(1,TraceId("paid-failure113-trace"),run,occurredAtMillis:23))}
    finally{original.acknowledgeAfterConsumption().value().getOrThrow()}
}
func expectFailureData113(error:AgentError):Unit{
    @Expect(error.kind,AgentErrorKind.Provider);@Expect(error.code,"original.failure113")
    @Expect(error.message.size>300000,true);@Expect(error.message.endsWith("雪\u{0}🙂"),true)
    @Expect(error.retryable,true);@Expect(error.fallbackAllowed,true)
    @Expect(error.fields.size,1);@Expect(error.fields[0].name,"field\u{0}");@Expect(error.fields[0].value,"雪🙂")
    let attempt=error.attemptFailure.getOrThrow();let d=attempt.diagnostics
    @Expect(attempt.kind,AttemptFailureKind.ProviderProtocolError)
    @Expect(d.elapsedMillis,3);@Expect(d.softDeadlineMillis,5);@Expect(d.hardDeadlineMillis,7)
    @Expect(d.enteredCompletionGrace,true);@Expect(d.lastProgressKind,AttemptProgressKind.ToolArgumentProgress)
    @Expect(d.lastProgressAgeMillis,11);@Expect(d.providerTerminalObserved,true)
    @Expect(d.openContentBlockCount,13);@Expect(d.toolCallsStarted,17);@Expect(d.toolCallsCompleted,19)
    @Expect(encodeAgentValue(error.observation.getOrThrow().toValue()),
        encodeAgentValue(OperationObservation("{\"unicode\":\"雪\\u0000🙂\",\"number\":-0,\"nested\":[null,true,false,1e2]}").toValue()))
}
class FailureReadbackHolder113 {var value:?OwnedFailureRunPublication113=None<OwnedFailureRunPublication113>}

@Test
class PaidFailurePersistence113Tests{
    @TestCase
    func actualCanonicalRunCloseReopenPreservesAllEightFieldsAndCallerAck113():Unit{
        let f=Failure113Fixture();let pool=LogicalJsonOwnerBudget()
        try{
            let original=failurePublicationData113(pool,f.run,f.thread)
            let saved=original.retainConsumer().value().getOrThrow()
            let event=original.retainConsumer().value().getOrThrow()
            match(f.repository.saveOwnedFailureOutcome113(saved)){
                case OwnedFailureDataOutcome113.Value(_)=>()
                case OwnedFailureDataOutcome113.Failure(v)=>v.acknowledgeAfterConsumption().value().getOrThrow();@Expect(false,true)}
            @Expect(saved.isAcknowledged(),true)
            match(f.repository.appendOwnedFailureOutcome113(event)){
                case OwnedFailureDataOutcome113.Value(_)=>()
                case OwnedFailureDataOutcome113.Failure(v)=>v.acknowledgeAfterConsumption().value().getOrThrow();@Expect(false,true)}
            @Expect(event.isAcknowledged(),true)
            @Expect(original.acknowledgeAfterConsumption().isOk(),true)
            @Expect(pool.usage()[1],0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"),1)
            f.reopen()
            // The old reader explicitly refuses nonempty new attachments; it
            // cannot silently erase the original typed failure/observation.
            @Expect(f.repository.find(f.run).isError(),true)
            let holder=FailureReadbackHolder113()
            match(f.repository.withOwnedFailureSnapshot113(f.run,EventMeta(1,TraceId("readback113"),f.run),
                {bytes=>pool.acquire(bytes)},{ actual=>holder.value=Some(actual.retainConsumer().value().getOrThrow()) })){
                case OwnedFailureDataOutcome113.Value(_)=>()
                case OwnedFailureDataOutcome113.Failure(v)=>v.acknowledgeAfterConsumption().value().getOrThrow();@Expect(false,true)}
            @Expect(pool.usage()[1]>0,true)
            @Expect(holder.value.getOrThrow().withError({error,fund=>
                fund(16777216).value().getOrThrow();expectFailureData113(error);Result<Unit>.Ok(())}).isOk(),true)
            @Expect(holder.value.getOrThrow().acknowledgeAfterConsumption().isOk(),true)
            holder.value=None<OwnedFailureRunPublication113>
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{f.close()}
    }
    @TestCase
    func snapshotAndEventBytesMatchOriginalFullDomCodecAtOriginalObservationBound113():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        try{
            owner.ensureRetainedPeak(100663296)
            // Full original 65,536 encoded-byte boundary. A near-boundary
            // numeric corpus also exercises every actual content node.
            for(observation in ["{\"text\":\"雪\\u0000🙂\\n\\\\\\\"\",\"list\":[-0,1e2,18446744073709551615]}",
                "\""+String.fromUtf8(Array<Byte>(65534,repeat:b'x'))+"\"",
                "["+String.fromUtf8(Array<Byte>(65528,{i=>if(i%2==0){b'0'}else{b','}}))+"0]"]){
                failureOriginalDomCodecFrame113(observation,owner)
            }
            // A 65K-node corpus cannot fit the unchanged 65K BYTE limit.
            // Preserve that real rejection; do not enlarge/drop the bound.
            var rejected=false
            try{let _=OperationObservation("["+String.fromUtf8(Array<Byte>(131070,{i=>if(i%2==0){b'0'}else{b','}}))+"0]")}
            catch(_:Exception){rejected=true}
            @Expect(rejected,true)
            var oversized=false
            try{let _=OperationObservation("\""+String.fromUtf8(Array<Byte>(65535,repeat:b'x'))+"\"")}
            catch(_:Exception){oversized=true}
            @Expect(oversized,true)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func actualSqlTriggerFailureTransfersCompleteSecondaryBeforeInputAck113():Unit{
        let f=Failure113Fixture();let pool=LogicalJsonOwnerBudget()
        try{
            let original=failurePublicationData113(pool,f.run,f.thread)
            let input=original.retainConsumer().value().getOrThrow()
            f.database.execute("CREATE TRIGGER failure113_before_save BEFORE UPDATE OF app_snapshot ON runs "+
                "BEGIN SELECT RAISE(ABORT,'actual storage 雪 failure113');END")
            let secondary=match(f.repository.saveOwnedFailureOutcome113(input)){
                case OwnedFailureDataOutcome113.Failure(v)=>v
                case _=>throw IllegalStateException("actual SQL trigger must fail")}
            @Expect(input.isAcknowledged(),true)
            @Expect(original.withError({error,_=>@Expect(error.code,"original.failure113");Result<Unit>.Ok(())}).isOk(),true)
            @Expect(original.acknowledgeAfterConsumption().isOk(),true)
            @Expect(pool.usage()[1]>0,true)
            @Expect(secondary.withError({error,_=>
                @Expect(error.kind,AgentErrorKind.RecoveryRequired)
                @Expect(error.code,"persistence.sqlite_run_save")
                @Expect(error.message.contains("actual storage 雪 failure113"),true)
                @Expect(error.attemptFailure.isNone(),true);@Expect(error.observation.isNone(),true)
            }).isOk(),true)
            @Expect(secondary.acknowledgeAfterConsumption().isOk(),true)
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE app_snapshot IS NOT NULL"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        }finally{f.close()}
    }
    @TestCase
    func actualReadbackMovesPaidConsumerFailureWithoutLosingAnyField113():Unit{
        let f=Failure113Fixture();let pool=LogicalJsonOwnerBudget()
        try{
            let original=failurePublicationData113(pool,f.run,f.thread)
            let input=original.retainConsumer().value().getOrThrow()
            match(f.repository.saveOwnedFailureOutcome113(input)){
                case OwnedFailureDataOutcome113.Value(_)=>()
                case OwnedFailureDataOutcome113.Failure(v)=>v.acknowledgeAfterConsumption().value().getOrThrow();@Expect(false,true)}
            @Expect(input.isAcknowledged(),true)
            original.acknowledgeAfterConsumption().value().getOrThrow()
            @Expect(pool.usage()[1],0)
            let secondary=match(f.repository.withOwnedFailureSnapshot113(f.run,
                EventMeta(1,TraceId("actual-paid-throw113"),f.run),{bytes=>pool.acquire(bytes)},
                {publication=>
                    publication.withError({error,_=>
                        throw OwnedCanonicalPaidFailure113(error,{bytes=>pool.acquire(bytes)})
                    }).value().getOrThrow()
                })){
                case OwnedFailureDataOutcome113.Failure(v)=>v
                case _=>throw IllegalStateException("actual paid callback must transfer its consumer")}
            // SQL, original decoder and reader publication have now returned
            // and ACKed. The moved, independent full error remains paid.
            @Expect(pool.usage()[1]>0,true)
            secondary.withError({error,fund=>
                fund(16777216).value().getOrThrow();expectFailureData113(error)
            }).value().getOrThrow()
            @Expect(secondary.acknowledgeAfterConsumption().isOk(),true)
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE app_snapshot IS NOT NULL"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        }finally{f.close()}
    }
    @TestCase
    func oldMissingAndNullAttachmentsRemainCompatibleAndUnknownNewFieldsReject113():Unit{
        let error=AgentError(AgentErrorKind.Provider,"old.code","old message")
        let old=errorValue(error)
        @Expect(strictErrorFrom(old).isOk(),true)
        let fields=ArrayList<ValueField>(old.fields)
        fields.add(ValueField("attempt_failure",nullValue()));fields.add(ValueField("observation",nullValue()))
        @Expect(strictErrorFrom(objectValue(fields.toArray())).isOk(),true)
        @Expect(strictFailureError113(objectValue(fields.toArray())).isOk(),true)
        fields.add(ValueField("caller_authority",boolValue(true)))
        @Expect(strictFailureError113(objectValue(fields.toArray())).isError(),true)
    }
    @TestCase
    func originalObservationIntegerNegativeZeroCanonicalizesButFractionAndExponentRemainExact157():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        try{
            owner.ensureRetainedPeak(16777216)
            // The unchanged original constructor freezes parsed DOM bytes.
            // This baseline never invokes the new paid failure writer/reader.
            let original=OperationObservation("[-0,-0.0,-0e0,1e2]")
            original.withFrozenEncodedData113({frozen=>
                @Expect(frozen,"[0,-0.0,-0e0,1e2]")
            })
            @Expect(encodeAgentValue(original.toValue().field("content").getOrThrow()),"[0,-0.0,-0e0,1e2]")
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
func failureOriginalDomCodecFrame113(observation:String,owner:LogicalJsonOwnerReservation):Unit{
    let funding=FailureCodecFunding113(owner)
    let error=failureOriginalData113(observation)
    let snapshot=RunSnapshot(RunId("oracle113"),SessionId("thread113"),RunState.Failed,error:Some(error),summary:error.message)
    let event=AgentEvent(EventMeta(1,TraceId("oracle113-trace"),RunId("oracle113")),AgentEventPayload.Diagnostic(error))
    let expectedSnapshot=failureSnapshotOriginalDomOracle113(snapshot)
    let expectedEvent=failureEventOriginalDomOracle113(event)
    @Expect(encodeFailureSnapshot113(snapshot,{bytes=>funding.pay(bytes)}).value().getOrThrow(),expectedSnapshot)
    @Expect(encodeFailureEvent113(event,{bytes=>funding.pay(bytes)}).value().getOrThrow(),expectedEvent)
    let decoded=decodeFailureSnapshot113(expectedSnapshot).value().getOrThrow().error.getOrThrow()
    @Expect(encodeAgentValue(decoded.observation.getOrThrow().toValue()),encodeAgentValue(error.observation.getOrThrow().toValue()))
    @Expect(decoded.attemptFailure.getOrThrow().diagnostics.toolCallsCompleted,19)
}
func failureOriginalDomValueOracle113(error:AgentError):AgentValue{
    let fields=ArrayList<ValueField>(errorValue(error).fields)
    fields.add(ValueField("attempt_failure",match(error.attemptFailure){case Some(v)=>failureAttemptValue113(v);case None=>nullValue()}))
    fields.add(ValueField("observation",match(error.observation){case Some(v)=>v.toValue();case None=>nullValue()}))
    objectValue(fields.toArray())
}

func failureSnapshotOriginalDomOracle113(snapshot: RunSnapshot): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("format_version", integerValue(RUN_SNAPSHOT_FORMAT_VERSION)),
                ValueField("run_id", textValue(snapshot.runId.value)),
                ValueField("session_id", textValue(snapshot.sessionId.value)),
                ValueField("status", textValue(statusName(snapshot.status))),
                ValueField("run_kind", textValue(runKindName(snapshot.kind))),
                ValueField("sequence", integerValue(snapshot.sequence)),
                ValueField("summary", textValue(snapshot.summary)),
                ValueField("model_requests", integerValue(snapshot.modelRequests)),
                ValueField("input_tokens", integerValue(snapshot.inputTokens)),
                ValueField("output_tokens", integerValue(snapshot.outputTokens)),
                ValueField("reasoning_tokens", integerValue(snapshot.reasoningTokens)),
                ValueField("cache_read_tokens", integerValue(snapshot.cacheReadTokens)),
                ValueField("cache_write_tokens", integerValue(snapshot.cacheWriteTokens)),
                ValueField("cost_micros", optionalIntegerValue(snapshot.costMicros)),
                ValueField("last_input_tokens", integerValue(snapshot.lastInputTokens)),
                ValueField("last_output_tokens", integerValue(snapshot.lastOutputTokens)),
                ValueField(
                    "last_request_duration_millis",
                    integerValue(snapshot.lastRequestDurationMillis)
                ),
                ValueField("tool_calls", integerValue(snapshot.toolCalls)),
                ValueField("turns", integerValue(snapshot.turns)),
                ValueField("structured_output", match (snapshot.structuredOutput) {
                    case Some(value) => value
                    case None => nullValue()
                }),
                ValueField("error", match (snapshot.error) {
                    case Some(error) => failureOriginalDomValueOracle113(error)
                    case None => nullValue()
                })
            ]
        )
    )
}

func failureEventOriginalDomOracle113(event: AgentEvent): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("format_version", integerValue(RUN_EVENT_FORMAT_VERSION)),
                ValueField("sequence", integerValue(event.sequence)),
                ValueField("run_id", textValue(event.runId.value)),
                ValueField("kind", textValue(eventKindName(event.kind))),
                ValueField("timestamp_ms", integerValue(event.meta.occurredAtMillis)),
                ValueField("trace_id", textValue(event.meta.traceId.value)),
                ValueField("turn_id", eventOptionalTurnIdValue(event.meta.turnId)),
                ValueField("request_id", eventOptionalRequestIdValue(event.meta.requestId)),
                ValueField("tool_batch_id", eventOptionalToolBatchIdValue(event.meta.toolBatchId)),
                ValueField("tool_call_id", eventOptionalToolCallIdValue(event.meta.toolCallId)),
                ValueField("operation_id", eventOptionalOperationIdValue(event.meta.operationId)),
                ValueField("payload_type", textValue(eventPayloadName(event.payload))),
                ValueField("detail", failureOriginalDomValueOracle113(match(event.payload){case AgentEventPayload.Diagnostic(e)=>e;case _=>throw IllegalStateException("original Diagnostic oracle required")}))
            ]
        )
    )
}

// A source/test-only adapter to the SAME actual pre-existing test owner. Its
// cumulative invoices coexist with the original 96MiB oracle reservation.
class FailureCodecFunding113{
    let owner:LogicalJsonOwnerReservation
    var extra:Int64=0
    init(owner:LogicalJsonOwnerReservation){this.owner=owner}
    func pay(bytes:Int64):Result<Unit>{
        extra=ownedOuterErrorAdd333(extra,bytes)
        try{owner.ensureRetainedPeak(ownedOuterErrorAdd333(100663296,extra));Result<Unit>.Ok(())}
        catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.BudgetExceeded,"test.codec_pressure113","original codec test bank is exhausted"))}
    }
}
