package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func failureEncoderSeedFrame113(pool:LogicalJsonOwnerBudget,kind:AgentErrorKind,
    observation:String,attempt!:AttemptFailureKind=AttemptFailureKind.ProviderProtocolError):OwnedFailureDataConsumer113{
    let error=AgentError(kind,"codec.code雪\u{0}","message雪\u{0}🙂\n\\\"",retryable:true,fallbackAllowed:true,
        fields:[ErrorField("field雪\u{0}","value🙂\u{0}"),ErrorField("duplicate","one"),ErrorField("duplicate","two")],
        attemptFailure:Some(AttemptFailure(attempt,diagnostics:AttemptFailureDiagnostics(elapsedMillis:3,
            softDeadlineMillis:5,hardDeadlineMillis:7,enteredCompletionGrace:true,
            lastProgressKind:AttemptProgressKind.ToolArgumentProgress,lastProgressAgeMillis:11,
            providerTerminalObserved:true,openContentBlockCount:13,toolCallsStarted:17,toolCallsCompleted:19))),
        observation:Some(OperationObservation(observation)))
    let original=OwnedFailureData113(error,{bytes=>pool.acquire(bytes)})
    try{original.retainConsumer().value().getOrThrow()}
    finally{original.closeAfterProducerRetirement().value().getOrThrow()}
}
func failureEncoderSeed113(pool:LogicalJsonOwnerBudget,kind:AgentErrorKind,
    observation:String,attempt!:AttemptFailureKind=AttemptFailureKind.ProviderProtocolError):OwnedFailureDataConsumer113{
    let source=pool.acquire(1)
    try{source.ensureRetainedPeak(33554432);failureEncoderSeedFrame113(pool,kind,observation,attempt:attempt)}
    finally{source.close()}
}
// Independent original full DOM writer oracle. It does not call the shared
// encoder's value builder, mappings or observation splice.
func failureEncoderOriginalDom113(error:AgentError):AgentValue{
    let fields=ArrayList<AgentValue>()
    for(field in error.fields){fields.add(objectValue([ValueField("name",textValue(field.name)),ValueField("value",textValue(field.value))]))}
    let kind=match(error.kind){
        case AgentErrorKind.Configuration=>"configuration";case AgentErrorKind.Authentication=>"authentication"
        case AgentErrorKind.PermissionDenied=>"permission_denied";case AgentErrorKind.InvalidInput=>"invalid_input"
        case AgentErrorKind.RateLimited=>"rate_limited";case AgentErrorKind.Timeout=>"timeout"
        case AgentErrorKind.Transport=>"transport";case AgentErrorKind.Provider=>"provider"
        case AgentErrorKind.Protocol=>"protocol";case AgentErrorKind.Cancelled=>"cancelled"
        case AgentErrorKind.BudgetExceeded=>"budget_exceeded";case AgentErrorKind.Conflict=>"conflict"
        case AgentErrorKind.RecoveryRequired=>"recovery_required";case AgentErrorKind.Internal=>"internal"}
    let attempt=error.attemptFailure.getOrThrow();let d=attempt.diagnostics
    let attemptKind=match(attempt.kind){
        case AttemptFailureKind.ConnectTimeout=>"connect_timeout";case AttemptFailureKind.FirstResponseTimeout=>"first_response_timeout"
        case AttemptFailureKind.StreamIdleTimeout=>"stream_idle_timeout";case AttemptFailureKind.AttemptSoftDeadlineExceeded=>"attempt_soft_deadline_exceeded"
        case AttemptFailureKind.AttemptHardDeadlineExceeded=>"attempt_hard_deadline_exceeded";case AttemptFailureKind.DecisionIncompleteAtDeadline=>"decision_incomplete_at_deadline"
        case AttemptFailureKind.ProviderTerminalMissing=>"provider_terminal_missing";case AttemptFailureKind.ProtocolIncomplete=>"protocol_incomplete"
        case AttemptFailureKind.OutputLimited=>"output_limited";case AttemptFailureKind.OutputLimitedBeforeDecision=>"output_limited_before_decision"
        case AttemptFailureKind.ProviderTransportError=>"provider_transport_error";case AttemptFailureKind.ProviderProtocolError=>"provider_protocol_error"
        case AttemptFailureKind.MalformedToolArguments=>"malformed_tool_arguments";case AttemptFailureKind.UserCancelled=>"user_cancelled"
        case AttemptFailureKind.RunDeadlineExceeded=>"run_deadline_exceeded"}
    objectValue([ValueField("kind",textValue(kind)),ValueField("code",textValue(error.code)),ValueField("message",textValue(error.message)),
        ValueField("retryable",boolValue(error.retryable)),ValueField("fallback_allowed",boolValue(error.fallbackAllowed)),ValueField("fields",listValue(fields.toArray())),
        ValueField("attempt_failure",objectValue([ValueField("kind",textValue(attemptKind)),ValueField("diagnostics",objectValue([
            ValueField("elapsed_millis",integerValue(d.elapsedMillis)),ValueField("soft_deadline_millis",integerValue(d.softDeadlineMillis)),
            ValueField("hard_deadline_millis",integerValue(d.hardDeadlineMillis)),ValueField("entered_completion_grace",boolValue(d.enteredCompletionGrace)),
            ValueField("last_progress_kind",textValue("tool_argument_progress")),ValueField("last_progress_age_millis",integerValue(d.lastProgressAgeMillis)),
            ValueField("provider_terminal_observed",boolValue(d.providerTerminalObserved)),ValueField("open_content_block_count",integerValue(d.openContentBlockCount)),
            ValueField("tool_calls_started",integerValue(d.toolCallsStarted)),ValueField("tool_calls_completed",integerValue(d.toolCallsCompleted))]))])),
        ValueField("observation",error.observation.getOrThrow().toValue())])
}
func failureEncoderOracleLoan113(consumer:OwnedFailureDataConsumer113):Unit{
    consumer.withError({error,fund=>
        // Pay the complete ORIGINAL observation DOM/expected writer before
        // the oracle constructs it. The shared production path builds none.
        fund(33554432).value().getOrThrow()
        let prefix=[ValueField("type",textValue("response")),ValueField("id",textValue("id雪\u{0}")),
            ValueField("command",textValue("run")),ValueField("success",boolValue(false)),
            ValueField("error",textValue(error.message)),ValueField("numeric",numberValue("-0"))]
        let expected=ArrayList<ValueField>(prefix);expected.add(ValueField("error_data",failureEncoderOriginalDom113(error)))
        @Expect(encodeOwnedFailureError113(error,prefix,"error_data",fund).value().getOrThrow(),encodeAgentValue(objectValue(expected.toArray())))
        @Expect(encodeOwnedFailureError113(error,fund).value().getOrThrow(),encodeAgentValue(failureEncoderOriginalDom113(error)))
        @Expect(consumer.acknowledgeAfterConsumption().isError(),true)
    }).value().getOrThrow()
}
class FailureEncoderDisplay113{
    var allocation:?LogicalJsonCopiedDisplayAllocation=None<LogicalJsonCopiedDisplayAllocation>
    var code:?String=None<String>
    var message:?String=None<String>
    func clear():Unit{code=None<String>;message=None<String>}
}
func failureEncoderDisplayLoan113(consumer:OwnedFailureDataConsumer113,copied:FailureEncoderDisplay113):Unit{
    consumer.withError({error,_=>
        let invoice=ownedOuterErrorAdd333(32768,ownedOuterErrorMultiply333(ownedOuterErrorAdd333(error.code.size,error.message.size),8))
        let actual=consumer.deriveCopiedDisplayAllocation113(invoice).value().getOrThrow()
        copied.allocation=Some(actual)
        copied.code=Some(String.fromUtf8(error.code.toArray()));copied.message=Some(String.fromUtf8(error.message.toArray()))
        @Expect(consumer.acknowledgeAfterConsumption().isError(),true)
    }).value().getOrThrow()
}

@Test
class PaidErrorRuntimeEncoder11319Tests{
    @TestCase
    func allFourteenRealErrorKindsHaveOriginalFullEightFieldBytes11319():Unit{
        let pool=LogicalJsonOwnerBudget()
        for(kind in [AgentErrorKind.Configuration,AgentErrorKind.Authentication,AgentErrorKind.PermissionDenied,
            AgentErrorKind.InvalidInput,AgentErrorKind.RateLimited,AgentErrorKind.Timeout,AgentErrorKind.Transport,
            AgentErrorKind.Provider,AgentErrorKind.Protocol,AgentErrorKind.Cancelled,AgentErrorKind.BudgetExceeded,
            AgentErrorKind.Conflict,AgentErrorKind.RecoveryRequired,AgentErrorKind.Internal]){
            let consumer=failureEncoderSeed113(pool,kind,"{\"unicode\":\"雪\\u0000🙂\",\"n\":-0,\"exp\":1e2,\"u\":18446744073709551615}")
            failureEncoderOracleLoan113(consumer)
            consumer.acknowledgeAfterConsumption().value().getOrThrow();@Expect(pool.usage()[1],0)
        }
    }
    @TestCase
    func allAttemptKindsKeepTenDiagnosticsWithoutFlattening11319():Unit{
        let pool=LogicalJsonOwnerBudget()
        for(kind in [AttemptFailureKind.ConnectTimeout,AttemptFailureKind.FirstResponseTimeout,AttemptFailureKind.StreamIdleTimeout,
            AttemptFailureKind.AttemptSoftDeadlineExceeded,AttemptFailureKind.AttemptHardDeadlineExceeded,AttemptFailureKind.DecisionIncompleteAtDeadline,
            AttemptFailureKind.ProviderTerminalMissing,AttemptFailureKind.ProtocolIncomplete,AttemptFailureKind.OutputLimited,
            AttemptFailureKind.OutputLimitedBeforeDecision,AttemptFailureKind.ProviderTransportError,AttemptFailureKind.ProviderProtocolError,
            AttemptFailureKind.MalformedToolArguments,AttemptFailureKind.UserCancelled,AttemptFailureKind.RunDeadlineExceeded]){
            let consumer=failureEncoderSeed113(pool,AgentErrorKind.Provider,"{}",attempt:kind)
            failureEncoderOracleLoan113(consumer)
            consumer.acknowledgeAfterConsumption().value().getOrThrow();@Expect(pool.usage()[1],0)
        }
    }
    @TestCase
    func originalSixtyFiveKObservationAndNullSnapshotErrorBytes11319():Unit{
        let pool=LogicalJsonOwnerBudget();let source=pool.acquire(1)
        let consumer=try{
            source.ensureRetainedPeak(33554432)
            failureEncoderSeed113(pool,AgentErrorKind.Internal,"\""+String.fromUtf8(Array<Byte>(65534,repeat:b'x'))+"\"")
        }finally{source.close()}
        failureEncoderOracleLoan113(consumer)
        consumer.withError({_,fund=>
            fund(8192).value().getOrThrow()
            @Expect(encodeOwnedFailureError113(None<AgentError>,[ValueField("id",textValue("null"))],"error",fund).value().getOrThrow(),
                "{\"id\":\"null\",\"error\":null}")
        }).value().getOrThrow()
        consumer.acknowledgeAfterConsumption().value().getOrThrow();@Expect(pool.usage()[1],0)
    }
    @TestCase
    func realSameBankPressureReturnsBeforeOutputAndNeverAcknowledges11319():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged:134217728);let consumer=failureEncoderSeed113(pool,AgentErrorKind.Internal,"{}")
        consumer.withError({error,fund=>
            fund(133169152).value().getOrThrow()
            @Expect(encodeOwnedFailureError113(error,fund).isError(),true)
            @Expect(consumer.isAcknowledged(),false)
            @Expect(consumer.acknowledgeAfterConsumption().isError(),true)
        }).value().getOrThrow()
        @Expect(pool.usage()[1]>0,true)
        consumer.acknowledgeAfterConsumption().value().getOrThrow();@Expect(pool.usage()[1],0)
    }
    @TestCase
    func sharedLargePrefixRejectsOriginalSixtyFourMiBBoundWithoutEncoding11319():Unit{
        let pool=LogicalJsonOwnerBudget();let source=pool.acquire(1)
        let consumer=failureEncoderSeed113(pool,AgentErrorKind.Internal,"{}")
        try{source.ensureRetainedPeak(16777216);failureEncoderLargePrefixLoan113(consumer)}finally{source.close()}
        consumer.acknowledgeAfterConsumption().value().getOrThrow();@Expect(pool.usage()[1],0)
    }
    @TestCase
    func copiedDisplayUsesOriginalBankAndOutlivesOnlyItsRealRetirement11319():Unit{
        let pool=LogicalJsonOwnerBudget();let consumer=failureEncoderSeed113(pool,AgentErrorKind.Internal,"{}")
        @Expect(consumer.deriveCopiedDisplayAllocation113(32768).isError(),true)
        let copied=FailureEncoderDisplay113();failureEncoderDisplayLoan113(consumer,copied)
        consumer.acknowledgeAfterConsumption().value().getOrThrow()
        @Expect(pool.usage()[1]>0,true);@Expect(consumer.deriveCopiedDisplayAllocation113(32768).isError(),true)
        let actual=copied.allocation.getOrThrow()
        actual.withCopiedDisplayBorrow({=>
            @Expect(copied.code.getOrThrow(),"codec.code雪\u{0}")
            @Expect(copied.message.getOrThrow(),"message雪\u{0}🙂\n\\\"")
            @Expect(actual.closeAfterCopiedDisplayRetirement().isError(),true)
            Result<Unit>.Ok(())
        }).value().getOrThrow()
        copied.clear();copied.allocation=None<LogicalJsonCopiedDisplayAllocation>
        actual.closeAfterCopiedDisplayRetirement().value().getOrThrow();@Expect(pool.usage()[1],0)
    }
}
func failureEncoderLargePrefixLoan113(consumer:OwnedFailureDataConsumer113):Unit{
    consumer.withError({error,fund=>
        fund(16777216).value().getOrThrow()
        let shared=String.fromUtf8(Array<Byte>(1048576,repeat:b'x'))
        let values=Array<AgentValue>(65,{_=>textValue(shared)})
        let answer=encodeOwnedFailureError113(error,[ValueField("prior",listValue(values))],"error",fund)
        @Expect(answer.isError(),true);@Expect(answer.error().getOrThrow().message.contains("64MiB"),true)
        @Expect(consumer.isAcknowledged(),false)
    }).value().getOrThrow()
}
