package product_prompt_contract

import agent_domain.*
import agent_product.*
import agent_skills.*
import model_adapters.*
import std.collection.*
import std.fs.*

func verifyAutomaticSkillRuns(
    product: ProductRuntime,
    probe: FixtureModelPort,
    session: SessionId,
    cacheKey: String
): Unit {
    let automatic = product.request("review product changes", sessionId: Some(session))
    expect(automatic.skillStack.active.size == 1 &&
        automatic.skillStack.active[0].descriptor.id == "reviewer" &&
        automatic.skillStack.loadedReferences.isEmpty(),
        "a task selects instructions, but not references, before its Run")
    expect(product.client.start(automatic, {_ => ()}).isOk(), "automatic Skill Run completes")
    let active = probe.lastRequest.getOrThrow()
    expect(active.system.contains("REVIEWER-INSTRUCTIONS") &&
        !active.system.contains("REFERENCE-MUST-STAY-LAZY") && active.cacheKey == cacheKey,
        "automatically selected instructions reach Core without changing the stable cache key")
    let unrelated = product.request("compute seven plus nine", sessionId: Some(session))
    expect(unrelated.skillStack.active.isEmpty(), "a new Run does not inherit the previous selection")
    expect(product.client.start(unrelated, {_ => ()}).isOk(), "unrelated next Run completes")
    let inactive = probe.lastRequest.getOrThrow()
    expect(!inactive.system.contains("REVIEWER-INSTRUCTIONS") && inactive.cacheKey == cacheKey,
        "the subsequent Run omits inactive instructions and preserves the stable cache key")
}

func verifyAutomaticSkillDiscovery(temporary: String): Unit {
    let settings = temporary + "/settings"
    let workspace = temporary + "/workspace"
    let directory = settings + "/skills/review"
    Directory.create(directory + "/references", recursive: true)
    let header = "---\nname: review\ndescription: Review code changes\n---\n"
    File.writeTo(directory + "/SKILL.md", (header + "FROZEN-INSTRUCTIONS").toArray())
    File.writeTo(directory + "/references/checklist.md", "LAZY-REFERENCE".toArray())
    let runtime = ProductSkillRuntime(settings, workspace)
    let first = runtime.resolve("review code changes", SkillStackSnapshot([], []))
    expect(first.active.size == 1 && first.active[0].instructions == "FROZEN-INSTRUCTIONS" &&
        first.loadedReferences.isEmpty(), "automatic activation loads instructions only")
    File.writeTo(directory + "/SKILL.md", (header + "NEW-INSTRUCTIONS").toArray())
    expect(first.active[0].instructions == "FROZEN-INSTRUCTIONS",
        "editing a Skill cannot mutate an existing Run snapshot")
    let explicit = runtime.resolve("an unrelated task", first)
    expect(explicit.active[0].instructions == "FROZEN-INSTRUCTIONS",
        "a caller-supplied snapshot takes precedence without reloading disk content")
    let second = runtime.resolve("review code changes", SkillStackSnapshot([], []))
    expect(second.active[0].instructions == "NEW-INSTRUCTIONS",
        "a later Run refreshes instructions without changing the earlier snapshot")
    let reference = runtime.readReference(first, "review", "checklist.md").value().getOrThrow()
    expect(reference.content == "LAZY-REFERENCE" && first.loadedReferences.isEmpty(),
        "Product reads return tool data without mutating loadedReferences in the launch snapshot")
    expect(runtime.resolve("compute seven plus nine", SkillStackSnapshot([], [])).active.isEmpty(),
        "unrelated tasks keep an empty Skill stack")
    expect(runtime.readReference(SkillStackSnapshot([], []), "review", "checklist.md").isError(),
        "automatic routing cannot bypass reference activation checks")

    // Invalid UTF-8 after the delimiter proves discovery neither reads nor
    // decodes the body; activation still validates and rejects invalid data.
    let bytes = ArrayList<Byte>()
    for (byte in header.toArray()) { bytes.add(byte) }
    bytes.add(255)
    File.writeTo(directory + "/SKILL.md", bytes.toArray())
    expect(runtime.metadata().size == 1, "metadata discovery does not decode instruction bodies")
    expect(runtime.resolve("$review", SkillStackSnapshot([], [])).active.isEmpty(),
        "activation rejects an unreadable body without substituting another Skill")
    File.writeTo(directory + "/SKILL.md", "---\nname: incomplete\ndescription: no delimiter".toArray())
    expect(runtime.metadata().isEmpty(), "unterminated frontmatter is not discoverable")
}
