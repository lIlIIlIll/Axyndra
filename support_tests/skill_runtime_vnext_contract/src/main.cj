package skill_runtime_vnext_contract

import agent_domain.*
import agent_skills.*

main(): Int64 {
    let loader = CountingLoader()
    let stack = SkillStack(SkillRegistry([
        SkillDescriptor(
            "review", "Review", "Review a code change", ["review"], "skill://review",
            references: [
                SkillReferenceDescriptor("checklist", "Detailed checklist", "ref://checklist")
            ]
        )
    ]), loader)
    let metadata = stack.metadata()
    expect(metadata.size == 1 && metadata[0].name == "Review" && loader.reads == 0,
        "metadata is visible without loading instructions")
    expect(stack.readReference("review", "checklist").isError() && loader.reads == 0,
        "reference cannot bypass skill activation")
    let activation = stack.activate("review").value().getOrThrow()
    expect(activation.instructions == "instructions" && loader.reads == 1,
        "activation loads instructions only")
    expect(stack.snapshot().loadedReferences.isEmpty(),
        "activation does not eagerly load references")
    let projected = skillInvocationContext(stack.snapshot())
    let context = projected.contribution(SKILL_CONTEXT_OWNER, "review").getOrThrow()
    expect(loader.reads == 1 && context.reference("checklist").getOrThrow().content.isNone(),
        "generic context projection does not load a lazy reference")
    expect(context.trust == ContextContentTrust.UserSelected &&
        context.reference("checklist").getOrThrow().trust == ContextContentTrust.UntrustedData,
        "context projection preserves selected instructions and lower-trust resource data")
    let reference = stack.readReference("review", "checklist").value().getOrThrow()
    expect(reference.content == "checklist" && loader.reads == 2,
        "declared reference loads only when needed")
    stack.readReference("review", "checklist").value().getOrThrow()
    stack.activate("review").value().getOrThrow()
    expect(loader.reads == 2, "activated instructions and references are stable per Run")
    let loaded = skillInvocationContext(stack.snapshot())
        .contribution(SKILL_CONTEXT_OWNER, "review").getOrThrow()
        .reference("checklist").getOrThrow()
    expect(loaded.content.getOrThrow() == "checklist" &&
        loaded.contentDigest.getOrThrow() == modelPolicySha256Text("checklist") && loader.reads == 2,
        "projection preserves already-loaded bytes and their digest without another read")
    expect(stack.readReference("review", "undeclared").isError(),
        "active skill cannot read undeclared references")
    genericProjectionFreezesCallerArrays()
    println("vNext skill runtime contract passed")
    0
}

func genericProjectionFreezesCallerArrays(): Unit {
    let references = [SkillReferenceDescriptor("details", "Details", "ref://original")]
    let active = [SkillActivation(
        SkillDescriptor("review", "Review", "Review source", [], "skill://review", references: references),
        "Original instructions"
    )]
    let snapshot = SkillStackSnapshot(active, [])
    let sourceDigest = modelPolicySha256Text(canonicalAgentValue(skillStackSnapshotValue(snapshot)))
    let projected = skillInvocationContext(snapshot)
    references[0] = SkillReferenceDescriptor("details", "Replacement", "ref://replacement")
    active[0] = SkillActivation(SkillDescriptor("other", "Other", "Other source", [], "skill://other"), "Changed")
    let retained = projected.contribution(SKILL_CONTEXT_OWNER, "review").getOrThrow()
    expect(retained.content == "Original instructions" &&
        retained.reference("details").getOrThrow().locator == "ref://original" &&
        projected.sourceDigest == sourceDigest,
        "invocation context freezes source references and identity against caller array mutation")
    expect(projected.contribution("other.provider", "review").isNone(),
        "another context provider cannot satisfy a Skill namespace lookup")
    var duplicateRejected = false
    try {
        let _ = skillInvocationContext(SkillStackSnapshot([SkillActivation(
            SkillDescriptor("review", "Review", "Review source", [], "skill://review",
                references: [SkillReferenceDescriptor("details", "Details", "ref://original")]),
            "Instructions"
        )], [
            LoadedSkillReference("review", "details", "first"),
            LoadedSkillReference("review", "details", "second")
        ]))
    } catch (_: IllegalArgumentException) { duplicateRejected = true }
    expect(duplicateRejected, "ambiguous loaded reference content is rejected without first-wins selection")
}

class CountingLoader <: SkillContentLoader {
    var reads: Int64 = 0

    public func read(contentRef: String): Result<String> {
        reads += 1
        match (contentRef) {
            case "skill://review" => Result.Ok("instructions")
            case "ref://checklist" => Result.Ok("checklist")
            case _ => Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "fixture.not_found", "fixture content missing"
            ))
        }
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
