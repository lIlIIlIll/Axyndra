package agent_app

import agent_domain.*
import yjson.*
import yjson_support.*
import agent_product.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// Transport DATA fixtures only; no Source, authorization or Run is minted.
private func ownerFailurePacket204(version!: Int64 = 1, ok!: Bool = false,
    requestId!: String = "frontend-fixture", attachments!: Bool = true,
    observationGrants!: Bool = false): AgentValue {
    let fields = ArrayList<ValueField>([
        ValueField("kind", textValue("recovery_required")),
        ValueField("code", textValue("owner.acp_frontend_close_pending")),
        ValueField("message", textValue("original frontend cleanup remains pending")),
        ValueField("retryable", boolValue(false)), ValueField("fallback_allowed", boolValue(false)),
        ValueField("fields", listValue([objectValue([ValueField("name", textValue("stage")),
            ValueField("value", textValue("frontend_cleanup"))])]))])
    if (attachments) {
        fields.add(ValueField("attempt_failure", nullValue()))
        fields.add(ValueField("observation", objectValue([
            ValueField("schema", textValue("axyndra.operation-observation/v1")),
            ValueField("trust", textValue("untrusted_data")),
            ValueField("authorizes_effects", boolValue(observationGrants)),
            ValueField("content", objectValue([ValueField("detail", textValue("完整诊断"))]))])))
    }
    objectValue([ValueField("version", integerValue(version)), ValueField("requestId", textValue(requestId)),
        ValueField("ok", boolValue(ok)), ValueField("error", objectValue(fields.toArray()))])
}

@Test
class OwnerFrontendFailure204Tests {
    @TestCase
    func originalCleanupFailurePreservesCodeFieldsAndUntrustedObservation(): Unit {
        let result = decodeProductOwnerFrontendFailure180(ownerFailurePacket204())
        @Expect(result.isOk(), true)
        let error = result.value().getOrThrow()
        @Expect(error.kind, AgentErrorKind.RecoveryRequired)
        @Expect(error.code, "owner.acp_frontend_close_pending")
        @Expect(error.message, "original frontend cleanup remains pending")
        @Expect(error.retryable, false); @Expect(error.fallbackAllowed, false)
        @Expect(error.fields.size, 1); @Expect(error.field("stage").getOrThrow(), "frontend_cleanup")
        @Expect(error.attemptFailure.isNone(), true)
        let observed = error.observation.getOrThrow().toValue()
        @Expect(observed.field("authorizes_effects").getOrThrow().asBool(), false)
        @Expect(observed.field("content").getOrThrow().field("detail").getOrThrow().text, "完整诊断")
    }
    @TestCase
    func changedOuterEnvelopeCannotBecomeAnOwnerFailure(): Unit {
        for (packet in [ownerFailurePacket204(version: 2), ownerFailurePacket204(ok: true),
            ownerFailurePacket204(requestId: ""), ownerFailurePacket204(requestId: String.fromUtf8(Array<Byte>(257, repeat: b'x')))]) {
            let result = decodeProductOwnerFrontendFailure180(packet)
            @Expect(result.isError(), true)
            @Expect(result.error().getOrThrow().code, "owner.frontend_error_invalid")
        }
        @Expect(decodeProductOwnerFrontendFailure180(nullValue()).isError(), true)
    }
    @TestCase
    func missingAttachmentsAndObservationAuthorityAreRefused(): Unit {
        @Expect(decodeProductOwnerFrontendFailure180(ownerFailurePacket204(attachments: false)).isError(), true)
        @Expect(decodeProductOwnerFrontendFailure180(ownerFailurePacket204(observationGrants: true)).isError(), true)
    }
}
