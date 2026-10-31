package agent_skills

import agent_domain.*
import std.collection.*

public let SKILL_CONTEXT_OWNER: String = "axyndra.skills"

// Adapt the already frozen Run input without discovering files or loading any
// lazy reference. The tool runtime consumes only the generic domain projection.
public func skillInvocationContext(snapshot: SkillStackSnapshot): InvocationContextProjection {
    let contributions = ArrayList<InvocationContextContribution>()
    for (activation in snapshot.active) {
        let references = ArrayList<ContextResourceReference>()
        for (reference in activation.descriptor.references) {
            var loaded: ?String = None
            for (candidate in snapshot.loadedReferences where
                candidate.skillId == activation.descriptor.id &&
                candidate.referenceId == reference.id) {
                if (loaded.isSome()) {
                    throw IllegalArgumentException("duplicate loaded context resource identity")
                }
                loaded = Some(candidate.content)
            }
            references.add(ContextResourceReference(
                reference.id, reference.contentRef,
                trust: ContextContentTrust.UntrustedData, content: loaded
            ))
        }
        contributions.add(InvocationContextContribution(
            SKILL_CONTEXT_OWNER,
            activation.descriptor.id,
            activation.descriptor.instructionRef,
            activation.instructions,
            ContextContentTrust.UserSelected,
            references: references.toArray()
        ))
    }
    InvocationContextProjection(
        contributions: contributions.toArray(),
        sourceDigest: modelPolicySha256Text(canonicalAgentValue(skillStackSnapshotValue(snapshot)))
    )
}
