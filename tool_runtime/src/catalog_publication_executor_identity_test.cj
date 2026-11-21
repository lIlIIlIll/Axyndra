package tool_runtime

import agent_domain.*
import agent_runtime.*
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
    func ownedSnapshotsKeepIndependentSchemaAndCapabilityDecision(): Unit {
        let catalog = ToolCatalog()
        let thread = ThreadId("snapshot-thread")
        let owner = catalog.createContributionOwner("snapshot-owner", "test.scoped.",
            threadId: Some(thread)).value().getOrThrow()
        let digest = "0000000000000000000000000000000000000000000000000000000000000000"
        let binding = ToolContributionBinding("sha256:" + digest, digest, "snapshot-instance", 1)
        let name = "test.scoped.snapshot"
        let schema = objectValue([ValueField("required", listValue([textValue("path")]))])
        let descriptor = ToolDescriptor(ModelToolDefinition(name, "Snapshot schema", schema),
            Capability(CapabilityKind.WorkspaceRead))
        let executor = CatalogPublicationIdentityExecutor110()
        @Expect(catalog.replaceOwnedBatch(owner, 0, binding, [ToolCatalogRegistration(descriptor, executor)]).isOk())
        let allowed = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
        let first = catalog.toolSetSnapshot("allowed", allowed, threadId: Some(thread)).entries[0]
        @Expect(first.availableAtSnapshot)
        first.inputSchema.field("required").getOrThrow().items[0] = textValue("changed")
        let next = catalog.toolSetSnapshot("restricted", CapabilitySet(values: []), threadId: Some(thread)).entries[0]
        @Expect(!next.availableAtSnapshot)
        @Expect(next.name, name)
        @Expect(next.description, "Snapshot schema")
        @Expect(next.schemaDigest, descriptor.schemaDigest)
        @Expect(next.inputSchema.field("required").getOrThrow().items[0].asString(), "path")
    }

    @TestCase
    func revokingAnIdleToolDropsNoExternalReference(): Unit {
        let catalog = ToolCatalog()
        let executor = CatalogPublicationIdentityExecutor110()
        let name = "test.idle"
        @Expect(catalog.register(catalogPublicationIdentityDescriptor110(name), executor).isOk())
        @Expect(!catalog.revoke("test.missing"))
        @Expect(catalog.revoke(name))
        @Expect(!catalog.publicationRetainsExecutor(name, executor))
        @Expect(catalog.retireCatalogData159())
        let later = catalog.register(catalogPublicationIdentityDescriptor110("test.after"), executor)
        let code = match (later) { case Result.Err(error) => error.code; case Result.Ok(_) => "" }
        @Expect(code, "tool.catalog_closed")
        @Expect(executor.calls, 0)
    }

    @TestCase
    func missingRegistrationsDoNotPreventClosingTheCatalog(): Unit {
        let catalog = ToolCatalog()
        let executor = CatalogPublicationIdentityExecutor110()
        let name = "test.present"
        @Expect(catalog.register(catalogPublicationIdentityDescriptor110(name), executor).isOk())
        let missing = ToolCall("missing", "test.absent", objectValue([]))
        @Expect(catalog.publishedDescriptor(missing.name).isNone())
        @Expect(catalog.resolvedDescriptor(missing).isNone())
        @Expect(catalog.findRegistered(missing.name).isNone())
        @Expect(catalog.retireCatalogData159())
        let after = catalog.register(catalogPublicationIdentityDescriptor110("test.after"), executor)
        let code = match (after) { case Result.Err(error) => error.code; case Result.Ok(_) => "" }
        @Expect(code, "tool.catalog_closed")
        @Expect(executor.calls, 0)
    }

    @TestCase
    func aReturnedDescriptorStillPreventsClosingAfterAMiss(): Unit {
        let catalog = ToolCatalog()
        let executor = CatalogPublicationIdentityExecutor110()
        let name = "test.present"
        @Expect(catalog.register(catalogPublicationIdentityDescriptor110(name), executor).isOk())
        @Expect(catalog.publishedDescriptor("test.absent").isNone())
        let held = catalog.publishedDescriptor(name).getOrThrow()
        @Expect(!catalog.retireCatalogData159())
        @Expect(held.definition.name, name)
        @Expect(catalog.publicationRetainsExecutor(name, executor))
        @Expect(executor.calls, 0)
    }

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
