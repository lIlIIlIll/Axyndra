package skill_runtime

import std.collection.*
import std.sync.*
import json4cj.*

// Experimental: the runtime semantics are reusable, but no ecosystem-wide
// SKILL.md format is declared stable by this package.
public class SkillError <: Exception {
    public let code: String
    public init(code: String, message: String) { super(message); this.code = code }
}

public enum SkillResult<T> {
    Ok(T) | Err(SkillError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

public interface SkillSnapshotCodec<T> {
    func encode(snapshot: SkillStackSnapshot): T
    func decode(value: T): SkillStackSnapshot
}

public class SkillReferenceDescriptor {
    public let id: String
    public let description: String
    public let contentRef: String

    public init(id: String, description: String, contentRef: String) {
        if (id.trimAscii() == "" || description.trimAscii() == "" ||
            contentRef.trimAscii() == "") {
            throw IllegalArgumentException("skill reference metadata must not be empty")
        }
        this.id = id.trimAscii()
        this.description = description.trimAscii()
        this.contentRef = contentRef.trimAscii()
    }
}

public class SkillDescriptor {
    public let id: String
    public let name: String
    public let description: String
    public let triggers: Array<String>
    public let instructionRef: String
    public let references: Array<SkillReferenceDescriptor>

    public init(
        id: String,
        name: String,
        description: String,
        triggers: Array<String>,
        instructionRef: String,
        references!: Array<SkillReferenceDescriptor> = []
    ) {
        if (id.trimAscii() == "" || name.trimAscii() == "" ||
            description.trimAscii() == "" || instructionRef.trimAscii() == "") {
            throw IllegalArgumentException("skill descriptor metadata must not be empty")
        }
        for (index in 0..references.size) {
            for (other in index + 1..references.size where
                references[index].id == references[other].id) {
                throw IllegalArgumentException("skill descriptor contains duplicate references")
            }
        }
        this.id = id.trimAscii()
        this.name = name.trimAscii()
        this.description = description.trimAscii()
        this.triggers = triggers
        this.instructionRef = instructionRef.trimAscii()
        this.references = references
    }
}

public class SkillMetadata {
    public let id: String
    public let name: String
    public let description: String
    public let triggers: Array<String>
    public let references: Array<SkillReferenceDescriptor>

    public init(descriptor: SkillDescriptor) {
        id = descriptor.id
        name = descriptor.name
        description = descriptor.description
        triggers = descriptor.triggers
        references = descriptor.references
    }
}

public interface SkillContentLoader {
    func read(contentRef: String): SkillResult<String>
}

public class SkillActivation {
    public let descriptor: SkillDescriptor
    public let instructions: String

    public init(descriptor: SkillDescriptor, instructions: String) {
        if (instructions.trimAscii() == "") {
            throw IllegalArgumentException("activated skill instructions must not be empty")
        }
        this.descriptor = descriptor
        this.instructions = instructions
    }
}

public class LoadedSkillReference {
    public let skillId: String
    public let referenceId: String
    public let content: String

    public init(skillId: String, referenceId: String, content: String) {
        if (content == "") {
            throw IllegalArgumentException("loaded skill reference must not be empty")
        }
        this.skillId = skillId
        this.referenceId = referenceId
        this.content = content
    }
}

public class SkillStackSnapshot {
    public let active: Array<SkillActivation>
    public let loadedReferences: Array<LoadedSkillReference>

    public init(
        active: Array<SkillActivation>,
        loadedReferences: Array<LoadedSkillReference>
    ) {
        this.active = active
        this.loadedReferences = loadedReferences
    }
}

public func skillStackSnapshotValue(snapshot: SkillStackSnapshot): JsonValue {
    let active = ArrayList<JsonValue>()
    for (activation in snapshot.active) {
        let references = ArrayList<JsonValue>()
        for (reference in activation.descriptor.references) {
            references.add(JsonValue.objectValue([
                JsonField("id", JsonValue.stringValue(reference.id)),
                JsonField("description", JsonValue.stringValue(reference.description)),
                JsonField("content_ref", JsonValue.stringValue(reference.contentRef))
            ]))
        }
        let triggers = ArrayList<JsonValue>()
        for (trigger in activation.descriptor.triggers) { triggers.add(JsonValue.stringValue(trigger)) }
        active.add(JsonValue.objectValue([
            JsonField("id", JsonValue.stringValue(activation.descriptor.id)),
            JsonField("name", JsonValue.stringValue(activation.descriptor.name)),
            JsonField("description", JsonValue.stringValue(activation.descriptor.description)),
            JsonField("triggers", JsonValue.arrayValue(triggers.toArray())),
            JsonField("instruction_ref", JsonValue.stringValue(activation.descriptor.instructionRef)),
            JsonField("instructions", JsonValue.stringValue(activation.instructions)),
            JsonField("references", JsonValue.arrayValue(references.toArray()))
        ]))
    }
    let loaded = ArrayList<JsonValue>()
    for (reference in snapshot.loadedReferences) {
        loaded.add(JsonValue.objectValue([
            JsonField("skill_id", JsonValue.stringValue(reference.skillId)),
            JsonField("reference_id", JsonValue.stringValue(reference.referenceId)),
            JsonField("content", JsonValue.stringValue(reference.content))
        ]))
    }
    JsonValue.objectValue([
        JsonField("active", JsonValue.arrayValue(active.toArray())),
        JsonField("loaded_references", JsonValue.arrayValue(loaded.toArray()))
    ])
}

public func skillStackFromSnapshotValue(value: JsonValue): SkillStackSnapshot {
    let activeValues = skillListField(value, "active")
    let active = ArrayList<SkillActivation>()
    for (item in activeValues.items) {
        let triggerValues = skillListField(item, "triggers")
        let triggers = ArrayList<String>()
        for (trigger in triggerValues.items) { triggers.add(skillText(trigger, "trigger")) }
        let referenceValues = skillListField(item, "references")
        let references = ArrayList<SkillReferenceDescriptor>()
        for (reference in referenceValues.items) {
            references.add(SkillReferenceDescriptor(
                skillTextField(reference, "id"), skillTextField(reference, "description"),
                skillTextField(reference, "content_ref")
            ))
        }
        let descriptor = SkillDescriptor(
            skillTextField(item, "id"), skillTextField(item, "name"),
            skillTextField(item, "description"), triggers.toArray(),
            skillTextField(item, "instruction_ref"), references: references.toArray()
        )
        active.add(SkillActivation(descriptor, skillTextField(item, "instructions")))
    }
    let loadedValues = skillListField(value, "loaded_references")
    let loaded = ArrayList<LoadedSkillReference>()
    for (item in loadedValues.items) {
        loaded.add(LoadedSkillReference(
            skillTextField(item, "skill_id"), skillTextField(item, "reference_id"),
            skillTextField(item, "content")
        ))
    }
    SkillStackSnapshot(active.toArray(), loaded.toArray())
}

public class JsonSkillSnapshotCodec <: SkillSnapshotCodec<JsonValue> {
    public init() {}
    public func encode(snapshot: SkillStackSnapshot): JsonValue { skillStackSnapshotValue(snapshot) }
    public func decode(value: JsonValue): SkillStackSnapshot { skillStackFromSnapshotValue(value) }
}

func skillListField(value: JsonValue, name: String): JsonValue {
    let item = match (value.field(name)) {
        case Some(candidate) => candidate
        case None => throw IllegalStateException("Skill snapshot field is missing: " + name)
    }
    if (value.kind != JsonKind.Object || item.kind != JsonKind.List) {
        throw IllegalStateException("Skill snapshot field is not a list: " + name)
    }
    item
}

func skillTextField(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => skillText(item, name)
        case None => throw IllegalStateException("Skill snapshot field is missing: " + name)
    }
}

func skillText(value: JsonValue, name: String): String {
    if (value.kind != JsonKind.Text) {
        throw IllegalStateException("Skill snapshot field is not text: " + name)
    }
    value.text
}

public class SkillRegistry {
    private let descriptors: Array<SkillDescriptor>

    public init(descriptors: Array<SkillDescriptor>) {
        for (index in 0..descriptors.size) {
            for (other in index + 1..descriptors.size where
                descriptors[index].id == descriptors[other].id ||
                descriptors[index].name == descriptors[other].name) {
                throw IllegalArgumentException("skill registry contains duplicate skill identity")
            }
        }
        this.descriptors = descriptors
    }

    public func metadata(): Array<SkillMetadata> {
        let values = ArrayList<SkillMetadata>()
        for (descriptor in descriptors) { values.add(SkillMetadata(descriptor)) }
        values.toArray()
    }

    public func find(id: String): ?SkillDescriptor {
        for (descriptor in descriptors where descriptor.id == id) { return Some(descriptor) }
        None
    }
}

// SkillStack is scoped to one Run. It has no CapabilitySet and cannot widen
// policy, approval, or sandbox authority.
public class SkillStack {
    private let lock = Mutex()
    private let registry: SkillRegistry
    private let loader: SkillContentLoader
    private let active = ArrayList<SkillActivation>()
    private let references = ArrayList<LoadedSkillReference>()

    public init(registry: SkillRegistry, loader: SkillContentLoader) {
        this.registry = registry
        this.loader = loader
    }

    public func metadata(): Array<SkillMetadata> { registry.metadata() }

    public func activate(id: String): SkillResult<SkillActivation> {
        lock.lock()
        try {
            for (activation in active where activation.descriptor.id == id) {
                return SkillResult.Ok(activation)
            }
            let descriptor = match (registry.find(id)) {
                case Some(value) => value
                case None => return skillError(
                    "skill.not_found", "requested skill is not registered"
                )
            }
            let instructions = match (loader.read(descriptor.instructionRef)) {
                case SkillResult.Ok(value) => value
                case SkillResult.Err(error) => return SkillResult.Err(error)
            }
            if (instructions.trimAscii() == "") {
                return skillError("skill.instructions_empty", "skill instructions are empty")
            }
            let activation = SkillActivation(descriptor, instructions)
            active.add(activation)
            SkillResult.Ok(activation)
        } finally {
            lock.unlock()
        }
    }

    public func readReference(skillId: String, referenceId: String): SkillResult<LoadedSkillReference> {
        lock.lock()
        try {
            for (loaded in references where loaded.skillId == skillId &&
                loaded.referenceId == referenceId) { return SkillResult.Ok(loaded) }
            let activation = activeActivation(skillId)
            if (activation.isNone()) {
                return skillError(
                    "skill.not_active", "skill must be activated before reading references"
                )
            }
            var descriptor: ?SkillReferenceDescriptor = None
            for (candidate in activation.getOrThrow().descriptor.references where
                candidate.id == referenceId) { descriptor = Some(candidate); break }
            let selected = match (descriptor) {
                case Some(value) => value
                case None => return skillError(
                    "skill.reference_not_declared",
                    "skill reference is not declared by the active skill"
                )
            }
            let content = match (loader.read(selected.contentRef)) {
                case SkillResult.Ok(value) => value
                case SkillResult.Err(error) => return SkillResult.Err(error)
            }
            if (content == "") {
                return skillError("skill.reference_empty", "skill reference is empty")
            }
            let loaded = LoadedSkillReference(skillId, referenceId, content)
            references.add(loaded)
            SkillResult.Ok(loaded)
        } finally {
            lock.unlock()
        }
    }

    public func snapshot(): SkillStackSnapshot {
        lock.lock()
        try { SkillStackSnapshot(active.toArray(), references.toArray()) }
        finally { lock.unlock() }
    }

    private func activeActivation(id: String): ?SkillActivation {
        for (activation in active where activation.descriptor.id == id) {
            return Some(activation)
        }
        None
    }
}

func skillError<T>(code: String, message: String): SkillResult<T> {
    SkillResult.Err(SkillError(code, message))
}
