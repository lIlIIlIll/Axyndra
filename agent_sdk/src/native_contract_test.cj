package agent_sdk

import std.unittest.*
import std.unittest.testmacro.*

@Test
class NativeAuthoringDeclarationTests {
    @TestCase
    func preservesKindNameIdentityWithoutRequestAuthority() {
        let declarations = [PluginContributionDefinition("same", PluginContributionKind.Provider),
            PluginContributionDefinition("same", PluginContributionKind.Tool)]
        let value = NativePluginDefinition("native.fixture", "1.0.0", declarations,
            capabilities: ["document.store", "process.channel", "child.start"])
        @Expect(value.contributions.size, 2)
        @Expect(value.capabilities[0], "document.store")
        @Expect(value.capabilities[2], "child.start")
        // This is untrusted data. The unchanged Host rejects unsupported
        // capability/profile declarations before any activation or I/O.
        var duplicate = false
        try { let _ = NativePluginDefinition("native.fixture", "1.0.0",
            [declarations[0], declarations[0]]) }
        catch (_: IllegalArgumentException) { duplicate = true }
        @Expect(duplicate, true)
    }

    @TestCase
    func rejectsDuplicateAndNulCapabilityData() {
        let contributions = [PluginContributionDefinition("echo", PluginContributionKind.Provider)]
        var duplicate = false
        try { let _ = NativePluginDefinition("native.fixture", "1.0.0", contributions,
            capabilities: ["document.store", "document.store"]) }
        catch (_: IllegalArgumentException) { duplicate = true }
        @Expect(duplicate, true)
        var nul = false
        try { let _ = NativePluginDefinition("native.fixture", "1.0.0", contributions,
            capabilities: ["document\u{0000}store"]) }
        catch (_: IllegalArgumentException) { nul = true }
        @Expect(nul, true)
    }
}
