package agent_product

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func artifactEncodingAppend(name: String, value: AgentValue): AgentValue {
    objectValue([ValueField("action", textValue("append")), ValueField("stream", textValue("stdout")),
        ValueField("offset", integerValue(0)), ValueField(name, value)])
}

@Test
class ServiceArtifactEncodingTests {
    @TestCase
    func canonicalEncodedControlsKeepOriginalFileHashAndByteOffsets(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let content = "雪" + String.fromUtf8(Array<Byte>(16381, repeat: 0u8))
        let expected = content + content
        let writer = ProductServiceArtifactWriter(root, reserveNativeObservationBuffer())
        try {
            lifecycleTestRequire(writer.open())
            let encoded = serviceArtifactAppendText(artifactEncodingAppend("data_base64", textValue(productBase64Bytes(content.toArray()))))
            @Expect(encoded, content)
            lifecycleTestRequire(writer.append(0, encoded, expected.size))
            lifecycleTestRequire(writer.append(content.size, serviceArtifactAppendText(artifactEncodingAppend("text", textValue(content))), expected.size))
            lifecycleTestRequire(writer.finish(expected.size, modelPolicySha256Text(expected)))
            let path = root + "/published"
            lifecycleTestRequire(writer.publish(path))
            @Expect(String.fromUtf8(File.readFrom(path)), expected)
            @Expect(writer.completedArtifact().bytes, expected.size)
            @Expect(writer.completedArtifact().sha256, modelPolicySha256Text(expected))
        } finally { lifecycleTestRequire(writer.close()); remove(root, recursive: true) }
    }
    @TestCase
    func malformedEncodingAndOversizedDecodedContentFailBeforeAppend(): Unit {
        for (value in ["", "A", "AA=", "AA===", "AB==", "AAF=", "=AAA", "A=AA", "AA=A", "AA==AAAA",
            "AA\n=", "__8=", "////", String.fromUtf8(Array<Byte>(21848, repeat: b'A')),
            productBase64Bytes(Array<Byte>(16385, repeat: b'x'))]) {
            var rejected = false
            try { let _ = serviceArtifactAppendText(artifactEncodingAppend("data_base64", textValue(value))) }
            catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
        @Expect(serviceArtifactBase64("AA=="), "\u{0000}")
        @Expect(serviceArtifactBase64("AAE="), "\u{0000}\u{0001}")
        @Expect(serviceArtifactBase64("6Zuq"), "雪")
    }
    @TestCase
    func representationsAreExclusiveAndCannotCarryPathsOrReferences(): Unit {
        let both = artifactEncodingAppend("text", textValue("a")); both.put("data_base64", textValue("YQ=="))
        let path = artifactEncodingAppend("data_base64", textValue("YQ==")); path.put("path", textValue("/tmp/untrusted"))
        let reference = artifactEncodingAppend("data_base64", textValue("YQ==")); reference.put("ref", textValue("blob:sha256:untrusted"))
        for (value in [both, path, reference, artifactEncodingAppend("data_base64", integerValue(1)),
            artifactEncodingAppend("text", nullValue()), artifactEncodingAppend("text", textValue("")),
            artifactEncodingAppend("text", textValue(String.fromUtf8(Array<Byte>(16385, repeat: b'x'))))]) {
            var rejected = false
            try { let _ = serviceArtifactAppendText(value) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
}
