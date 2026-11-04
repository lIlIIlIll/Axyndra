package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func canonicalProducerDataFrame204(owner:ToolCanonicalArgumentsOwner204, value:AgentValue):Unit {
    owner.installProducerData204(value)
}
private func canonicalProducerErrorFrame204(owner:ToolCanonicalArgumentsOwner204, error:AgentError):Unit {
    owner.installProducerError204(error)
}
private func canonicalOutcomeCopyFrame204(owner:ToolCanonicalArgumentsOwner204,
    payment:LogicalJsonOwnerReservation):Result<AgentValue> {
    owner.withOutcome204<Result<AgentValue>>({ result => match(result) {
        case Result.Ok(value) =>
            let meter = ToolSnapshotMeasure159(payment); meter.addValue159(value); meter.fund159()
            Result.Ok(copyJsonData204(value))
        case Result.Err(error) =>
            let meter = ToolSnapshotMeasure159(payment); meter.addText159(error.message); meter.addSlots159(error.fields.size)
            for(field in error.fields){meter.addText159(field.name);meter.addText159(field.value)}
            meter.fund159()
            Result.Err(AgentError(error.kind,copyTextData204(error.code),copyTextData204(error.message),
                fields:error.fields.map{field=>ErrorField(copyTextData204(field.name),copyTextData204(field.value))})) }
    })
}
private func canonicalVerifySuccessFrame204(owner:ToolCanonicalArgumentsOwner204,
    payment:LogicalJsonOwnerReservation):Unit {
    let copied = canonicalOutcomeCopyFrame204(owner,payment).value().getOrThrow()
    owner.withOutcome204({ source =>
        @Expect(refEq(source.value().getOrThrow(),copied),false)
        @Expect(copied.field("text").getOrThrow().text,"original")
        var rejected = false
        try { owner.returnCopiedConsumerFrame204() } catch(_:IllegalStateException){rejected=true}
        @Expect(rejected,true)
    })
}
private func canonicalVerifyErrorFrame204(owner:ToolCanonicalArgumentsOwner204,
    payment:LogicalJsonOwnerReservation):Unit {
    let copied = canonicalOutcomeCopyFrame204(owner,payment).error().getOrThrow()
    owner.withOutcome204({ source =>
        @Expect(refEq(source.error().getOrThrow(),copied),false)
        @Expect(copied.code,"fixture.business_failure"); @Expect(copied.message,"dynamic business detail")
        @Expect(copied.fields[0].name,"reason"); @Expect(copied.fields[0].value,"original field")
    })
}
private func canonicalRejectPendingFrame204(owner:ToolCanonicalArgumentsOwner204):Unit {
    owner.rejectCopiedProducerData204(AgentError(AgentErrorKind.InvalidInput,"fixture.business_failure","dynamic business detail",
        fields:[ErrorField("reason","original field")]))
}
private func canonicalRefusedProducerFrame204(owner:ToolCanonicalArgumentsOwner204):?Exception {
    try {
        owner.installProducerData204(objectValue([ValueField("large",textValue(String.fromUtf8(Array<Byte>(65536,repeat:b'x'))))]))
        None<Exception>
    } catch(error:Exception){Some(error)}
}

@Test
class CanonicalArgumentsOwner204Tests {
    @TestCase
    func independentSuccessWaitsForTheCompleteCopyConsumer():Unit {
        let bank=LogicalJsonOwnerBudget(maximumCharged:16777216);let root=bank.acquire(131072)
        let source=root.deriveRetainedLease();source.ensureRetainedPeak(131072)
        let owner=ToolCanonicalArgumentsOwner204(source)
        let original=objectValue([ValueField("text",textValue("original"))])
        canonicalProducerDataFrame204(owner,original);owner.producerFrameReturned204()
        original.put("text",textValue("changed"))
        let copied=root.deriveRetainedLease();copied.ensureRetainedPeak(131072)
        owner.requireSameBank204(copied);owner.beginConsumer204()
        canonicalVerifySuccessFrame204(owner,copied)
        @Expect(bank.usage()[1]>0,true)
        owner.returnCopiedConsumerFrame204()
        copied.close();root.close();@Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
    @TestCase
    func businessErrorFieldsHaveIndependentPaidBacking():Unit {
        let bank=LogicalJsonOwnerBudget(maximumCharged:16777216);let root=bank.acquire(131072)
        let source=root.deriveRetainedLease();source.ensureRetainedPeak(131072)
        let owner=ToolCanonicalArgumentsOwner204(source)
        let original=AgentError(AgentErrorKind.InvalidInput,"fixture.business_failure","dynamic business detail",
            fields:[ErrorField("reason","original field")])
        canonicalProducerErrorFrame204(owner,original)
        original.fields[0]=ErrorField("changed","changed field")
        owner.producerFrameReturned204()
        let copied=root.deriveRetainedLease();copied.ensureRetainedPeak(131072)
        owner.beginConsumer204();canonicalVerifyErrorFrame204(owner,copied)
        owner.returnCopiedConsumerFrame204();copied.close();root.close()
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
    @TestCase
    func onlyExactPrecopyBankRefusalMayCloseAfterProducerUnwinds():Unit {
        let bank=LogicalJsonOwnerBudget(maximumCharged:16777216);let root=bank.acquire(131072)
        let source=root.deriveRetainedLease();source.ensureRetainedPeak(131072)
        let owner=ToolCanonicalArgumentsOwner204(source)
        let pressure=root.deriveRetainedLease();pressure.ensureRetainedPeak(4096)
        let used=root.retainedCustodyUsage113()[0]
        pressure.ensureRetainedPeak(16777216-used-65536+4096)
        let error=canonicalRefusedProducerFrame204(owner).getOrThrow()
        @Expect(owner.closeUnacceptedProducer204(LogicalJsonPayloadError("different exception")),false)
        @Expect(owner.closeUnacceptedProducer204(error),true)
        pressure.close();root.close();@Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
    @TestCase
    func unknownTraversalFailureNeverAcknowledgesTheOriginalPayment():Unit {
        let bank=LogicalJsonOwnerBudget(maximumCharged:16777216);let root=bank.acquire(131072)
        let source=root.deriveRetainedLease();source.ensureRetainedPeak(131072)
        let owner=ToolCanonicalArgumentsOwner204(source)
        let cyclic=objectValue([]);cyclic.put("cycle",cyclic)
        var failure:?Exception=None<Exception>
        try{canonicalProducerDataFrame204(owner,cyclic)}catch(error:Exception){failure=Some(error)}
        @Expect(failure.isSome(),true)
        @Expect(owner.closeUnacceptedProducer204(failure.getOrThrow()),false)
        root.close();@Expect(bank.usage()[1]>0,true)
    }
    @TestCase
    func finalProducerRecheckCanRejectCopiedSuccessWithoutRefundingItsPeak():Unit {
        let bank=LogicalJsonOwnerBudget(maximumCharged:16777216);let root=bank.acquire(131072)
        let source=root.deriveRetainedLease();source.ensureRetainedPeak(131072)
        let owner=ToolCanonicalArgumentsOwner204(source)
        canonicalProducerDataFrame204(owner,objectValue([ValueField("text",textValue("copied success"))]))
        let before=bank.usage()[1]
        canonicalRejectPendingFrame204(owner)
        @Expect(bank.usage()[1]>=before,true)
        owner.producerFrameReturned204()
        let copied=root.deriveRetainedLease();copied.ensureRetainedPeak(131072)
        owner.beginConsumer204();canonicalVerifyErrorFrame204(owner,copied)
        owner.returnCopiedConsumerFrame204();copied.close();root.close()
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }

}
