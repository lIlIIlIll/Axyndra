package agent_product

import agent_domain.*
import agent_plugin_registry.PluginRegistry
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func hookGenerationRecord159g(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual generation fixture could not import its package") }
            finally { error.close() }
    }
}
private func writeHookGenerationPackage159g(path: String, version: String): Unit {
    Directory.create(path + "/extensions", recursive: true)
    File.writeTo(path + "/package.json", ("{\"name\":\"generation159g\",\"version\":\"" + version +
        "\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}").toArray())
    File.writeTo(path + "/extensions/index.js", "throw new Error('NOT_AN_EXECUTION_CONTROL');".toArray())
}
private func hookGenerationClose159g(runtime: ProductCodexHookRuntime): Unit {
    match (runtime.closeHookGenerationData159g()) {
        case Result.Err(error) => throw IllegalStateException(error.code)
        case Result.Ok(_) => ()
    }
}
private func hookGenerationCyclesFrame159g(root: String, first: ProductPluginRecord,
    second: ProductPluginRecord, probe: LogicalJsonOwnerReservation, replace: Bool): Unit {
    let processes = LocalProcessPort(LocalWorkspace(root))
    let runtime = ProductCodexHookRuntime(processes,
        ProductJavaScriptPluginHost(settingsRoot: root + "/settings"))
    // Both real descriptors remain alive throughout this probe. Their payment
    // is independent of the private generation copies being tested here.
    let original = probe.retainedCustodyUsage113()
    try {
        for (_ in 0..32) {
            runtime.activatePlugin(first)
            let installed = probe.retainedCustodyUsage113()
            @Expect(installed[0] > original[0]); @Expect(installed[2], original[2] + 1)
            if (replace) {
                runtime.activatePlugin(second)
                let replaced = probe.retainedCustodyUsage113()
                @Expect(replaced[0] > original[0]); @Expect(replaced[2], installed[2])
                runtime.revokePlugin(first)
                let stale = probe.retainedCustodyUsage113()
                @Expect(stale[0], replaced[0]); @Expect(stale[2], replaced[2])
                runtime.revokePlugin(second)
            } else { runtime.revokePlugin(first) }
            let after = probe.retainedCustodyUsage113()
            @Expect(after[0], original[0]); @Expect(after[2], original[2])
        }
        runtime.activatePlugin(second)
        @Expect(probe.retainedCustodyUsage113()[0] > original[0])
        hookGenerationClose159g(runtime)
        let closed = probe.retainedCustodyUsage113()
        @Expect(closed[0], original[0]); @Expect(closed[2], original[2])
        // The actual runtime closing gate rejects publication, then its full
        // private helper returns before the uninstalled lookup payment closes.
        runtime.activatePlugin(first)
        runtime.revokePlugin(second)
        let rejected = probe.retainedCustodyUsage113()
        @Expect(rejected[0], original[0]); @Expect(rejected[2], original[2])
    } finally { hookGenerationClose159g(runtime); let _ = processes.close() }
}
private func hookGenerationRegistryFrame159g(replace: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        writeHookGenerationPackage159g(root + "/source", "1.0.0")
        let first = hookGenerationRecord159g(registry.importLocal(root + "/source"))
        try {
            writeHookGenerationPackage159g(root + "/source", "2.0.0")
            let second = hookGenerationRecord159g(registry.updateLocal("pi:generation159g", root + "/source"))
            try {
                let probe = first.descriptor.deriveCopiedDataPayment(4194304)
                try {
                    let before = probe.retainedCustodyUsage113()
                    hookGenerationCyclesFrame159g(root, first, second, probe, replace)
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2])
                } finally { probe.close() }
            } finally { second.close() }
        } finally { first.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualPrivateHookGeneration159gTests {
    @TestCase
    func actualRegistryGenerationRepeatedActivationAndRevocationReturnsOnlyPrivateCopies159g(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookGenerationRegistryFrame159g(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualRegistryReplacementRejectsStaleRevocationAndClosedPublicationWithoutDebt159g(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookGenerationRegistryFrame159g(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
