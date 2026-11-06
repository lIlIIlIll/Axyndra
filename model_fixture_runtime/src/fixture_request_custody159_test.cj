package model_fixture_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These are actual DATA allocations; the funding/loan objects carry no Run,
// Tool, Source, permission or physical task-return evidence.
private class FixtureRequestFunding159 <: ModelInputDataBudget159 {
    private let original: LogicalJsonOwnerReservation
    init(original: LogicalJsonOwnerReservation) { this.original = original }
    public func reserveRetainedModelMetadata159(bytes: Int64): LogicalJsonOwnerReservation {
        let paid = original.deriveRetainedLease()
        try { paid.ensureRetainedPeak(bytes); paid }
        catch (error: Exception) { paid.close(); throw error }
    }
}
private class FixtureTranscriptLoan159 <: ModelInputToolsBorrow159 {
    private let payment: LogicalJsonOwnerReservation
    var returned = false
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
    public func returnModelToolsFrame159(): Unit { returned = true; payment.close() }
}
private class FixtureObservedView159 { var value: ?FixtureRequestObservation159 = None<FixtureRequestObservation159> }
private class FixtureReentry159 { var entered = false }

private func executeFixtureOwnedFrame159(port: FixtureModelPort, funding: ModelInputDataBudget159,
    text: String): Unit {
    let input = ModelRequest("fixture", [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: text)])],
        system: "independently paid system", tools: [ModelToolDefinition("fixture.only", "description",
            objectValue([ValueField("type", textValue("object"))]))], requestId: "fixture-paid-request",
        transportHardTimeoutMillis: 37)
    @Expect(match (port.executeReturningInput159(input, { _ => () }, funding)) {
        case ModelInputReturn159.Returned(value) => value.isOk()
        case _ => false }, true)
}

@Test
class FixtureRequestCustody159Tests {
    @TestCase
    func prefixObservationReturnsNoRequestAliasAndRevokesAtCallbackReturn(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 33554432)
        let source = bank.acquire(131072)
        let funding = FixtureRequestFunding159(source)
        let port = FixtureModelPort(); let observed = FixtureObservedView159()
        executeFixtureOwnedFrame159(port, funding, "[checkpoint] retained suffix")
        @Expect(port.withLastRequest159({ view =>
            observed.value = Some(view)
            view.firstMessageTextStartsWith159("[checkpoint]") &&
                !view.firstMessageTextStartsWith159("[foreign]") }), true)
        @Expect(observed.value.getOrThrow().firstMessageTextStartsWith159("[checkpoint]"), false)
        let histories: Array<Array<ModelMessage>> = [[], [ModelMessage(ModelRole.User, [])],
            [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "")])]]
        for (messages in histories) {
            let result = port.executeReturningInput159(ModelRequest("fixture", messages), { _ => () }, funding)
            @Expect(match (result) { case ModelInputReturn159.Returned(value) => value.isOk(); case _ => false }, true)
            @Expect(port.withLastRequest159({ view => view.firstMessageTextStartsWith159("[checkpoint]") }), false)
        }
        port.retireLastRequest159(); source.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func approvedGlobReplyKeepsTheAdvertisedFrontendArgumentShape(): Unit {
        for ((name, advertisesBinding) in [("plugin.axyndra:workspace.glob", false),
            ("plugin.axyndra:workspace.glob", true), ("glob", true), ("glob", false)]) {
            let properties = objectValue([
                ValueField("pattern", objectValue([ValueField("type", textValue("string"))])),
                ValueField("limit", objectValue([ValueField("type", textValue("integer"))]))
            ])
            if (advertisesBinding) { properties.put("_plan", objectValue([])) }
            let schema = objectValue([ValueField("type", textValue("object")),
                ValueField("properties", properties), ValueField("additionalProperties", boolValue(false))])
            let request = ModelRequest("fixture", [ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "[plan-review approved hash=fixture]\nfixture-inspect")
            ])], tools: [ModelToolDefinition(name, "advertised glob frontend", schema)])
            let reply = FixtureModelPort().execute(request, { _ => () }).value().getOrThrow()
            @Expect(reply.blocks.size, 1)
            @Expect(reply.blocks[0].kind, ModelBlockKind.ToolCall)
            @Expect(reply.blocks[0].name, name)
            let arguments = reply.blocks[0].arguments
            @Expect(arguments.field("pattern").getOrThrow().text, "**/*")
            @Expect(arguments.field("limit").getOrThrow().asInt64(), 1)
            let explicitBinding = name == "glob" || advertisesBinding
            @Expect(arguments.asObject().size(), if (explicitBinding) { 3 } else { 2 })
            @Expect(arguments.field("_plan").isSome(), explicitBinding)
            if (explicitBinding) {
                let binding = arguments.field("_plan").getOrThrow()
                @Expect(binding.field("step_id").getOrThrow().text, "fixture-inspect")
                @Expect(binding.field("action_id").getOrThrow().text, "fixture-glob")
            }
            @Expect(schema.field("properties").getOrThrow().field("_plan").isSome(), advertisesBinding)
        }
    }

    @TestCase
    func preExecuteCapacityRefusalReturnsInputAndRetiresPartialCopy(): Unit {
        // Initial lease refusal and refusal after constructing earlier copy
        // fields both use the actual original-bank concurrent SUM limit.
        for (remaining in [Int64(32768), Int64(131072)]) {
            let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
            let source = bank.acquire(131072)
            source.ensureRetainedPeak(16777216 - remaining)
            let port = FixtureModelPort()
            let input = ModelRequest("fixture", [ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: String.fromUtf8(Array<Byte>(32768, repeat: b'x')))
            ])], streaming: true)
            let result = port.executeReturningInput159(input,
                { _ => throw IllegalStateException("pre-execute refusal must not call events") },
                FixtureRequestFunding159(source))
            @Expect(match (result) {
                case ModelInputReturn159.Returned(value) => match (value) {
                    case Result.Err(error) => error.kind == AgentErrorKind.BudgetExceeded &&
                        error.code == "fixture.input_copy_capacity"
                    case _ => false }
                case _ => false }, true)
            @Expect(port.observedCallCount11318(), 0)
            @Expect(port.withLastRequest159({ view => view.hasRequest159() }), false)
            @Expect(source.retainedCustodyUsage113()[2], 1)
            // No abandoned partial snapshot remains on the original ledger.
            let next = source.deriveRetainedLease()
            next.ensureRetainedPeak(512); next.close(); source.close()
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        }
    }

    @TestCase
    func replacementDuringActualProducerCallbackKeepsBothIndependentCopiesPaid(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(131072)
        let funding = FixtureRequestFunding159(source)
        let port = FixtureModelPort(); let nested = FixtureReentry159()
        let result = port.executeReturningInput159(ModelRequest("fixture", [], streaming: true), { _ =>
            if (!nested.entered) {
                nested.entered = true
                let before = source.retainedCustodyUsage113()[0]
                executeFixtureOwnedFrame159(port, funding, "overlapping request")
                // The outer complete execute/callback frame has NOT returned.
                // Source + both copies + the outer active producer lease.
                @Expect(source.retainedCustodyUsage113()[2], 4)
                @Expect(source.retainedCustodyUsage113()[0] > before, true)
                @Expect(bank.usage()[0], 1)
            }
        }, funding)
        @Expect(match (result) { case ModelInputReturn159.Returned(value) => value.isOk(); case _ => false }, true)
        @Expect(nested.entered, true)
        @Expect(source.retainedCustodyUsage113()[2], 2)
        @Expect(bank.usage()[0], 1)
        port.retireLastRequest159(); source.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func unexportedCopiesReplaceAndClosedScalarObservationReallyRetires(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(131072)
        let funding = FixtureRequestFunding159(source)
        let port = FixtureModelPort()
        let saved = FixtureObservedView159()
        let initialCharge = bank.usage()[1]
        for (index in 0..12) {
            executeFixtureOwnedFrame159(port, funding, "copy-" + index.toString())
            @Expect(port.withLastRequest159({ view =>
                saved.value = Some(view)
                view.hasRequest159() && view.systemContains159("independently paid") && view.hasOnlyTool159("fixture.only")
            }), true)
            @Expect(saved.value.getOrThrow().hasRequest159(), false)
            @Expect(saved.value.getOrThrow().systemContains159("paid"), false)
            // One source and only the current copy lease share their actual
            // original slot/floor; no artificial transport frame was added.
            @Expect(source.retainedCustodyUsage113()[2], 2)
            @Expect(bank.usage()[0], 1)
            @Expect(bank.usage()[1], initialCharge)
        }
        port.retireLastRequest159()
        @Expect(bank.usage()[0], 1)
        source.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func rawExportHasItsOwnDeepCopyAndNeverRefundsOnReplacement(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(131072)
        let funding = FixtureRequestFunding159(source)
        let port = FixtureModelPort()
        let schema = objectValue([ValueField("original", textValue("source value 雪"))])
        let input = ModelRequest("fixture", [], system: "original system",
            tools: [ModelToolDefinition("fixture.schema", "description", schema)],
            requestId: "original-request", transportHardTimeoutMillis: 37)
        @Expect(match (port.executeReturningInput159(input, { _ => () }, funding)) {
            case ModelInputReturn159.Returned(value) => value.isOk(); case _ => false }, true)
        let exported = port.lastRequest.getOrThrow()
        schema.put("original", textValue("changed input"))
        @Expect(exported.tools[0].inputSchema.field("original").getOrThrow().text, "source value 雪")
        @Expect(exported.requestId, "original-request")
        @Expect(exported.transportHardTimeoutMillis, 37)
        @Expect(exported.inputToolsLifetime159.isNone(), true)
        executeFixtureOwnedFrame159(port, funding, "replacement")
        port.retireLastRequest159(); source.close()
        @Expect(exported.system, "original system")
        @Expect(bank.usage()[0], 1)
        @Expect(bank.usage()[1] > 0, true)
    }

    @TestCase
    func transcriptReturnsOnlyTheLoanOfItsCompleteActualCodecFrame(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(131072)
        let loan = FixtureTranscriptLoan159(source.deriveRetainedLease())
        let input = ModelRequest("fixture", [], requestId: "transcript-input")
        let snapshot = FixtureModelPort().transcriptSnapshotReturning159(input, loan)
        @Expect(snapshot.isSome(), true)
        @Expect(loan.returned, true)
        @Expect(snapshot.getOrThrow().contains("transcript-input"), true)
        source.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func unexpectedEventConsumerExceptionCannotReportReturnedInput(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(131072)
        let port = FixtureModelPort()
        var threw = false
        try {
            let _ = port.executeReturningInput159(ModelRequest("fixture", [], streaming: true),
                { _ => throw IllegalStateException("actual event consumer failed") }, FixtureRequestFunding159(source))
        } catch (_: IllegalStateException) { threw = true }
        @Expect(threw, true)
        // This independent observation never borrowed the failed input.
        // Core's separate unknown-input debt remains Core's responsibility.
        port.retireLastRequest159(); source.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func allocationExceptionFromActualEventCannotMasqueradeAsCopyRefusal(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(131072)
        let port = FixtureModelPort()
        var threw = false
        try {
            let _ = port.executeReturningInput159(ModelRequest("fixture", [], streaming: true),
                { _ => throw LogicalJsonPayloadError("actual event allocation failed") }, FixtureRequestFunding159(source))
        } catch (_: LogicalJsonPayloadError) { threw = true }
        @Expect(threw, true)
        @Expect(port.observedCallCount11318(), 1)
        port.retireLastRequest159(); source.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}
