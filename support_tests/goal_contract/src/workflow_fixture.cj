package goal_contract

import agent_domain.*
import agent_plugin_registry
import agent_product.*
import std.env.*
import std.fs.*
import tool_runtime.*
import yjson.*
import yjson_support.*

class GoalRegistryCopyDebt {
    let payment: LogicalJsonOwnerReservation
    let previous: ?GoalRegistryCopyDebt
    init(payment: LogicalJsonOwnerReservation, previous: ?GoalRegistryCopyDebt) {
        this.payment = payment
        this.previous = previous
    }
}
var goalRegistryCopyDebt: ?GoalRegistryCopyDebt = None<GoalRegistryCopyDebt>

func goalRegistryText(result: agent_plugin_registry.PluginRegistryResult<agent_plugin_registry.OwnedRegistryUtf8>): String {
    let source = match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("registry descriptor copy failed")
    }
    try {
        let size = source.byteCount
        if (size < 0 || size > (134217728 - 8192) / 64) {
            throw LogicalJsonPayloadError("fixture registry copy exceeds the original shared capacity")
        }
        let payment = source.deriveCopiedDataPayment(size * 64 + 8192)
        goalRegistryCopyDebt = Some(GoalRegistryCopyDebt(payment, goalRegistryCopyDebt))
        String.fromUtf8(Array<UInt8>(size, { index => source.byteAt(index) }))
    } finally { source.close() }
}

func openGoalContractProduct(root: String): ProductRuntime {
    if (!exists(Path(root))) { Directory.create(root, recursive: true) }
    openProduct(config: ProductConfig(
        settingsRoot: root + "/settings",
        stateRoot: root + "/state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
}

func installGoalContractWorkflow(product: ProductRuntime): String {
    let record = match (product.importLocalPlugin(
        getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow(),
        PluginInstallScope.Workspace
    )) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("workflow goal package import failed")
    }
    try {
        let namespace = goalRegistryText(record.descriptor.copyText(PluginDescriptorText.Namespace))
        let digest = goalRegistryText(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
        let directory = product.settingsRoot + "/plugins"
        if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
        let right = objectValue([
            ValueField("key", textValue("goal")),
            ValueField("read", boolValue(true)),
            ValueField("write", boolValue(true))
        ])
        File.writeTo(directory + "/documents.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)),
            ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(namespace)),
                ValueField("package_digest", textValue(digest)),
                ValueField("tools", listValue([objectValue([
                    ValueField("name", textValue("goal")),
                    ValueField("preparation_provider", textValue("prepare_document")),
                    ValueField("documents", listValue([right]))
                ])]))
            ])]))
        ])).toArray())
        File.writeTo(directory + "/goal-tools.json", stringifyUnifiedJson(objectValue([
            ValueField("schema", textValue("axyndra.goal-tools/v1")),
            ValueField("namespace", textValue(namespace)),
            ValueField("package_digest", textValue(digest)),
            ValueField("tool", textValue("goal")),
            ValueField("command", textValue("goal"))
        ])).toArray())
        // Goal content is resolved by the real Run's canonical document read,
        // not by a request-time legacy metadata projection.
        File.writeTo(directory + "/context.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(5)),
            ValueField("namespace", textValue(namespace)),
            ValueField("package_digest", textValue(digest)),
            ValueField("provider", textValue("goal_context")),
            ValueField("resources", listValue([textValue("goal")])),
            ValueField("query", objectValue([
                ValueField("schema", textValue("axyndra.goal-context-query/v1"))
            ])),
            ValueField("prompt_field", textValue(""))
        ])).toArray())
        File.writeTo(directory + "/document-context.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)),
            ValueField("providers", listValue([objectValue([
                ValueField("namespace", textValue(namespace)),
                ValueField("package_digest", textValue(digest)),
                ValueField("provider", textValue("goal_context")),
                ValueField("keys", listValue([textValue("goal")]))
            ])]))
        ])).toArray())
        match (product.setPluginEnabled(namespace, true, PluginInstallScope.Workspace)) {
            case PluginRegistryResult.Ok(enabled) => enabled.close()
            case PluginRegistryResult.Err(_) => throw IllegalStateException("workflow goal package enable failed")
        }
        namespace
    } finally { record.close() }
}

func goalContractToolCall(namespace: String, id: String, op: String,
    fields!: Array<ValueField> = []): ToolCall {
    let arguments = objectValue([ValueField("op", textValue(op))])
    for (field in fields) { arguments.put(field.name, field.value) }
    ToolCall(id, "plugin." + namespace + ".goal", arguments)
}

func canonicalGoalOperation(product: ProductRuntime, namespace: String,
    session: SessionId, call: ToolCall): Result<ToolInvocationResult> {
    product.vnext.executeCanonicalTool(session,
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: namespace)]),
        call, budget: ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
}

func completedGoalOperation(product: ProductRuntime, namespace: String,
    session: SessionId, call: ToolCall): ToolResult {
    match (canonicalGoalOperation(product, namespace, session, call)) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            if (value.isError) {
                try { throw IllegalStateException("canonical goal operation failed: " + stringifyUnifiedJson(value.output)) }
                finally { value.releasePayload() }
            }
            value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("canonical goal operation did not complete")
    }
}

func rejectedGoalOperation(product: ProductRuntime, namespace: String,
    session: SessionId, call: ToolCall): Bool {
    match (canonicalGoalOperation(product, namespace, session, call)) {
        case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            try { value.isError } finally { value.releasePayload() }
        case _ => false
    }
}

func requireGoalContractResult<T>(result: Result<T>): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
    }
}
