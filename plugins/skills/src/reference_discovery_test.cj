package skills_plugin

import skill_runtime.*
import std.fs.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PackagedReferenceDiscoveryBoundaryTests {
    @TestCase
    func invalidReferencesDoNotConsumeBoundedSlots(): Unit {
        for (invalid in ["".toArray(), Array<Byte>(1048577, repeat: 65)]) {
            let root = Directory.createTemp("/tmp").toString()
            try {
                Directory.create(root + "/references")
                for (index in 0..32) { File.writeTo(root + "/references/a-invalid-" + index.toString() + ".md", invalid) }
                File.writeTo(root + "/references/z-valid.md", "valid".toArray())
                let descriptors = packagedSkillReferences(root)
                @Expect(descriptors.size, 1); @Expect(descriptors[0].id, "z-valid.md")
            } finally { remove(root, recursive: true) }
        }
    }

    @TestCase
    func metadataBudgetChargesEscapedRepresentation(): Unit {
        let descriptor = SkillDescriptor("escaping", "escaping", String.fromUtf8(Array<Byte>(11000, repeat: 60)), [], "unused")
        let source = packagedSkillMetadataPrompt([SkillMetadata(descriptor)])
        @Expect(source.size < PACKAGED_SKILL_MAX_METADATA_BYTES)
        @Expect(packagedSkillEscapedMetadataBytes(source) > PACKAGED_SKILL_MAX_METADATA_BYTES)
        @Expect(boundedPackagedSkillDescriptors([descriptor]).isEmpty())
    }
}
