package agent_cli

import std.unittest.*
import std.unittest.testmacro.*

@Test
class PlanSourceDigestTests {
    @TestCase
    func sourceDigestUsesExactUtf8WithoutDisplayEnvelopeOrTrimming(): Unit {
        let source = "Plan 雪\nAcceptance: exact source"
        let expected = "9eacab443b3593f6561e93307762f58622e3d4270cb490345fdc41c59032ba6c"
        @Expect(planReviewHash(source), expected)
        @Expect(planReviewHash("Latest plan:\n\n" + source) != expected)
        @Expect(planReviewHash(source + "\n") != expected)
        @Expect(planReviewHash(source.replace("exact", "different")) != expected)
    }
}
