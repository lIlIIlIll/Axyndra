package agent_runtime

import agent_domain.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func publicationSeed113(pool: LogicalJsonOwnerBudget): OwnedFailureRunPublication113 {
    let root=ownedFailureSeed113(pool)
    try {
        let first=root.retainConsumer().value().getOrThrow()
        try { OwnedFailureRunPublication113(first,RunSnapshot(RunId("publication113"),
            SessionId("thread113"),RunState.Failed),EventMeta(1,TraceId("trace113"),RunId("publication113"))) }
        finally { first.acknowledgeAfterConsumption().value().getOrThrow() }
    } finally { root.closeAfterProducerRetirement().value().getOrThrow() }
}
@Test
class OwnedFailurePublication113Tests {
    @TestCase
    func separateStorageEventAndCallerSharesSurviveOriginalPublicationAck113(): Unit {
        let pool=LogicalJsonOwnerBudget();let original=publicationSeed113(pool)
        let storage=original.retainConsumer().value().getOrThrow()
        let event=original.retainConsumer().value().getOrThrow()
        let caller=original.retainConsumer().value().getOrThrow()
        @Expect(original.acknowledgeAfterConsumption().isOk(),true)
        @Expect(original.matchesRun(RunId("publication113")),false)
        @Expect(original.retainConsumer().isError(),true)
        @Expect(storage.withSnapshot({ snapshot,_ =>
            @Expect(snapshot.status,RunState.Failed)
            @Expect(snapshot.error.getOrThrow().observation.isSome(),true)
            Result<Unit>.Ok(()) }).isOk(),true)
        @Expect(storage.acknowledgeAfterConsumption().isOk(),true)
        @Expect(event.withDiagnostic({ diagnostic,_ =>
            match(diagnostic.payload){case AgentEventPayload.Diagnostic(error)=>
                @Expect(error.attemptFailure.getOrThrow().kind,AttemptFailureKind.ProviderTransportError)
                case _=>@Expect(false,true)}
            Result<Unit>.Ok(()) }).isOk(),true)
        @Expect(event.acknowledgeAfterConsumption().isOk(),true)
        @Expect(pool.usage()[1]>0,true)
        @Expect(caller.withError({ error,_ =>
            @Expect(error.message.endsWith("\u{0}雪🙂"),true);Result<Unit>.Ok(()) }).isOk(),true)
        @Expect(caller.acknowledgeAfterConsumption().isOk(),true)
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func genuinelyHeldSnapshotFrameRejectsConcurrentAckAndDoesNotRefund113(): Unit {
        let pool=LogicalJsonOwnerBudget();let publication=publicationSeed113(pool)
        let entered=AtomicBool(false);let release=AtomicBool(false)
        let worker: Future<Unit> = spawn {
            @Expect(publication.withSnapshot({ snapshot,_ =>
                entered.store(true)
                while(!release.load()){sleep(Duration.millisecond)}
                @Expect(snapshot.error.getOrThrow().fields[0].value,"\u{0}雪🙂")
                Result<Unit>.Ok(()) }).isOk(),true)
        }
        try {
            let deadline=MonoTime.now()+Duration.second*2
            while(!entered.load() && MonoTime.now()<deadline){sleep(Duration.millisecond)}
            @Expect(entered.load(),true)
            @Expect(publication.acknowledgeAfterConsumption().isError(),true)
            @Expect(publication.isAcknowledged(),false);@Expect(pool.usage()[1]>0,true)
        } finally {release.store(true);worker.get()}
        @Expect(publication.acknowledgeAfterConsumption().isOk(),true)
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ordinaryCallbackOkIsNotAnAliasConsumptionAck113(): Unit {
        let pool=LogicalJsonOwnerBudget();let publication=publicationSeed113(pool)
        let unconsumed=CallbackOwnedFailureEventSink113({ _=>Result<Unit>.Ok(()) })
        @Expect(unconsumed.emitOwnedFailure113(publication).isError(),true)
        @Expect(publication.isAcknowledged(),false);@Expect(pool.usage()[1]>0,true)
        let consumed=CallbackOwnedFailureEventSink113({ actual=>
            match(actual.withError({ error,_=>@Expect(error.code,"original.dynamic.code");Result<Unit>.Ok(()) })){
                case Result.Err(e)=>Result<Unit>.Err(e)
                case Result.Ok(_)=>actual.acknowledgeAfterConsumption()}
        })
        @Expect(consumed.emitOwnedFailure113(publication).isOk(),true)
        @Expect(publication.isAcknowledged(),true)
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
