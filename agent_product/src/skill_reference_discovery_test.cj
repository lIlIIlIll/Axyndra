package agent_product

import agent_skills.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProductSkillDiscoveryBoundaryTests {
    @TestCase
    func invalidReferencesDoNotConsumeBoundedSlots(): Unit {
        verifyInvalidReferencesDoNotConsumeSlots("".toArray())
        verifyInvalidReferencesDoNotConsumeSlots(Array<Byte>(65537, repeat: 65))
    }

    @TestCase
    func metadataBudgetChargesEscapedRepresentation(): Unit {
        let descriptor = SkillDescriptor(
            "escaping",
            "escaping",
            String.fromUtf8(Array<Byte>(11000, repeat: 60)),
            [],
            "unused"
        )
        let source = productSkillMetadataPrompt([SkillMetadata(descriptor)])
        @Expect(source.size < PRODUCT_SKILL_MAX_METADATA_BYTES)
        @Expect(productSkillEscapedMetadataBytes(source) > PRODUCT_SKILL_MAX_METADATA_BYTES)
        @Expect(boundedProductSkillDescriptors([descriptor]).isEmpty())
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
