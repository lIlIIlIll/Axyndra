package agent_host_runtime

import agent_sdk.*
import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*

import std.unittest.*
import std.unittest.testmacro.*


// These fixtures exhaust the actual shared Native bank with their own leases.
// The existing Runtime/SQLite fixture supplies canonical facts. The actual
// Pipeline prepares a readonly test call; its executor must never run. No
// caller-fabricated Source, alternate bank or execution bypass is used.
private class AttachmentPressureNoEffect204 <: ToolExecutor {
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        throw IllegalStateException("capacity fixture must never execute a Tool")
    }
}
private func attachmentCapacityFailure204(grow: Bool): Unit {
    let f = LivePolicyCanonicalFixture()
    let host = HostJavaScriptPluginHost({ path => HostLocalReadTargetInspector(path) })
    let owner = HostToolInputAttachmentOwner(HostArtifactStore("/never-opened-attachment-pressure"))
    let context = ToolInvocationContext(f.active.runId, SessionId(f.active.threadId.value),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), epoch: f.active.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: f.root, cwd: f.root),
        cancellation: f.cancellation.token, contextProjection: f.active.contextSnapshot)
    let call = ToolCall("attachment-pressure-call", "attachment-pressure-tool", objectValue([]))
    let catalog = ToolCatalog()
    catalog.register(ToolDescriptor(ModelToolDefinition(call.name, "Readonly capacity fixture",
        objectValue([ValueField("type", textValue("object"))])), Capability(CapabilityKind.WorkspaceRead)),
        AttachmentPressureNoEffect204()).value().getOrThrow()
    let pipeline = ToolPipeline(catalog, f.store, PathIdentitySqlAudit(f.database), HostIds())
    let prepared = match (pipeline.prepare(context, call).value().getOrThrow()) {
        case ToolPreparation.Ready(value) => value
        case _ => throw IllegalStateException("actual readonly fixture preparation was not ready") }
    let before = nativeControlMetadataUsage113()
    let retained = ArrayList<LogicalJsonOwnerReservation>()
    try {
        let required: Int64 = if (grow) { 67108864 } else { 16777216 }
        while (nativeControlMetadataCapacity113() - nativeControlMetadataUsage113()[1] >= required) {
            retained.add(reserveNativeDocumentPayload(1))
        }
        let pressured = nativeControlMetadataUsage113()
        // Growth case admits the original floor, then refuses its exact
        // 64 MiB invoice. Both failures must refund only their own attempt.
        if (grow) { @Expect(nativeControlMetadataCapacity113() - pressured[1] >= 16777216, true) }
        let result = owner.acquire(host, context, prepared, "axyndra:fixture", "run", 1u64)
        @Expect(result.isError(), true)
        let error = result.error().getOrThrow()
        @Expect(error.code, "input_attachment.capacity")
        @Expect(error.kind, AgentErrorKind.BudgetExceeded)
        @Expect(error.retryable, false); @Expect(error.fallbackAllowed, false)
        @Expect(nativeControlMetadataUsage113()[0], pressured[0])
        @Expect(nativeControlMetadataUsage113()[1], pressured[1])
        @Expect(owner.close().isOk(), true)
    } finally {
        for (paid in retained) { paid.close() }
        host.close().value().getOrThrow(); f.close()
    }
    @Expect(nativeControlMetadataUsage113()[0], before[0])
    @Expect(nativeControlMetadataUsage113()[1], before[1])
}

@Test
class PluginInputAttachmentTests {
    @TestCase
    func AbsentDeclarationPreservesDefaultAndBrokeredToolCarriesOnlyMetadata(): Unit {
        let old = PluginContributionDefinition("run", PluginContributionKind.Tool)
        @Expect(old.inputAttachmentField, ""); @Expect(old.inputAttachmentMaxBytes, 0)
        let selected = PluginContributionDefinition("run", PluginContributionKind.Tool,
            inputAttachmentField: "code", inputAttachmentMaxBytes: 262144)
        @Expect(selected.inputAttachmentField, "code"); @Expect(selected.inputAttachmentMaxBytes, 262144)
    }
    @TestCase
    func ServiceDataOnlyAndMalformedDeclarationsCannotOptIntoHostInputPersistence(): Unit {
        var refused: Int64 = 0
        try { let _ = PluginContributionDefinition("endpoint", PluginContributionKind.Service,
            inputAttachmentField: "code", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        try { let _ = PluginContributionDefinition("pure", PluginContributionKind.Tool, executionProfile: PluginToolExecutionProfile.DataOnly,
            inputAttachmentField: "code", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        try { let _ = PluginContributionDefinition("run", PluginContributionKind.Tool,
            inputAttachmentField: "../code", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        try { let _ = PluginContributionDefinition("run", PluginContributionKind.Tool,
            inputAttachmentField: "", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        @Expect(refused, 4)
    }
    @TestCase
    func realInitialReservationRefusalIsBudgetFailureAndKeepsOriginalBank(): Unit {
        attachmentCapacityFailure204(false)
    }
    @TestCase
    func realInvoiceGrowthRefusalRefundsItsAttemptAndStaysBudgetFailure(): Unit {
        attachmentCapacityFailure204(true)
    }

}
