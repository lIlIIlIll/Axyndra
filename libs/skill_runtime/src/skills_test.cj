package skill_runtime

import std.unittest.*
import std.unittest.testmacro.*

class FixtureSkillLoader <: SkillContentLoader {
    public func read(contentRef: String): SkillResult<String> {
        match (contentRef) {
            case "instructions" => SkillResult.Ok("follow the bounded workflow")
            case "reference" => SkillResult.Ok("reference body")
            case _ => SkillResult.Err(SkillError("skill.fixture_missing", "missing fixture"))
        }
    }
}

@Test
class SkillRuntimeTests {
    @TestCase
    func progressivelyLoadsAndRestoresSnapshot() {
        let descriptor = SkillDescriptor(
            "review", "Review", "review code", ["review"], "instructions",
            references: [SkillReferenceDescriptor("rules", "review rules", "reference")]
        )
        let stack = SkillStack(SkillRegistry([descriptor]), FixtureSkillLoader())
        @Expect(stack.activate("review").isOk(), true)
        @Expect(stack.readReference("review", "rules").isOk(), true)
        @Expect(stack.readReference("missing", "rules").isOk(), false)

        let codec = JsonSkillSnapshotCodec()
        let restored = codec.decode(codec.encode(stack.snapshot()))
        @Expect(restored.active.size, 1)
        @Expect(restored.loadedReferences.size, 1)
        @Expect(restored.active[0].descriptor.id, "review")
    }
}
