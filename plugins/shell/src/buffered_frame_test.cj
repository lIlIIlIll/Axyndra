package shell_plugin

import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ShellFrameTestInput <: InputStream {
    private let value: Array<Byte>
    private let maximum: Int64
    private var offset: Int64 = 0
    init(value: String, maximum!: Int64 = 8192) { this.value = value.toArray(); this.maximum = maximum }
    public func read(output: Array<Byte>): Int64 {
        let count = min(min(output.size, maximum), value.size - offset)
        for (index in 0..count) { output[index] = value[offset + index] }
        offset += count; count
    }
}

@Test
class ShellBufferedFrameTests {
    @TestCase
    func preservesSplitUtf8NewlineAndCoalescedFrames(): Unit {
        for (size in [1, 2, 7, 8192]) {
            let reader = ShellFrameReader(ShellFrameTestInput("{\"text\":\"雪\"}\n{\"n\":2}\n", maximum: size))
            @Expect(text(reader.readFrame().getOrThrow(), "text"), "雪")
            @Expect(number(reader.readFrame().getOrThrow(), "n"), 2)
            @Expect(reader.readFrame().isNone())
        }
    }
    @TestCase
    func incompleteAndOversizedFramesAreRejected(): Unit {
        for (value in ["{\"n\":1}", "{\"text\":\"" + String.fromUtf8(Array<Byte>(FRAME_LIMIT, repeat: b'x')) + "\"}\n"]) {
            var rejected = false
            try { let _ = ShellFrameReader(ShellFrameTestInput(value)).readFrame() }
            catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
    @TestCase
    func canonicalBase64PreservesUtf8AndControls(): Unit {
        @Expect(shellArtifactBase64("AA=="), "\u{0000}")
        @Expect(shellArtifactBase64("AAE="), "\u{0000}\u{0001}")
        @Expect(shellArtifactBase64("6Zuq"), "雪")
        @Expect(shellArtifactBase64("YWJj"), "abc")
    }
    @TestCase
    func explicitArtifactBoundPreservesSixteenKibWithoutChangingTheDefault(): Unit {
        let encoded = String.fromUtf8(Array<Byte>(21846, repeat: b'A')) + "=="
        @Expect(shellArtifactBase64(encoded, maxBytes: 16384), String.fromUtf8(Array<Byte>(16384, repeat: 0u8)))
        for (maximum in [0, 8192, 16385]) {
            var rejected = false
            try { let _ = shellArtifactBase64(encoded, maxBytes: maximum) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
        var rejected = false
        try { let _ = shellArtifactBase64(String.fromUtf8(Array<Byte>(21848, repeat: b'A')), maxBytes: 16384) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
    @TestCase
    func rejectsInvalidPaddingPadBitsAlphabetUtf8AndDecodedSize(): Unit {
        for (value in ["", "A", "AA=", "AA===", "AB==", "AAF=", "=AAA", "A=AA", "AA=A", "AA==AAAA",
            "AA\n=", "__8=", "////", String.fromUtf8(Array<Byte>(10924, repeat: b'A'))]) {
            var rejected = false
            try { let _ = shellArtifactBase64(value) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
    @TestCase
    func binaryChannelChunksPreserveEmptyNonUtf8AndSplitCodePoints(): Unit {
        @Expect(shellChannelBase64("").size, 0)
        let bytes = shellChannelBase64("AAH/")
        @Expect(bytes.size, 3)
        @Expect(bytes[0], 0u8); @Expect(bytes[1], 1u8); @Expect(bytes[2], 255u8)
        let first = shellChannelBase64("6Q==")
        let rest = shellChannelBase64("m6o=")
        @Expect(String.fromUtf8([first[0], rest[0], rest[1]]), "雪")
        @Expect(shellChannelBase64("/w==")[0], 255u8)
        for (artifact in ["", "/w==", "6Q=="]) {
            var rejected = false
            try { let _ = shellArtifactBase64(artifact) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
    @TestCase
    func binaryChannelEnforcesCanonicalPaddingAndThirtyTwoKibDecodedBound(): Unit {
        let maximum = String.fromUtf8(Array<Byte>(43691, repeat: b'A')) + "="
        @Expect(shellChannelBase64(maximum).size, 32768)
        for (value in ["A", "AA=", "AA===", "AB==", "AAF=", "=AAA", "A=AA", "AA=A", "AA==AAAA",
            "AA\n=", "__8=", String.fromUtf8(Array<Byte>(43692, repeat: b'A'))]) {
            var rejected = false
            try { let _ = shellChannelBase64(value) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }

}
