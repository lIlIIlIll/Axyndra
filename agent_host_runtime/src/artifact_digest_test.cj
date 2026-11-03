package agent_host_runtime

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HostArtifactDigestTests {
    @TestCase
    func standardMessagesKeepTheirPublishedSha256Identity(): Unit {
        for ((message, expected) in [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        ]) {
            @Expect(hostArtifactSha256(message.toArray()), expected)
        }
    }

    @TestCase
    func binaryPaddingBoundariesPreserveEveryOriginalByte(): Unit {
        for ((size, expected) in [
            (55, "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59"),
            (64, "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108"),
            (65, "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781"),
            (256, "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
        ]) {
            let bytes = Array<Byte>(size, { index => UInt8(index % 256) })
            @Expect(hostArtifactSha256(bytes), expected)
        }
    }

    @TestCase
    func oneMillionBytesKeepTheStandardArtifactDigest(): Unit {
        @Expect(hostArtifactSha256(Array<Byte>(1000000, repeat: b'a')),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
