package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func registryDigestWorkIdentity(root: String,
    accounting: ?PluginPackageMetadataAccounting): String {
    match (inspectPluginPackage(root, metadataAccounting: accounting)) {
        case PluginPackageResult.Ok(value) => value.contentDigest
        case PluginPackageResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

@Test
class RegistryDigestWorkTests {
    @TestCase
    func actualPaidInspectionKeepsV2OrderModesAndEverySameSizeByteChange(): Unit {
        let (beforeOwners, beforeBytes) = nativeControlMetadataUsage113()
        let root = canonicalize(Directory.createTemp(".")).toString()
        let custody = PluginRegistryMetadataCustody()
        let memory = try { PluginRegistryStateMemory(custody) }
            catch (error: Exception) { custody.close(); remove(root, recursive: true); throw error }
        try {
            let packageRoot = registryFixturePackage(root, "1.0.0")
            let largest = Array<Byte>(1048579, { index => UInt8(index % 251) })
            let other = Array<Byte>(1048577, { index => UInt8(index % 239) })
            File.writeTo(packageRoot + "/zz-largest", largest)
            File.writeTo(packageRoot + "/aa-other", other)
            File.writeTo(packageRoot + "/mm-empty", [])
            File.writeTo(packageRoot + "/mm-雪", [0u8, 255u8, 17u8])
            for (path in ["aa-other", "extensions/index.js", "package.json", "mm-empty", "mm-雪"]) {
                let _ = FileInfo(packageRoot + "/" + path).setExecutable(false)
            }
            let _ = FileInfo(packageRoot + "/zz-largest").setExecutable(true)
            // Independent SHA256 goldens of the six exact files and original
            // v2 path/mode/size format. The worker file sorts last, not first.
            @Expect(registryDigestWorkIdentity(packageRoot, None),
                "sha256:968cdf3f244eda72d420783a047fdb9b883b23d67721eaa7b353947719137c63")
            @Expect(registryDigestWorkIdentity(packageRoot, Some(memory)),
                "sha256:968cdf3f244eda72d420783a047fdb9b883b23d67721eaa7b353947719137c63")
            largest[largest.size - 1] += 1u8
            File.writeTo(packageRoot + "/zz-largest", largest)
            @Expect(registryDigestWorkIdentity(packageRoot, Some(memory)),
                "sha256:6a4c424b3f3a9417122c701fd589a95f6a52d0c0e52befdf41dbaa909eab20a3")
            other[0] += 1u8
            File.writeTo(packageRoot + "/aa-other", other)
            @Expect(registryDigestWorkIdentity(packageRoot, Some(memory)),
                "sha256:fc45a98875143abfe62aae78f58ce3db175ccfabdccb56e01444dc1156c8f36a")
            let _ = FileInfo(packageRoot + "/zz-largest").setExecutable(false)
            @Expect(registryDigestWorkIdentity(packageRoot, Some(memory)),
                "sha256:51209cfa2bd72940e56def074b08c90319f11b692aea9fbc07ade7de7f205abc")
        } finally {
            memory.close(); custody.close(); remove(root, recursive: true)
        }
        let (afterOwners, afterBytes) = nativeControlMetadataUsage113()
        @Expect(afterBytes, beforeBytes)
        @Expect(afterOwners, beforeOwners)
    }
}
