package agent_product

import agent_domain.*
import agent_store.*
import agent_extension_runtime.reserveNativeControlMetadata
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func observationEnvelope201(facts: AgentValue, op!: String = "ps",
    schema!: String = "axyndra.hub-process-observation/v1"): AgentValue {
    objectValue([ValueField("schema", textValue(schema)), ValueField("op", textValue(op)),
        ValueField("facts", facts)])
}

private func observationFacts201(daemons: AgentValue, warnings: AgentValue): AgentValue {
    objectValue([ValueField("daemons", daemons), ValueField("recovery_warnings", warnings)])
}

private func requireCompleteObservationMergeFrame201(): Unit {
    // The caller reserved the real shared bank before creating any test DATA.
    let localDaemon = objectValue([ValueField("name", textValue("local 雪")),
        ValueField("pid", integerValue(17)), ValueField("state", textValue("running")),
        ValueField("nested", objectValue([ValueField("token", textValue("keep\u{0}whole"))]))])
    let remoteDaemon = objectValue([ValueField("name", textValue("remote")),
        ValueField("pid", integerValue(29)), ValueField("state", textValue("exited"))])
    let local = ToolResult("local", observationEnvelope201(observationFacts201(
        listValue([localDaemon]), listValue([textValue("local warning\n雪"), textValue("same")]))))
    let remote = ToolResult("remote", observationEnvelope201(observationFacts201(
        listValue([remoteDaemon]), listValue([textValue("same"), textValue("remote\u{0}warning")]))),
        isError: true)
    let actual = match (mergeProcessObservations201("actual-call", local, remote)) {
        case Result.Err(error) => throw IllegalStateException(error.message)
        case Result.Ok(value) => value
    }
    let expected = observationEnvelope201(observationFacts201(listValue([localDaemon, remoteDaemon]),
        listValue([textValue("local warning\n雪"), textValue("same"), textValue("same"),
            textValue("remote\u{0}warning")])))
    @Expect(actual.callId, "actual-call")
    @Expect(actual.isError)
    @Expect(encodeStoredValue(actual.output), encodeStoredValue(expected))
    @Expect(httpIntentExactFields(actual.output, ["schema", "op", "facts"]))
    @Expect(httpIntentExactFields(actual.output.field("facts").getOrThrow(), ["daemons", "recovery_warnings"]))
    let empty = ToolResult("empty", observationEnvelope201(observationFacts201(listValue([]), listValue([]))))
    let emptyResult = match (mergeProcessObservations201("empty-call", empty, empty)) {
        case Result.Err(error) => throw IllegalStateException(error.message)
        case Result.Ok(value) => value
    }
    @Expect(!emptyResult.isError)
    @Expect(encodeStoredValue(emptyResult.output), encodeStoredValue(empty.output))
}

private func requireMalformedObservationRejectedFrame201(): Unit {
    let facts = observationFacts201(listValue([]), listValue([]))
    let valid = ToolResult("valid", observationEnvelope201(facts))
    let malformed: Array<AgentValue> = [
        objectValue([ValueField("op", textValue("ps")), ValueField("daemons", listValue([]))]),
        observationEnvelope201(facts, op: "logs"),
        observationEnvelope201(facts, schema: "other"),
        observationEnvelope201(objectValue([ValueField("daemons", listValue([]))])),
        observationEnvelope201(observationFacts201(nullValue(), listValue([]))),
        observationEnvelope201(observationFacts201(listValue([]), textValue("not a list"))),
        observationEnvelope201(observationFacts201(listValue([]), listValue([integerValue(1)]))),
        objectValue([ValueField("schema", textValue("axyndra.hub-process-observation/v1")),
            ValueField("op", textValue("ps")), ValueField("facts", facts), ValueField("extra", nullValue())])
    ]
    for (value in malformed) {
        let bad = ToolResult("bad", value)
        for (reverse in [false, true]) {
            let result = if (reverse) { mergeProcessObservations201("bad-call", valid, bad) }
                else { mergeProcessObservations201("bad-call", bad, valid) }
            match (result) {
                case Result.Ok(_) => @Expect(false)
                case Result.Err(error) => @Expect(error.code, "hub.process_list_invalid")
            }
        }
    }
}

@Test
class ProcessObservationMerge201Tests {
    @TestCase
    func completeLocalAndRemoteFactsWarningsAndErrorFlagArePreserved(): Unit {
        let payment = reserveNativeControlMetadata(8388608)
        try { requireCompleteObservationMergeFrame201() } finally { payment.close() }
    }

    @TestCase
    func eitherMalformedEnvelopeFailsBeforePublishingMergedFacts(): Unit {
        let payment = reserveNativeControlMetadata(8388608)
        try { requireMalformedObservationRejectedFrame201() } finally { payment.close() }
    }
}
