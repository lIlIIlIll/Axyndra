package product_prompt_contract

import agent_domain.*
import agent_product.*
import tool_runtime.*
import agent_testkit.FixtureModelPort
import std.collection.*
import std.fs.*
import std.io.*

func verifyAutomaticSkillRuns(product: ProductRuntime, probe: FixtureModelPort, session: SessionId, cacheKey: String): Unit {
    let automatic = product.request("review product changes", sessionId: Some(session))
    expect(automatic.initializeContext && automatic.contextSnapshot.contributions().isEmpty(), "automatic selection is deferred to the real Run")
    expect(product.client.start(automatic, {_ => ()}).isOk(), "automatic Skill Run completes")
    let frozen = promptStoredContext(product, automatic.runId)
    expect(promptContribution(frozen, "reviewer").getOrThrow().references()[0].content.isNone(), "references remain lazy")
    let active = probe.lastRequest.getOrThrow()
    expect(active.system.contains("REVIEWER-INSTRUCTIONS") && !active.system.contains("REFERENCE-MUST-STAY-LAZY") && active.cacheKey == cacheKey,
        "automatic instructions reach Core without changing stable cache identity")
    let unrelated = product.request("compute seven plus nine", sessionId: Some(session))
    expect(product.client.start(unrelated, {_ => ()}).isOk(), "unrelated next Run completes")
    expect(!promptHasSelected(promptStoredContext(product, unrelated.runId)), "a new Run does not inherit prior selections")
    expect(!probe.lastRequest.getOrThrow().system.contains("REVIEWER-INSTRUCTIONS") && probe.lastRequest.getOrThrow().cacheKey == cacheKey,
        "the subsequent Run omits inactive instructions and preserves stable cache identity")
}

func verifyAutomaticSkillDiscovery(temporary: String): Unit {
    let settings = temporary + "/settings"; let workspace = temporary + "/workspace"
    let directory = settings + "/skills/local-review"
    Directory.create(directory + "/references", recursive: true); Directory.create(workspace, recursive: true)
    let header = "---\nname: local-review\ndescription: Review code changes\n---\n"
    File.writeTo(directory + "/SKILL.md", (header + "FROZEN-INSTRUCTIONS").toArray())
    File.writeTo(directory + "/references/checklist.md", "LAZY-REFERENCE".toArray())
    promptConfigureReadScopes(settings)
    let product = openProduct(config: ProductConfig(settingsRoot: settings, stateRoot: temporary + "/state", workspaceRoot: workspace,
        fixture: true, approvalMode: ApprovalMode.Yolo, distributionRoot: promptDistributionRoot())).value().getOrThrow()
    try {
        let first = promptSelectedContext(product, "$local-review")
        expect(promptContribution(first, "local-review").getOrThrow().content.contains("FROZEN-INSTRUCTIONS"), "actual approved body is frozen")
        File.writeTo(directory + "/SKILL.md", (header + "NEW-INSTRUCTIONS").toArray())
        expect(promptContribution(first, "local-review").getOrThrow().content.contains("FROZEN-INSTRUCTIONS"), "editing cannot mutate the existing snapshot")
        let explicit = product.request("unrelated", contextSnapshot: Some(first))
        expect(!explicit.initializeContext && product.client.start(explicit, { _ => () }).isOk(), "explicit immutable context bypasses automatic reads")
        expect(product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("FROZEN-INSTRUCTIONS"), "explicit context does not reload source")
        let second = promptSelectedContext(product, "$local-review")
        expect(promptContribution(second, "local-review").getOrThrow().content.contains("NEW-INSTRUCTIONS"), "later Run refreshes exact body")
        expect(promptReference(product, first, "local-review", "checklist.md", "automatic-reference") == "LAZY-REFERENCE", "lazy canonical read preserves old declaration")
        expect(promptContribution(first, "local-review").getOrThrow().references()[0].content.isNone(), "tool output does not mutate context snapshot")
        expect(!promptHasSelected(promptSelectedContext(product, "compute seven plus nine")), "unrelated task keeps no selection")
        let bytes = ArrayList<Byte>(); for (byte in header.toArray()) { bytes.add(byte) }; bytes.add(255)
        File.writeTo(directory + "/SKILL.md", bytes.toArray())
        let invalid = promptSelectedContext(product, "$local-review")
        expect(!promptHasSelected(invalid) && product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("Review code changes"),
            "bounded header metadata remains visible but observed invalid UTF8 body is not activated")
        File.writeTo(directory + "/SKILL.md", "---\nname: incomplete\ndescription: no delimiter".toArray())
        let incomplete = promptSelectedContext(product, "$local-review")
        expect(!promptHasSelected(incomplete), "unterminated frontmatter is not discoverable")
    } finally { product.close() }
}
