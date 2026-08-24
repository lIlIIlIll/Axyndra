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
    let reference = stack.readReference("review", "checklist").value().getOrThrow()
    expect(reference.content == "checklist" && loader.reads == 2,
        "declared reference loads only when needed")
    stack.readReference("review", "checklist").value().getOrThrow()
    stack.activate("review").value().getOrThrow()
    expect(loader.reads == 2, "activated instructions and references are stable per Run")
    expect(stack.readReference("review", "undeclared").isError(),
        "active skill cannot read undeclared references")
    println("vNext skill runtime contract passed")
    0
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
