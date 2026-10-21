package agent_product

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class NativePlanReviewBindingPressureTests {
    @TestCase
    func currentBindingIsMetadataOnlyAndDoesNotLaunchUnusedGuidanceUnderOriginalAggregatePressure(): Unit {
        let f = WorkflowRolesFixture()
        let name = workflowPlanTestSelect(f)
        let tools = f.product.toolsFor(f.product.readonlyToolCapabilities(f.session),
            threadId: Some(ThreadId(f.session.value)))
        let published = f.product.vnext.publishedToolIdentity(name, threadId: Some(ThreadId(f.session.value))).getOrThrow()
        let pressure = reserveProductControlMetadata113(4096)
        try {
            let original = productControlMetadataUsage113()
            // The same original bank and limits: leave one MiB for bounded
            // metadata but not another 16 MiB logical-message floor.
            pressure.ensureRetainedPeak(16777216 + productControlMetadataCapacity113() - original[1] - 1048576)
            let before = productControlMetadataUsage113()
            @Expect(before[1], productControlMetadataCapacity113() - 1048576)
            let current = lifecycleTestRequire(queryProductWorkflowPlanBinding(f.product, f.session, tools))
            @Expect(current[0], name)
            @Expect(current[1], published.implementationVersion)
            @Expect(current[2], published.implementationFingerprint)
            let after = productControlMetadataUsage113()
            @Expect(after[0], before[0]); @Expect(after[1], before[1])
            // Rendering remains a real bounded invocation. Metadata success
            // does not grant room or permission to render under this pressure.
            match (queryProductWorkflowGuidance(f.product, f.session, "plan", tools)) {
                case Result.Ok(_) => @Expect(false)
                case Result.Err(error) => @Expect(error.code, "policy.query_limit")
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        } finally { pressure.close(); f.close() }
    }

    @TestCase
    func currentBindingRefusesMissingPublicationChangedSelectionAndDisabledOriginalContribution(): Unit {
        let f = WorkflowRolesFixture()
        let name = workflowPlanTestSelect(f)
        let tools = f.product.toolsFor(f.product.readonlyToolCapabilities(f.session),
            threadId: Some(ThreadId(f.session.value)))
        try {
            @Expect(queryProductWorkflowPlanBinding(f.product, f.session, []).isError())
            f.select("sha256:0000000000000000000000000000000000000000000000000000000000000000")
            @Expect(queryProductWorkflowPlanBinding(f.product, f.session, tools).isError())
            @Expect(workflowPlanTestSelect(f), name)
            let namespace = productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))
            @Expect(f.product.setPluginEnabled(namespace, false, f.record.scope).isOk())
            @Expect(queryProductWorkflowPlanBinding(f.product, f.session, tools).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
}