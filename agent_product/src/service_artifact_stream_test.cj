package agent_product

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ServiceArtifactStreamTests {
    @TestCase
    func actualFileStreamsExactUtf8HashAndReusesOnlyIdenticalExistingBlob(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let source = "雪" + String.fromUtf8(Array<Byte>(16380, repeat: b'x'))
        let expected = source + source
        let writer = ProductServiceArtifactWriter(root, reserveNativeObservationBuffer())
        try {
            @Expect(Directory.readFrom(root).size, 0)
            lifecycleTestRequire(writer.open())
            @Expect(Directory.readFrom(root).size, 1)
            lifecycleTestRequire(writer.append(0, source, expected.size))
            lifecycleTestRequire(writer.append(source.size, source, expected.size))
            lifecycleTestRequire(writer.finish(expected.size, modelPolicySha256Text(expected)))
            let path = root + "/" + modelPolicySha256Text(expected) + ".txt"
            lifecycleTestRequire(writer.publish(path))
            @Expect(Directory.readFrom(root).size, 1)
            @Expect(String.fromUtf8(File.readFrom(path)), expected)
            @Expect(writer.completedArtifact().bytes, expected.size)
            @Expect(writer.preview().size <= 8192)
            @Expect(writer.preview().startsWith("雪"))
            lifecycleTestRequire(writer.verifyPublished(path))
            let duplicate = ProductServiceArtifactWriter(root, reserveNativeObservationBuffer())
            try {
                lifecycleTestRequire(duplicate.open())
                @Expect(Directory.readFrom(root).size, 2)
                lifecycleTestRequire(duplicate.append(0, source, expected.size))
                lifecycleTestRequire(duplicate.append(source.size, source, expected.size))
                lifecycleTestRequire(duplicate.finish(expected.size, modelPolicySha256Text(expected)))
                lifecycleTestRequire(duplicate.publish(path))
                @Expect(Directory.readFrom(root).size, 1)
                @Expect(String.fromUtf8(File.readFrom(path)), expected)
            } finally { lifecycleTestRequire(duplicate.close()) }
            lifecycleTestRequire(writer.close())
            @Expect(writer.verifyPublished(path).isError())
        } finally { lifecycleTestRequire(writer.close()); remove(root, recursive: true) }
    }

    @TestCase
    func incompleteWrongOffsetDigestAndExistingConflictNeverOverwriteContent(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        try {
            for (mode in ["offset", "limit", "digest", "incomplete", "existing"]) {
                let originalCount = Directory.readFrom(root).size
                let writer = ProductServiceArtifactWriter(root, reserveNativeObservationBuffer())
                try {
                    lifecycleTestRequire(writer.open())
                    if (mode == "offset") { @Expect(writer.append(1, "content", 7).isError()) }
                    else if (mode == "limit") { @Expect(writer.append(0, "content", 6).isError()) }
                    else {
                        lifecycleTestRequire(writer.append(0, "content", 7))
                        if (mode == "digest") { @Expect(writer.finish(7, modelPolicySha256Text("other")).isError()) }
                        else if (mode == "incomplete") { @Expect(writer.finish(8, modelPolicySha256Text("content")).isError()) }
                        else {
                            lifecycleTestRequire(writer.finish(7, modelPolicySha256Text("content")))
                            let existing = root + "/existing"
                            File.writeTo(existing, "unchanged".toArray())
                            @Expect(writer.publish(existing).isError())
                            @Expect(String.fromUtf8(File.readFrom(existing)), "unchanged")
                        }
                    }
                } finally { lifecycleTestRequire(writer.close()) }
                @Expect(Directory.readFrom(root).size, originalCount + if (mode == "existing") { 1 } else { 0 })
                lifecycleTestRequire(writer.close())
                @Expect(writer.open().isError())
            }
            // A failed file creation remains owned until explicit cleanup,
            // returns its allocation exactly once, and cannot be reopened.
            let pool = LogicalJsonOwnerBudget()
            let failed = ProductServiceArtifactWriter(root + "/missing", pool.acquireFixedBuffer(65536))
            @Expect(failed.open().isError())
            @Expect(pool.usage()[1], 65536)
            @Expect(failed.open().isError())
            lifecycleTestRequire(failed.close())
            @Expect(pool.usage()[1], 0)
            lifecycleTestRequire(failed.close())
            @Expect(failed.open().isError())
        } finally { remove(root, recursive: true) }
    }
}
