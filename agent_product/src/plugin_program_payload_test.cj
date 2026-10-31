package agent_product

import agent_domain.*
import agent_ports.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func programPayloadGrant(fixture: ProgramDelegationFixture, contribution!: String = "run", maximumInput!: Int64 = 2097152): Unit {
    let path = fixture.root + "/settings/plugins/services.json"
    let value = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
    let limits = OrdinaryToolPayloadLimits(contribution, maxInputBytes: maximumInput)
    for (item in value.field("plugins").getOrThrow().items where httpIntentText(item, "namespace") == productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))) {
        item.put("tool_payload_limits", listValue([limits.value()]))
    }
    File.writeTo(path, stringifyUnifiedJson(value).toArray())
}

@Test
class PluginProgramPayloadTests {
    @TestCase
    func payloadHandshakeSelectionRequiresExactCurrentOperatorToolAndReadyDeclaration(): Unit {
        let f = ProgramDelegationFixture()
        try {
            let descriptor = f.record.descriptor
            let settings = f.root + "/settings"
            let limits = Some(OrdinaryToolPayloadLimits("run"))
            @Expect(productOrdinaryToolPayloadSelection("missing-settings", descriptor, ["run"], "tool", "run", None).value().getOrThrow(), "")
            @Expect(productOrdinaryToolPayloadSelection(settings, descriptor, ["run"], "tool", "run", limits).isError())
            programPayloadGrant(f)
            let selected = lifecycleTestRequire(productOrdinaryToolPayloadSelection(settings, descriptor, ["run"], "tool", "run", limits))
            @Expect(selected != "")
            for (kind in ["service", "service_prepare", "model_provider", "context_provider", "prepare"]) {
                @Expect(productOrdinaryToolPayloadSelection(settings, descriptor, ["run"], kind, "run", limits).isError()) }
            @Expect(productOrdinaryToolPayloadSelection(settings, descriptor, [], "tool", "run", limits).isError())
            @Expect(productOrdinaryToolPayloadSelection(settings, descriptor, ["run"], "tool", "other", limits).isError())
            programPayloadGrant(f, maximumInput: 2000000)
            @Expect(productOrdinaryToolPayloadSelection(settings, descriptor, ["run"], "tool", "run", limits).isError())
            let changed = lifecycleTestRequire(productOrdinaryToolPayloadSelection(settings, descriptor, ["run"], "tool", "run",
                Some(OrdinaryToolPayloadLimits("run", maxInputBytes: 2000000))))
            @Expect(changed != selected)
        } finally { f.close() }
    }
    @TestCase
    func existingUnprofiledWorkerCannotSuppressNewExactProfileNegotiation(): Unit {
        let f = ProgramDelegationFixture()
        try {
            let first = f.completed(f.direct("program-profile-transition", f.input(code: "return 1;"), ExecutionBudget(maxToolCalls: 1)))
            try { @Expect(!first.isError); @Expect(first.payloadLease.isNone()) } finally { first.releasePayload() }
            programPayloadGrant(f)
            let code = String.fromUtf8(Array<Byte>(262135, repeat: 32)) + "return 2;"
            let second = f.completed(f.direct("program-profile-transition", f.input(code: code), ExecutionBudget(maxToolCalls: 1)))
            try { @Expect(!second.isError); @Expect(second.payloadLease.isSome()); @Expect(second.output.field("value").getOrThrow().asNumberText(), "2") }
            finally { second.releasePayload() }
            @Expect(f.count("program-profile-transition", "SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed'"), 2)
        } finally { f.close() }
    }
    @TestCase
    func actualDirect256KiBRawSourceKeepsResultOwnerThroughCanonicalReceipt(): Unit {
        let f = ProgramDelegationFixture()
        try {
            programPayloadGrant(f)
            let code = String.fromUtf8(Array<Byte>(262135, repeat: 32)) + "return 1;"
            @Expect(code.size, 262144)
            let result = f.completed(f.direct("program-logical-input", f.input(code: code), ExecutionBudget(maxToolCalls: 1)))
            try {
                @Expect(!result.isError); @Expect(result.output.field("value").getOrThrow().asNumberText(), "1")
                @Expect(result.payloadLease.isSome())
                @Expect(f.count("program-logical-input", "SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed'"), 1)
                @Expect(f.children("program-logical-input"), 0)
            } finally { result.releasePayload() }
            // The same Thread may invoke again after the first public consumer
            // has released its allocation ownership.
            let second = f.completed(f.direct("program-logical-input", f.input(code: "return 2;"), ExecutionBudget(maxToolCalls: 1)))
            try { @Expect(!second.isError) } finally { second.releasePayload() }
        } finally { f.close() }
    }
    @TestCase
    func actualCommittedPrepareCarriesLargeSourceButChangedProfileCannotExecuteOldApproval(): Unit {
        for (change in [false, true]) {
            let f = ProgramDelegationFixture(mode: ApprovalMode.Write)
            try {
                programPayloadGrant(f)
                let thread = if (change) { "program-logical-stale" } else { "program-logical-approved" }
                let code = String.fromUtf8(Array<Byte>(262135, repeat: 32)) + "return 1;"
                let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
                f.product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, f.name, f.input(code: code))
                @Expect(session.submit("Review this exact large ordinary Tool input.").isOk())
                let pending = session.approval().getOrThrow(); @Expect(pending.toolName, f.name)
                @Expect(f.count(thread, "SELECT COUNT(*) FROM audit_events a JOIN operations o ON o.id=a.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND a.kind='operation_execution_handoff'"), 0)
                if (change) { programPayloadGrant(f, maximumInput: 2000000) }
                let outcome = session.decide(pending.operationId.value, ApprovalDecision.Approve)
                if (!change) { @Expect(outcome.isOk()) }
                @Expect(f.count(thread, "SELECT COUNT(*) FROM audit_events a JOIN operations o ON o.id=a.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND a.kind='operation_execution_handoff'"), if (change) { 0 } else { 1 })
                @Expect(f.children(thread), 0)
            } finally { f.close() }
        }
    }
    @TestCase
    func exactOtherContributionProfileDoesNotExpandThisToolAndRawLimitStillApplies(): Unit {
        let f = ProgramDelegationFixture()
        try {
            programPayloadGrant(f, contribution: "another")
            let large = f.input(code: String.fromUtf8(Array<Byte>(262144, repeat: 0)))
            let denied = f.direct("program-profile-wrong", large, ExecutionBudget(maxToolCalls: 1))
            try { @Expect(managedRejected(denied)) } finally { releaseToolInvocationPayload(denied) }
            @Expect(f.count("program-profile-wrong", "SELECT COUNT(*) FROM audit_events a JOIN operations o ON o.id=a.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND a.kind='operation_execution_handoff'"), 0)
            programPayloadGrant(f)
            let invalid = f.completed(f.direct("program-raw-limit", f.input(code: String.fromUtf8(Array<Byte>(262145, repeat: 32))), ExecutionBudget(maxToolCalls: 1)))
            try { @Expect(invalid.isError); @Expect(httpIntentText(invalid.output, "error"), "tool_program.source_limit") }
            finally { invalid.releasePayload() }
            @Expect(f.children("program-raw-limit"), 0)
        } finally { f.close() }
    }
}
