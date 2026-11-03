package agent_store

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Local original 128 MiB / 32-slot bank; no Native global fixture bank, Source,
// completed fact, SQL transaction or execution permission is manufactured.
private class PreparedNumericFixture204 <: PreparedPlanUtf8Owner204 {
    private let payment: LogicalJsonOwnerReservation
    private var bytes: ?Array<UInt8>
    private let expectedDigest: String
    init(payment: LogicalJsonOwnerReservation, bytes: Array<UInt8>, expectedDigest: String) {
        this.payment = payment; this.bytes = Some(bytes); this.expectedDigest = expectedDigest
    }
    func matchesDurableDigest204(actual: String): Bool { expectedDigest == actual }
    public prop byteCount: Int64 { get() { bytes.getOrThrow().size } }
    public func byteAt(index: Int64): UInt8 { bytes.getOrThrow()[index] }
    public func deriveCopiedPlanPayment204(invoice: Int64): LogicalJsonOwnerReservation {
        let child = payment.deriveRetainedLease()
        try { child.ensureRetainedPeak(invoice); child }
        catch (error: Exception) { child.close(); throw error }
    }
    func revokeBytes204(): Unit {
        match (bytes) { case Some(value) =>
            for (index in 0..value.size) { value[index] = UInt8(0) }
            case None => () }
        bytes = None<Array<UInt8>>
    }
}

private func receiverMetadataPlan204(): NormalizedOperationPlan {
    let digest = modelPolicySha256Text("copied metadata only")
    let origin = ContextReadOrigin("axyndra:missing", "sha256:" + digest,
        digest, digest, digest, "missing-request", "")
    let reference = ContextReadFactLink(OperationId("missing-operation"), RunId("missing-run"),
        ItemId("missing-source"), ItemId("missing-result"), "missing-receipt", origin, digest, 7)
    NormalizedOperationPlan("fixture.copy", objectValue([
        ValueField("unicode", textValue("λ中")), ValueField("flag", boolValue(true)),
        ValueField("items", listValue([integerValue(7), nullValue(), textValue("value")]))]),
        [Capability(CapabilityKind.WorkspaceWrite, resource: "/tmp/fixture.txt"),
         Capability(CapabilityKind.NetworkAccess, resource: "example.invalid:443")],
        OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.ByIdempotencyKey, digest,
        resolvedPaths: ["/tmp/fixture.txt", "/tmp/second"], resolvedHosts: ["example.invalid"],
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Mediated,
            egress: [NetworkEgressRule("example.invalid", 443u16, privateAddresses: ["10.1.2.3"])],
            publish: [NetworkPublishRule(8123u16, 8124u16)])), cwd: "/tmp",
        relevantEnvironment: [ValueField("LANG", textValue("C.UTF-8")), ValueField("COUNT", integerValue(3))],
        approvalMetadata: Some(ToolApprovalMetadata("fixture write", RiskAssessment(ApprovalRiskLevel.High,
            flags: ["one", "two"], reasons: ["complete metadata"]),
            ApprovalGrantScope("workspace.write", pathPrefix: "/tmp", toolName: "fixture.copy",
                host: "example.invalid", sessionOnly: false),
            writeSummary: Some(WriteApprovalSummary("/tmp/fixture.txt", "replace", true, 21, 2,
                language: "text", preview: ["λ", "second"], truncated: true, contentHash: digest,
                beforeBytes: 19, addedLines: 2, removedLines: 1)), sessionApprovalAllowed: false)),
        idempotencyKey: "copy-key", replayDisposition: Some(ReplayDisposition.Idempotent("copy-key")),
        toolVersion: "fixture-v2", implementationFingerprint: "fixture-implementation",
        schemaDigest: "fixture-schema", effectiveArgumentsDigest: "fixture-arguments",
        replayContractVersion: 1u32, contextReadFacts: [reference])
}

private func receiverSummaryValue204(summary: WriteApprovalSummary): AgentValue {
    objectValue([
        ValueField("path", textValue(summary.path)), ValueField("action", textValue(summary.action)),
        ValueField("exists", boolValue(summary.exists)), ValueField("bytes", integerValue(summary.bytes)),
        ValueField("lines", integerValue(summary.lines)), ValueField("language", textValue(summary.language)),
        ValueField("preview", stringValues(summary.preview)), ValueField("truncated", boolValue(summary.truncated)),
        ValueField("content_hash", textValue(summary.contentHash)), ValueField("before_bytes", integerValue(summary.beforeBytes)),
        ValueField("added_lines", integerValue(summary.addedLines)), ValueField("removed_lines", integerValue(summary.removedLines))])
}

// The producer returns only an independently paid byte/digest carrier. Its
// original Plan, codec DOM and framed text all leave the stack before payment
// for that producer phase is returned and the receiver phase begins.
private func receiverProduceFrame204(producer: LogicalJsonOwnerReservation,
    sender: LogicalJsonOwnerReservation, complete: Bool): PreparedNumericFixture204 {
    let original = if (complete) { receiverMetadataPlan204() } else {
        NormalizedOperationPlan("fixture.read", objectValue(), [],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "legacy-digest") }
    let invoice = HubProcessPlanInvoice180({ size => producer.ensureRetainedPeak(size) })
    invoice.includePlan(original); producer.ensureRetainedPeak(invoice.retainedPeak())
    let value = storedOperationPlanValue(original)
    if (complete) {
        value.put("write_summary204", receiverSummaryValue204(original.approvalMetadata.writeSummary.getOrThrow()))
    }
    let encoded = encodeStoredValue(value)
    sender.ensureRetainedPeak(131072 + encoded.size * 4 + 64 * 8)
    PreparedNumericFixture204(sender, encoded.toArray(), modelPolicySha256Text(encodeOperationPlan(original)))
}

// Only Bool escapes this helper. The numeric source is revoked after the
// independent receiver buffer is paid and copied, before that buffer is decoded.
private func receiverConsumeFrame204(source: PreparedNumericFixture204,
    receiver: LogicalJsonOwnerReservation, complete: Bool): Bool {
    let size = source.byteCount
    receiver.ensureRetainedPeak(131072 + size * 4)
    let copied = Array<UInt8>(size, { index => source.byteAt(index) })
    let peak = preparedFramedValueCopyPeak204(copied)
    receiver.ensureRetainedPeak(peak)
    source.revokeBytes204()
    var refusedCount = false; var refusedByte = false
    try { let _ = source.byteCount } catch (_: Exception) { refusedCount = true }
    try { let _ = source.byteAt(0) } catch (_: Exception) { refusedByte = true }
    let decoded = decodePreparedOperationPlan204(String.fromUtf8(copied))
    let comparison = HubProcessPlanInvoice180({ amount => receiver.ensureRetainedPeak(peak + amount) })
    comparison.includePlan(decoded); receiver.ensureRetainedPeak(peak + comparison.retainedPeak())
    // The golden hash covers every original durable field and its ordering.
    if (!refusedCount || !refusedByte ||
        !source.matchesDurableDigest204(modelPolicySha256Text(encodeOperationPlan(decoded)))) { return false }
    if (!complete) {
        return decoded.approvalMetadata.writeSummary.isNone() && decoded.approvalMetadata.sessionApprovalAllowed &&
            decoded.implementation.toolVersion == "legacy-v1" && decoded.implementation.replayContractVersion == 1u32
    }
    if (decoded.contextReadFactCount180() != 1 || decoded.approvalMetadata.sessionApprovalAllowed ||
        decoded.approvalMetadata.writeSummary.isNone()) { return false }
    let b = decoded.approvalMetadata.writeSummary.getOrThrow()
    b.path == "/tmp/fixture.txt" && b.action == "replace" && b.exists && b.bytes == 21 &&
        b.lines == 2 && b.language == "text" && b.preview.size == 2 && b.preview[0] == "λ" &&
        b.preview[1] == "second" && b.truncated && b.contentHash == modelPolicySha256Text("copied metadata only") &&
        b.beforeBytes == 19 && b.addedLines == 2 && b.removedLines == 1 && receiver.retainedCustodyUsage113()[0] > 0
}

private func receiverPhasedCopyFrame204(root: LogicalJsonOwnerReservation, sender: LogicalJsonOwnerReservation, complete: Bool): Bool {
    let producer = root.deriveRetainedLease(); producer.ensureRetainedPeak(131072)
    let source = receiverProduceFrame204(producer, sender, complete)
    producer.close()
    let receiver = root.deriveRetainedLease(); receiver.ensureRetainedPeak(131072)
    let valid = receiverConsumeFrame204(source, receiver, complete)
    receiver.close()
    // The source is still paid here: this frame holds its digest and empty
    // shell. Return its payment to the caller, after this whole frame returns.
    receiverFinishSourceFrame204(source)
    valid
}

private func receiverFinishSourceFrame204(source: PreparedNumericFixture204): Unit {
    source.revokeBytes204()
}

private func receiverMalformedFrame204(payment: LogicalJsonOwnerReservation): Bool {
    // The numeric preflight counts these valid frames. It must not replace
    // the original UTF8 or duplicate-name checks performed by the real parser.
    let duplicate = "o1:21:an1:an".toArray()
    let invalidUtf8: Array<UInt8> = [b'o', b'1', b':', b'1', b'1', b':', UInt8(255), b'n']
    let first = preparedFramedValueCopyPeak204(duplicate)
    let second = preparedFramedValueCopyPeak204(invalidUtf8)
    payment.ensureRetainedPeak(first + second)
    var rejectedDuplicate = false; var rejectedUtf8 = false
    try { let _ = decodePreparedOperationPlan204(String.fromUtf8(duplicate)) }
    catch (error: Exception) { rejectedDuplicate = error.message == "stored object has duplicate field: a" }
    try { let _ = decodeStoredValue(String.fromUtf8(invalidUtf8)) }
    catch (_: Exception) { rejectedUtf8 = true }
    rejectedDuplicate && rejectedUtf8
}

@Test
class PreparedPlanCopiedData204Tests {
    @TestCase
    func CompleteMetadataSurvivesSenderRevocationAndWholeHelperReturnsBothChildren(): Unit {
        let bank = LogicalJsonOwnerBudget()
        for (_ in 0..32) {
            let root = bank.acquire(1)
            let sender = root.deriveRetainedLease(); sender.ensureRetainedPeak(131072)
            let valid = receiverPhasedCopyFrame204(root, sender, true)
            // Whole known local frame returned; no Plan, String or Array was
            // exported to these caller frames or to any unknown consumer.
            sender.close(); root.close()
            @Expect(valid, true)
            @Expect(bank.usage()[0], 0)
            @Expect(bank.usage()[1], 0)
        }
    }
    @TestCase
    func OriginalDefaultsAndMalformedUtf8DuplicateChecksRemainClosed(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let root = bank.acquire(1)
        let defaults = root.deriveRetainedLease(); defaults.ensureRetainedPeak(131072)
        let valid = receiverPhasedCopyFrame204(root, defaults, false)
        defaults.close()
        let malformed = root.deriveRetainedLease(); malformed.ensureRetainedPeak(131072)
        let rejected = receiverMalformedFrame204(malformed)
        malformed.close(); root.close()
        @Expect(valid, true)
        @Expect(rejected, true)
        @Expect(bank.usage()[0], 0)
        @Expect(bank.usage()[1], 0)
    }
}
