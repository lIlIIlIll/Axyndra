package agent_product

import agent_core.*
import agent_domain.*
import tool_runtime.ApprovalMode
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginContextBodyTests {
    @TestCase
    func invalidUtf8SelectedBodyIsAnObservedFailureWhileOtherSelectionAndMetadataRemain(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let root = f.root + "/instructions"
            writeObservedSkill(root, "")
            let invalid = ArrayList<Byte>("---\nname: review\ndescription: Review invalid body\n---\nPRIVATE-INVALID-BODY".toArray())
            invalid.add(255); invalid.add(254)
            File.writeTo(root + "/review/SKILL.md", invalid.toArray())
            Directory.create(root + "/good", recursive: true)
            File.writeTo(root + "/good/SKILL.md", "---\nname: good\ndescription: Good instructions\n---\nVALID-SELECTED-BODY\n".toArray())
            sequenceTestConfig(f, [root], ["selected"])
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let result = lifecycleTestRequire(app.submit("$review $good"))
            @Expect(result.snapshot.getOrThrow().status, RunState.Completed)
            let facts = sequenceFacts(f); @Expect(facts.size, 2); @Expect(initialContextHandoffs(f), 2)
            var found = false
            for (item in facts[1].output().field("resources").getOrThrow().items) {
                if (httpIntentText(item, "path") == "selected/review/SKILL.md") {
                    found = true; @Expect(httpIntentText(item, "error"), "invalid_utf8")
                    @Expect(httpIntentText(item, "text"), "")
                    @Expect(httpIntentText(item, "sha256"), modelPolicySha256(invalid.toArray())) }
            }
            @Expect(found)
            @Expect(initialContextStored(f).contributions().size, 1)
            @Expect(initialContextStored(f).contributions()[0].id, "good")
            let system = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
            @Expect(system.contains("VALID-SELECTED-BODY")); @Expect(system.contains("Review invalid body"))
            @Expect(!system.contains("PRIVATE-INVALID-BODY"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            skillsReadSettled(f)
        } finally { f.close() }
    }

    @TestCase
    func emptySelectedBodyKeepsTheOldMetadataFallbackWithoutFakingMissingRead(): Unit {
        let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let root = f.root + "/settings/skills"; writeObservedSkill(root, " \n\t\n")
            sequenceTestConfig(f, [root], ["selected"])
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let first = lifecycleTestRequire(contextDiagnosticApp(f, "emptySelectedBodyKeepsTheOldMetadataFallbackWithoutFakingMissingRead", app.submit("$review"))).approval.getOrThrow()
            let second = lifecycleTestRequire(contextDiagnosticApp(f, "emptySelectedBodyKeepsTheOldMetadataFallbackWithoutFakingMissingRead", app.decide(first.operationId.value, ApprovalDecision.Approve))).approval.getOrThrow()
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
            let result = lifecycleTestRequire(contextDiagnosticApp(f, "emptySelectedBodyKeepsTheOldMetadataFallbackWithoutFakingMissingRead", app.decide(second.operationId.value, ApprovalDecision.Approve)))
            @Expect(result.snapshot.getOrThrow().status, RunState.Completed)
            let facts = sequenceFacts(f); @Expect(facts.size, 2)
            let body = facts[1].output().field("resources").getOrThrow().items[0]
            @Expect(body.field("error").getOrThrow().unifiedKind, ValueKind.Null)
            @Expect(httpIntentText(body, "text").startsWith("---\nname: review"))
            let snapshot = initialContextStored(f)
            @Expect(snapshot.contributions().size, 1); @Expect(snapshot.contributions()[0].id, "catalog")
            @Expect(snapshot.contributions()[0].content.contains("Review code and tests"))
            @Expect(!snapshot.contributions()[0].content.contains("Selected instructions:"))
            @Expect(initialContextHandoffs(f), 2); skillsReadSettled(f)
        } finally { f.close() }
    }
}
