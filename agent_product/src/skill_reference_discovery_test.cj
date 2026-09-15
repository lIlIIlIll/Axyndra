package agent_product

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProductSkillReferenceDiscoveryTests {
    @TestCase
    func invalidReferencesDoNotConsumeBoundedSlots(): Unit {
        verifyInvalidReferencesDoNotConsumeSlots("".toArray())
        verifyInvalidReferencesDoNotConsumeSlots(Array<Byte>(65537, repeat: 65))
    }
}

func verifyInvalidReferencesDoNotConsumeSlots(invalid: Array<Byte>): Unit {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let temporary = Directory.createTemp("target").toString()
    try {
        let references = temporary + "/references"
        Directory.create(references, recursive: true)
        for (index in 0..32) {
            File.writeTo(
                references + "/a-invalid-" + index.toString() + ".md",
                invalid
            )
        }
        File.writeTo(references + "/z-valid.md", "valid".toArray())

        let descriptors = productSkillReferences(temporary)
        @Expect(descriptors.size, 1)
        @Expect(descriptors[0].id, "z-valid.md")
    } finally {
        let _ = removeIfExists(temporary, recursive: true)
    }
}
