package tool_runtime

import agent_domain.*
import agent_ports.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class CatalogPublicationIdentityExecutor110 <: ToolExecutor {
    var calls: Int64 = 0
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        calls++
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "test.catalog_identity_no_effect", "identity observation never invokes an executor"))
    }
}
private func catalogPublicationIdentityDescriptor110(name: String): ToolDescriptor {
    ToolDescriptor(ModelToolDefinition(name, "Actual current executor observation", objectValue([])),
        Capability(CapabilityKind.ExtensionInvoke))
}

@Test
class CatalogPublicationExecutorIdentityTests110 {
    @TestCase
    func actualPublicationIdentityRejectsDifferentInactiveRevokedAndForeignThreadWithoutCalling(): Unit {
        let catalog = ToolCatalog()
        let original = CatalogPublicationIdentityExecutor110()
        let different = CatalogPublicationIdentityExecutor110()
        let name = "test.catalog-identity"
        @Expect(catalog.register(catalogPublicationIdentityDescriptor110(name), original).isOk(), true)
        @Expect(catalog.publicationRetainsExecutor(name, original), true)
        @Expect(catalog.publicationRetainsExecutor(name, different), false)
        @Expect(catalog.publicationRetainsExecutor("test.missing", original), false)
        @Expect(catalog.setActive(name, false), true)
        @Expect(catalog.publicationRetainsExecutor(name, original), false)
        @Expect(catalog.setActive(name, true), true)
        @Expect(catalog.publicationRetainsExecutor(name, original), true)
        @Expect(catalog.revoke(name), true)
        @Expect(catalog.publicationRetainsExecutor(name, original), false)

        let thread = ThreadId("catalog-identity-thread")
        let owner = catalog.createContributionOwner("catalog-identity-owner", "test.scoped.",
            threadId: Some(thread)).value().getOrThrow()
        let digest = "0000000000000000000000000000000000000000000000000000000000000000"
        let binding = ToolContributionBinding("sha256:" + digest, digest, "catalog-identity-instance", 1)
        let scoped = "test.scoped.identity"
        @Expect(catalog.replaceOwnedBatch(owner, 0, binding,
            [ToolCatalogRegistration(catalogPublicationIdentityDescriptor110(scoped), original)]).isOk(), true)
        @Expect(catalog.publicationRetainsExecutor(scoped, original, threadId: Some(thread)), true)
        @Expect(catalog.publicationRetainsExecutor(scoped, different, threadId: Some(thread)), false)
        @Expect(catalog.publicationRetainsExecutor(scoped, original), false)
        @Expect(catalog.publicationRetainsExecutor(scoped, original,
            threadId: Some(ThreadId("another-thread"))), false)
        @Expect(catalog.revokeOwned(owner).isOk(), true)
        @Expect(catalog.publicationRetainsExecutor(scoped, original, threadId: Some(thread)), false)
        @Expect(original.calls, 0)
        @Expect(different.calls, 0)
    }
}
