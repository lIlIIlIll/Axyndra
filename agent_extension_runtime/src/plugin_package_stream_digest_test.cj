package agent_extension_runtime

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginPackageStreamDigestTests {
    @TestCase
    func nativeLibraryBytesKeepTheExistingSha256AtPaddingAndReadBoundaries(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let path = Path(root).join("binary")
        try {
            let bytes0 = Array<Byte>(0, { index => UInt8(index % 251) })
            File.writeTo(path, bytes0)
            @Expect(pluginPackageFileDigest(path, 0, root), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            let bytes1 = Array<Byte>(1, { index => UInt8(index % 251) })
            File.writeTo(path, bytes1)
            @Expect(pluginPackageFileDigest(path, 1, root), "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
            let bytes55 = Array<Byte>(55, { index => UInt8(index % 251) })
            File.writeTo(path, bytes55)
            @Expect(pluginPackageFileDigest(path, 55, root), "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59")
            let bytes56 = Array<Byte>(56, { index => UInt8(index % 251) })
            File.writeTo(path, bytes56)
            @Expect(pluginPackageFileDigest(path, 56, root), "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562")
            let bytes63 = Array<Byte>(63, { index => UInt8(index % 251) })
            File.writeTo(path, bytes63)
            @Expect(pluginPackageFileDigest(path, 63, root), "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488")
            let bytes64 = Array<Byte>(64, { index => UInt8(index % 251) })
            File.writeTo(path, bytes64)
            @Expect(pluginPackageFileDigest(path, 64, root), "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108")
            let bytes65 = Array<Byte>(65, { index => UInt8(index % 251) })
            File.writeTo(path, bytes65)
            @Expect(pluginPackageFileDigest(path, 65, root), "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781")
            let bytes65535 = Array<Byte>(65535, { index => UInt8(index % 251) })
            File.writeTo(path, bytes65535)
            @Expect(pluginPackageFileDigest(path, 65535, root), "dda402a2c028f0cbbdbc5c6ebae965eed9c75f71236e7022b0386d3455d5ae2f")
            let bytes65536 = Array<Byte>(65536, { index => UInt8(index % 251) })
            File.writeTo(path, bytes65536)
            @Expect(pluginPackageFileDigest(path, 65536, root), "4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2")
            let bytes65539 = Array<Byte>(65539, { index => UInt8(index % 251) })
            File.writeTo(path, bytes65539)
            @Expect(pluginPackageFileDigest(path, 65539, root), "6859d9b53d73fd394a476c8cbf60367e041a0188a670fa853913becda71267fc")
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func v2TreeDigestKeepsPathsModesSizesAndBinaryBytes(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        try {
            let binary = Array<Byte>(66001, { index => UInt8(index % 251) })
            File.writeTo(Path(root).join("binary"), binary)
            File.writeTo(Path(root).join("empty"), [])
            File.writeTo(Path(root).join("snow-雪"), "snow-雪".toArray())
            let _ = FileInfo(Path(root).join("binary")).setExecutable(true)
            let _ = FileInfo(Path(root).join("empty")).setExecutable(false)
            let _ = FileInfo(Path(root).join("snow-雪")).setExecutable(false)
            let legacy = "axyndra-package-tree-v2\n" +
                "6:binary:true:66001:" + modelPolicySha256(binary) + "\n" +
                "5:empty:false:0:" + modelPolicySha256([]) + "\n" +
                "8:snow-雪:false:8:" + modelPolicySha256Text("snow-雪") + "\n"
            let actual = match (pluginContentDigest(root)) {
                case PluginPackageResult.Ok(value) => value
                case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
            }
            @Expect(actual, "sha256:" + modelPolicySha256Text(legacy))
            File.writeTo(Path(root).join("binary"), [0u8])
            @Expect(match (pluginContentDigest(root)) {
                case PluginPackageResult.Ok(value) => value != actual
                case PluginPackageResult.Err(_) => false
            })
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func recordedSizeAndTreeEntryLimitsStillRejectChanges(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let path = Path(root).join("binary")
        try {
            File.writeTo(path, [0u8, 255u8, 1u8])
            for (size in [-1, 0, 2, 4, 268435457]) {
                var rejected = false
                try { let _ = pluginPackageFileDigest(path, size, root) } catch (_: Exception) { rejected = true }
                @Expect(rejected)
            }
            SymbolicLink.create(Path(root).join("link"), to: path)
            var escaped = false
            try { let _ = pluginPackageFileDigest(Path(root).join("link"), 3, root) } catch (_: Exception) { escaped = true }
            @Expect(escaped)
            escaped = false
            try { let _ = pluginPackageFileDigest(path, 3, root + "/other") } catch (_: Exception) { escaped = true }
            @Expect(escaped)
            @Expect(match (pluginContentDigest(root)) {
                case PluginPackageResult.Err(error) => error.code == "plugin.package_symlink_unsupported"
                case PluginPackageResult.Ok(_) => false
            })
        } finally { remove(root, recursive: true) }
    }
}
