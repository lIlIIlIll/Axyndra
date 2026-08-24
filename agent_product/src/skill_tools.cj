package agent_product

import agent_domain.*
import tool_runtime.*

class SkillReferenceTool <: ToolExecutor {
    private let runtime: ProductSkillRuntime

    init(runtime: ProductSkillRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let skillId = skillToolString(call, "skill_id")
        let referenceId = skillToolString(call, "reference_id")
        if (skillId == "" || referenceId == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "skill.reference_arguments_invalid",
                "skill_id and reference_id are required"
            ))
        }
        match (runtime.readReference(context.skills, skillId, referenceId)) {
            case Result.Ok(reference) => Result.Ok(ToolResult(
                call.callId,
                objectValue([
                    ValueField("content", textValue(reference.content)),
                    ValueField("skill_id", textValue(reference.skillId)),
                    ValueField("reference_id", textValue(reference.referenceId))
                ])
            ))
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func skillReferenceDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "read_skill_reference",
        "Read one declared reference from a Skill already active in this Run. " +
            "This loads context only and never grants capabilities.",
        objectSchema([
            schemaProperty("skill_id", "string"),
            schemaProperty("reference_id", "string")
        ], ["skill_id", "reference_id"])
    )
}

func registerSkillReferenceTool(
    catalog: ToolCatalog,
    runtime: ProductSkillRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            skillReferenceDefinition(),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        SkillReferenceTool(runtime)
    )
}

func skillToolString(call: ToolCall, name: String): String {
    match (call.arguments.field(name)) {
        case Some(value) => if (value.kind == ValueKind.Text) {
            value.text.trimAscii()
        } else {
            ""
        }
        case None => ""
    }
}
