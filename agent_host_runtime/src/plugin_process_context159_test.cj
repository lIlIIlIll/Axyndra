package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

private func processContextSnapshotProducer159(owner: OwnedToolSetSnapshot159): Unit {
    let schema = objectValue([])
    owner.installSnapshot159(ToolSetSnapshot("process-context-snapshot", [
        ToolSnapshotEntry("read", "read", schema, "v1", [],
            implementationFingerprint: "read-v1", schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))
    ]))
}
private func processContextProjectionFrame159(context: ToolInvocationContext,
    cancellation: CancellationToken): ToolInvocationContext {
    hostPluginProcessCancellationContext(context, cancellation)
}

// DATA projection only: no Source, prepared invocation, worker or fake ACK.
@Test
class HostProcessCancellationContext159Tests {
    @TestCase
    func processControlKeepsRestrictionsWithoutExportingTheCatalogGraph(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let root = bank.acquire(131072)
        let paid = root.deriveRetainedLease(); paid.ensureRetainedPeak(131072)
        let producer = OwnedToolSetSnapshot159(paid)
        processContextSnapshotProducer159(producer)
        producer.returnedSnapshotProducer159()
        let shared = producer.transferSharedSnapshot159()
        let original = CancellationSource(); let replacement = CancellationSource()
        let budget = ExecutionBudget(maxToolCalls: 2, deadlineMillis: 123456)
        let context = ToolInvocationContext(RunId("process-context-run"), SessionId("process-context-session"),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: "src")]), epoch: 7,
            toolContext: ToolContextDescriptor(workspaceRoot: "/workspace", cwd: "/workspace/src"),
            cancellation: original.token, budget: budget, ownedToolSetSnapshot159: Some(shared.fork159()))
        try {
            let projected = processContextProjectionFrame159(context, replacement.token)
            @Expect(projected.runId.value, context.runId.value)
            @Expect(projected.sessionId.value, context.sessionId.value)
            @Expect(projected.epoch, 7)
            @Expect(projected.workspaceRoot, "/workspace")
            @Expect(projected.cwd, "/workspace")
            @Expect(refEq(projected.budget, budget), true)
            @Expect(projected.budget.deadlineMillis, 123456)
            @Expect(projected.capabilities.allows(CapabilityKind.WorkspaceRead, resource: "src"), true)
            @Expect(projected.capabilities.allows(CapabilityKind.WorkspaceWrite, resource: "src"), false)
            @Expect(projected.toolSetSnapshot.isNone(), true)
            @Expect(projected.hasOwnedToolSetSnapshot159(), false)
            // The whole projection helper has returned; its output contains
            // no catalog alias. The real source owner can now return its data.
            context.returnOwnedToolSetFrame159(); shared.close159(); root.close()
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
            let _ = replacement.cancel()
            @Expect(projected.cancellation.isCancelled(), true)
            @Expect(original.token.isCancelled(), false)
        } finally { original.close(); replacement.close() }
    }
}
