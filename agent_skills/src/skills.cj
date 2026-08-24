package agent_skills

import agent_domain.*
import skill_runtime as library

public type SkillReferenceDescriptor = library.SkillReferenceDescriptor
public type SkillDescriptor = library.SkillDescriptor
public type SkillMetadata = library.SkillMetadata
public type SkillActivation = library.SkillActivation
public type LoadedSkillReference = library.LoadedSkillReference
public type SkillStackSnapshot = library.SkillStackSnapshot
public type SkillRegistry = library.SkillRegistry

public interface SkillContentLoader {
    func read(contentRef: String): Result<String>
}

class AgentSkillContentLoader <: library.SkillContentLoader {
    private let source: SkillContentLoader
    init(source: SkillContentLoader) { this.source = source }
    public func read(contentRef: String): library.SkillResult<String> {
        match (source.read(contentRef)) {
            case Result.Ok(value) => library.SkillResult.Ok(value)
            case Result.Err(error) => library.SkillResult.Err(library.SkillError(error.code, error.message))
        }
    }
}

public class SkillStack {
    private let primitive: library.SkillStack
    public init(registry: SkillRegistry, loader: SkillContentLoader) {
        primitive = library.SkillStack(registry, AgentSkillContentLoader(loader))
    }
    public func metadata(): Array<SkillMetadata> { primitive.metadata() }
    public func activate(id: String): Result<SkillActivation> { adaptSkillResult(primitive.activate(id)) }
    public func readReference(skillId: String, referenceId: String): Result<LoadedSkillReference> {
        adaptSkillResult(primitive.readReference(skillId, referenceId))
    }
    public func snapshot(): SkillStackSnapshot { primitive.snapshot() }
}

public func skillStackSnapshotValue(snapshot: SkillStackSnapshot): AgentValue {
    library.skillStackSnapshotValue(snapshot)
}

public func skillStackFromSnapshotValue(value: AgentValue): SkillStackSnapshot {
    library.skillStackFromSnapshotValue(value)
}

func adaptSkillResult<T>(value: library.SkillResult<T>): Result<T> {
    match (value) {
        case library.SkillResult.Ok(result) => Result.Ok(result)
        case library.SkillResult.Err(error) => Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            error.code,
            error.message,
            fields: [ErrorField("skill_error", error.code)]
        ))
    }
}
