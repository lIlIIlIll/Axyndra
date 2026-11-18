package agent_product

import agent_domain.*
import agent_plugin_registry
import std.fs.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

func productOwnedRegistryFixture83(id: String): ProductPluginRuntime {
    let root = pluginContractTemp("owned-consumer-" + id)
    Directory.create(root, recursive: true)
    ProductPluginRuntime(root + "/settings", root + "/workspace")
}

@Test
class ProductOwnedRegistryConsumerData83Tests {
    @TestCase
    func copiedDataStaysChargedUntilTheLastProductCloses(): Unit {
        let floor: Int64 = 16777216
        let bank = LogicalJsonOwnerBudget(maximumCharged: floor)
        let debt = ProductRegistryEscapedCopyDebt83()
        debt.beginProduct()
        debt.adopt(bank.acquire(1))
        debt.beginProduct()
        debt.endProduct()
        @Expect(bank.usage()[1], floor)
        debt.endProduct()
        @Expect(bank.usage()[1], 0)

        // An unmatched close cannot retire a copy adopted after the last owner.
        debt.adopt(bank.acquire(1))
        debt.endProduct()
        @Expect(bank.usage()[1], floor)
        debt.beginProduct()
        debt.endProduct()
        @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func fullCopiedMaintenanceErrorSurvivesActualRegistryBackingRetirement(): Unit {
        let runtime = productOwnedRegistryFixture83("full-error")
        let expected = "leading\u{0000} Unicode 汉字 \n trailing " + String.fromUtf8(Array<UInt8>(32768, { _ => 120u8 }))
        let error = runtime.ownedError("plugin.not_found", expected, source: "actual/source", field: "manifest")
        let copied = productRegistryErrorText83(error, PluginRegistryErrorText.Message)
        error.close(); runtime.close()
        @Expect(copied, expected)
        @Expect(copied.size, expected.size)
    }

    @TestCase
    func allStaticOwnedErrorFieldsKeepTheirExactFixedCapacityReason(): Unit {
        let error = PluginRegistryOwnedError.capacity()
        @Expect(productRegistryErrorText83(error, PluginRegistryErrorText.Message), "registry metadata cannot fit the original shared capacity")
        @Expect(productRegistryErrorText83(error, PluginRegistryErrorText.Source), "")
        @Expect(productRegistryErrorText83(error, PluginRegistryErrorText.Field), "")
        error.close()
    }

    @TestCase
    func completeOwnedJsonCopyPreservesTheOriginalBusinessCodec(): Unit {
        let runtime = productOwnedRegistryFixture83("complete-json")
        let source = "{\"array\":[{\"text\":\"\\u0000汉字\"},true,null],\"maximum\":9223372036854775807}"
        let error = runtime.ownedError("plugin.not_found", source)
        let copied = productRegistryCopyJson83(error.copyText(PluginRegistryErrorText.Message))
        let expected = parseUnifiedJson(source, maxBytes: RUN_CONTEXT_SNAPSHOT_MAX_BYTES)
        error.close(); runtime.close()
        @Expect(stringifyUnifiedJson(copied), stringifyUnifiedJson(expected))
        @Expect(copied.field("array").getOrThrow().items.size, 3)
    }

    @TestCase
    func closedOwnedBytePacketRejectsBeforeAnyCopiedArrayOrString(): Unit {
        let runtime = productOwnedRegistryFixture83("before-copy")
        let error = runtime.ownedError("plugin.not_found", "same actual owner")
        let bytes = match (error.copyText(PluginRegistryErrorText.Message)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(_) => throw IllegalStateException("actual owned error did not produce bytes")
        }
        bytes.close()
        var refused = false
        try { let _ = productRegistryCopyText83(PluginRegistryResult.Ok(bytes)) }
        catch (_: Exception) { refused = true }
        error.close(); runtime.close()
        @Expect(refused, true)
    }
}
