package agent_product

import agent_skills.*
import std.collection.*
import std.io.*
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProductSkillRoutingTests {
    @TestCase
    func automaticRoutingUsesMetadataAndCanSelectNothing(): Unit {
        let available = [
            skillRoutingMetadata("reviewer", "Review product changes"),
            skillRoutingMetadata("ci", "Diagnose build failures")
        ]
        let selected = selectProductSkills(available, "Please review these product changes")
        @Expect(selected.size, 1)
        @Expect(selected[0], "reviewer")
        @Expect(selectProductSkills(available, "calculate seven plus nine").isEmpty())
        @Expect(selectProductSkills(available, "coincidence").isEmpty())
        @Expect(selectProductSkills(available, "build build build").isEmpty())
    }

    @TestCase
    func exactNamesAndTriggerPhrasesAreBoundaryAware(): Unit {
        let available = [
            SkillMetadata(SkillDescriptor(
                "review", "Code Review", "Inspect source correctness", ["check changes"], "unused"
            )),
            skillRoutingMetadata("ci", "Diagnose pipelines")
        ]
        @Expect(selectProductSkills(available, "please use CODE REVIEW")[0], "review")
        @Expect(selectProductSkills(available, "check the changes")[0], "review")
        @Expect(selectProductSkills(available, "preview changess").isEmpty())
        @Expect(selectProductSkills(available, "check unrelated changes").isEmpty())
        let unicode = [skillRoutingMetadata("审查", "审查 代码")]
        @Expect(selectProductSkills(unicode, "请 审查 代码")[0], "审查")
    }

    @TestCase
    func explicitSelectionsNeverGainAutomaticAdditions(): Unit {
        let available = [
            skillRoutingMetadata("review", "Review code changes"),
            skillRoutingMetadata("ci", "Diagnose build failures")
        ]
        let selected = selectProductSkills(available, "$ci review code changes")
        @Expect(selected.size, 1)
        @Expect(selected[0], "ci")
        for (prompt in ["$unknown review code", "$review_var", "$review中", "x$review"]) {
            @Expect(selectProductSkills(available, prompt).isEmpty())
        }
        let both = selectProductSkills(available, "$ci $review $ci")
        @Expect(both.size, 2)
        @Expect(both.contains("ci") && both.contains("review"))
    }

    @TestCase
    func rankingIsBoundedAndIndependentOfCatalogOrder(): Unit {
        let available = [
            skillRoutingMetadata("gamma", "review code"),
            skillRoutingMetadata("beta", "review code code code"),
            skillRoutingMetadata("delta", "review code"),
            skillRoutingMetadata("alpha", "review code")
        ]
        let selected = selectProductSkills(available, "review code")
        @Expect(selected.size, PRODUCT_SKILL_MAX_AUTOMATIC)
        @Expect(selected[0], "alpha")
        @Expect(selected[1], "beta")
        @Expect(selected[2], "delta")
        let reordered = selectProductSkills(
            [available[3], available[2], available[1], available[0]], "review code"
        )
        for (index in 0..selected.size) { @Expect(selected[index], reordered[index]) }
        let exact = selectProductSkills(available, "review code gamma")
        @Expect(exact[0], "gamma")
    }

    @TestCase
    func automaticTermBudgetDoesNotRouteFromATruncatedPrefix(): Unit {
        let available = [skillRoutingMetadata("review", "Review code changes")]
        var prompt = "review code "
        for (_ in 0..PRODUCT_SKILL_MAX_ROUTING_TERMS) { prompt += "token " }
        @Expect(selectProductSkills(available, prompt).isEmpty())
    }

    @TestCase
    func oversizedPromptsSkipAutomaticRoutingButPreserveExplicitChoice(): Unit {
        let available = [skillRoutingMetadata("review", "Review code changes")]
        let padding = String.fromUtf8(Array<Byte>(PRODUCT_SKILL_MAX_ROUTING_BYTES, repeat: 32))
        @Expect(selectProductSkills(available, padding + "review code").isEmpty())
        @Expect(selectProductSkills(available, padding + "$review")[0], "review")
    }
}

@Test
class ProductSkillDiscoveryTests {
    @TestCase
    func metadataReaderStopsExactlyBeforeInstructionBody(): Unit {
        for (newline in ["\n", "\r\n"]) {
            let header = "---" + newline + "name: 审查" + newline +
                "description: Review code" + newline + "---" + newline
            let stream = SkillReadProbe((header + "DO-NOT-READ-BODY").toArray(), header.size)
            @Expect(readProductSkillHeader(stream, PRODUCT_SKILL_MAX_HEADER_BYTES), header)
            @Expect(stream.position, header.size)
        }
    }

    @TestCase
    func metadataReaderRejectsMalformedAndOverBudgetHeaders(): Unit {
        for (source in ["body only\n", "---\nname: incomplete\n", "---\n---"]) {
            let stream = SkillReadProbe(source.toArray(), source.size)
            @Expect(readProductSkillHeader(stream, PRODUCT_SKILL_MAX_HEADER_BYTES), "")
        }
        let source = "---\nname: " + String.fromUtf8(Array<Byte>(8192, repeat: 65))
        let stream = SkillReadProbe(source.toArray(), PRODUCT_SKILL_MAX_HEADER_BYTES)
        @Expect(readProductSkillHeader(stream, PRODUCT_SKILL_MAX_HEADER_BYTES), "")
        @Expect(stream.position, PRODUCT_SKILL_MAX_HEADER_BYTES)
        let boundary = "---\nname: boundary\n---\n"
        let exact = SkillReadProbe(boundary.toArray(), boundary.size)
        @Expect(readProductSkillHeader(exact, boundary.size), boundary)
        let short = SkillReadProbe(boundary.toArray(), boundary.size - 1)
        @Expect(readProductSkillHeader(short, boundary.size - 1), "")
    }

    @TestCase
    func metadataReaderDoesNotDecodeAnInvalidUtf8Body(): Unit {
        let header = "---\nname: review\ndescription: Review code\n---\n"
        let data = ArrayList<Byte>()
        for (byte in header.toArray()) { data.add(byte) }
        data.add(255)
        let stream = SkillReadProbe(data.toArray(), header.size)
        @Expect(readProductSkillHeader(stream, PRODUCT_SKILL_MAX_HEADER_BYTES), header)
    }

    @TestCase
    func instructionReadsHaveAnIndependentActualByteLimit(): Unit {
        let exact = SkillReadProbe("12345678".toArray(), 8)
        @Expect(readProductSkillText(exact, 8), "12345678")
        let oversized = SkillReadProbe("123456789-extra".toArray(), 9)
        var rejected = false
        try { let _ = readProductSkillText(oversized, 8) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
        @Expect(oversized.position, 9)
    }

    @TestCase
    func catalogHasCountAndRenderedMetadataBudgets(): Unit {
        let candidates = ArrayList<SkillDescriptor>()
        for (index in 0..PRODUCT_SKILL_MAX_CANDIDATES + 8) {
            candidates.add(SkillDescriptor(
                "skill-" + index.toString(), "Skill " + index.toString(),
                "Review code", [], "unused"
            ))
        }
        @Expect(boundedProductSkillDescriptors(candidates.toArray()).size, PRODUCT_SKILL_MAX_CANDIDATES)
        let large = ArrayList<SkillDescriptor>()
        for (index in 0..32) {
            large.add(SkillDescriptor(
                "large-" + index.toString(), "Large " + index.toString(),
                String.fromUtf8(Array<Byte>(3000, repeat: 65)), [], "unused"
            ))
        }
        let bounded = boundedProductSkillDescriptors(large.toArray())
        @Expect(bounded.size > 0 && bounded.size < large.size)
        let metadata = SkillRegistry(bounded).metadata()
        @Expect(productSkillMetadataPrompt(metadata).size <= PRODUCT_SKILL_MAX_METADATA_BYTES)
    }

    @TestCase
    func metadataBudgetCannotResurrectShadowedSkills(): Unit {
        let values = ArrayList<SkillDescriptor>()
        productSkillReplace(values, SkillDescriptor("review", "Review", "old", [], "old"))
        productSkillReplace(values, SkillDescriptor(
            "review", "Review", String.fromUtf8(Array<Byte>(PRODUCT_SKILL_MAX_METADATA_BYTES, repeat: 65)),
            [], "replacement"
        ))
        @Expect(values.size, 1)
        @Expect(boundedProductSkillDescriptors(values.toArray()).isEmpty())
    }
}

func skillRoutingMetadata(id: String, description: String): SkillMetadata {
    SkillMetadata(SkillDescriptor(id, id, description, [], "unused"))
}

class SkillReadProbe <: InputStream {
    private let data: Array<Byte>
    private let readLimit: Int64
    var position: Int64 = 0

    init(data: Array<Byte>, readLimit: Int64) { this.data = data; this.readLimit = readLimit }

    public func read(buffer: Array<Byte>): Int64 {
        let count = min(buffer.size, data.size - position)
        if (position + count > readLimit) {
            throw IllegalStateException("reader crossed the expected content boundary")
        }
        for (index in 0..count) { buffer[index] = data[position + index] }
        position += count
        count
    }
}
