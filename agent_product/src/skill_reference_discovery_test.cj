package agent_product

import tool_runtime.*

import agent_domain.*
import std.fs.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ProductContextReferenceBoundaryTests {
    @TestCase
    func invalidContextIsRejectedBeforeDirectRunAdmission(): Unit {
        let root = pluginContractTemp("invalid-context-admission")
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(
            settingsRoot: root + "/settings", stateRoot: root + "/state", workspaceRoot: root, fixture: true)))
        try {
            let result = product.vnext.executeCanonicalTool(SessionId("invalid-context-session"), CapabilitySet(),
                ToolCall("invalid-context-call", "read", objectValue([])),
                contextSnapshot: InvocationContextProjection(contributions: [InvocationContextContribution(
                    "example.context", "oversized", "missing://oversized",
                    String.fromUtf8(Array<Byte>(RUN_CONTEXT_SNAPSHOT_MAX_BYTES + 1, repeat: 65)),
                    ContextContentTrust.UserSelected)]), runId: Some(RunId("invalid-context-run")))
            @Expect(result.error().getOrThrow().code, "context.snapshot_invalid")
            @Expect(product.latestRunId(ThreadId("invalid-context-session")).error().getOrThrow().code, "inspection.run_missing")
            @Expect(product.runInspection(ThreadId("invalid-context-session"), RunId("invalid-context-run")).error().getOrThrow().code,
                "product.app_thread_missing")
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func genericPreloadedReferenceIsImmutableAndNeverOpensItsLocator(): Unit {
        let root = pluginContractTemp("preloaded-context-reference")
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(
            settingsRoot: root + "/settings", stateRoot: root + "/state", workspaceRoot: root, fixture: true,
            approvalMode: ApprovalMode.Yolo)))
        try {
            let references = [ContextResourceReference("details", "missing://reference", content: Some("pinned content"))]
            let snapshot = validatedContextSnapshot(InvocationContextProjection(contributions: [InvocationContextContribution(
                "example.context", "review", "missing://instructions", "Instructions", ContextContentTrust.UserSelected,
                references: references)]))
            references[0] = ContextResourceReference("details", root + "/replacement.md", content: Some("replacement"))
            let output = lifecycleTestRequire(product.invokeLocalTool(SessionId("preloaded-context-thread"), CONTEXT_RESOURCE_TOOL,
                objectValue([ValueField("owner", textValue("example.context")), ValueField("contribution", textValue("review")),
                    ValueField("reference", textValue("details"))]), contextSnapshot: snapshot))
            @Expect(httpIntentText(output.output, "content"), "pinned content")
            let stored = snapshot.contribution("example.context", "review").getOrThrow().reference("details").getOrThrow()
            @Expect(stored.contentDigest.getOrThrow(), modelPolicySha256Text("pinned content"))
            @Expect(!exists(Path(root + "/replacement.md")))
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func genericReferenceCannotUseForeignOwnerOrUndeclaredIdentity(): Unit {
        let root = pluginContractTemp("context-reference-owner")
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(
            settingsRoot: root + "/settings", stateRoot: root + "/state", workspaceRoot: root, fixture: true)))
        try {
            let snapshot = InvocationContextProjection(contributions: [InvocationContextContribution("actual.owner", "review",
                "context://review", "Instructions", ContextContentTrust.UntrustedData,
                references: [ContextResourceReference("details", "missing://reference", content: Some("pinned content"))])])
            for ((owner, reference) in [("foreign.owner", "details"), ("actual.owner", "undeclared")]) {
                let result = product.invokeLocalTool(SessionId("foreign-reference-thread"), CONTEXT_RESOURCE_TOOL,
                    objectValue([ValueField("owner", textValue(owner)), ValueField("contribution", textValue("review")),
                        ValueField("reference", textValue(reference))]), contextSnapshot: snapshot)
                @Expect(result.isError())
                @Expect(result.error().getOrThrow().code,
                    if (owner == "foreign.owner") { "context.reference_inactive" } else { "context.reference_missing" })
            }
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }
}
