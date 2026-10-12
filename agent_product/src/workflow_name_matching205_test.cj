package agent_product

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProductWorkflowNameMatching205Tests {
    @TestCase
    func originalPublishedNameRequiresExactPrefixNamespaceSeparatorAndCompleteContribution(): Unit {
        @Expect(productWorkflowNameMatches205("plugin.axyndra:workflow.plan_write","axyndra:workflow","plan_write"),true)
        @Expect(productWorkflowNameMatches205("plugin.axyndra:workflow.plan_write","axyndra:other","plan_write"),false)
        @Expect(productWorkflowNameMatches205("plugin.axyndra:workflow.plan_write","axyndra:workflow","plan"),false)
        @Expect(productWorkflowNameMatches205("plugin.axyndra:workflow.plan_write.extra","axyndra:workflow","plan_write"),false)
        @Expect(productWorkflowNameMatches205("Plugin.axyndra:workflow.plan_write","axyndra:workflow","plan_write"),false)
        @Expect(productWorkflowNameMatches205("plugin.axyndra:workflow/plan_write","axyndra:workflow","plan_write"),false)
        @Expect(productWorkflowNameMatches205("plugin.axyndra:workflow.plan_write","axyndra:workflow.plan","write"),false)
        @Expect(productWorkflowNameMatches205("","axyndra:workflow","plan_write"),false)
    }
    @TestCase
    func matchingUsesOriginalUtf8BytesWithoutNormalizationTruncationOrAnExportedCopy(): Unit {
        for (_ in 0..64) {
            @Expect(productWorkflowNameMatches205("plugin.流程.计划","流程","计划"),true)
            @Expect(productWorkflowNameMatches205("plugin.流程.计划 ","流程","计划"),false)
            @Expect(productWorkflowNameMatches205("plugin.流程.计划","流程 ","计划"),false)
            @Expect(productWorkflowNameMatches205("plugin.a.b.c","a.b","c"),true)
            @Expect(productWorkflowNameMatches205("plugin.a.b.c","a","b.c"),true)
            @Expect(productWorkflowNameMatches205("plugin.a.\u{0000}b","a","\u{0000}b"),true)
            @Expect(productWorkflowNameMatches205("plugin.a.\u{0000}b","a","b"),false)
            @Expect(productWorkflowNameMatches205("plugin.a.b","aaaaaaaaaaaaaaaaaaaaaaaaaaaa","b"),false)
        }
    }
}
