package agent_product

import agent_plugin_registry.*

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

let PLUGIN_FILE_PLAN_TOOL = agent_host_runtime.PLUGIN_FILE_PLAN_TOOL
let PLUGIN_FILE_PLAN_PROPOSAL_BYTES: Int64 = agent_host_runtime.PLUGIN_FILE_PLAN_PROPOSAL_BYTES

// Shared by the connection-bound identity adapter and the executor. The
// plugin can propose file contents, never the origin of the host artifact.
func validatePluginFilePlanProposal(proposal: AgentValue): Result<Unit> {
    agent_host_runtime.hostValidatePluginFilePlanProposal(proposal)
}

func registerPluginFilePlanService(
    catalog: ToolCatalog,
    host: ProductJavaScriptPluginHost,
    operations: OperationRuntimePort,
    workspace: LocalWorkspace,
    artifacts: ProductArtifactStore
): Result<Unit> {
    catalog.register(ToolDescriptor(
        ModelToolDefinition(PLUGIN_FILE_PLAN_TOOL,
            "Validate a plugin file proposal and store an immutable plan without modifying workspace files.",
            objectSchema([
                schemaProperty("plugin", "string"), schemaProperty("generation", "string"),
                schemaProperty("package_digest", "string"), schemaProperty("proposal", "object"), schemaProperty("managed_binding", "object")
            ], ["plugin", "generation", "package_digest", "proposal"])
        ),
        Capability(CapabilityKind.WorkspaceRead, resource: workspace.rootPath()), hostServiceOnly: true,
        implementationVersion: "host-file-plan-v2", implementationFingerprint: "host-file-plan-v2",
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })
    ), PluginFilePlanProposeExecutor(host, operations, workspace, artifacts))
}

class PluginFilePlanProposeExecutor <: ToolExecutor {
    private let host: ProductJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let workspace: LocalWorkspace
    private let artifacts: ProductArtifactStore

    init(host: ProductJavaScriptPluginHost, operations: OperationRuntimePort,
        workspace: LocalWorkspace, artifacts: ProductArtifactStore) {
        this.host = host
        this.operations = operations
        this.workspace = workspace
        this.artifacts = artifacts
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            prepared.source.parentOperationId.isNone() || prepared.source.operationRoot.isNone() ||
            prepared.call.name != PLUGIN_FILE_PLAN_TOOL ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return pluginProcessError("application_plan.source_invalid", "file.plan.propose requires an admitted read-only plugin child Operation")
        }
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let arguments = prepared.operationPlan.canonicalArguments
        if (!applicationPlanObjectShape(arguments,
            ["plugin", "generation", "package_digest", "proposal", "managed_binding"],
            ["plugin", "generation", "package_digest", "proposal"])) {
            return pluginProcessError("application_plan.source_invalid", "file plan service arguments are not connection-bound")
        }
        let proposal = arguments.field("proposal").getOrThrow()
        match (validatePluginFilePlanProposal(proposal)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let namespace = pluginReceiptText(arguments, "plugin")
        let generation = try { UInt64.parse(pluginReceiptText(arguments, "generation")) }
            catch (_: Exception) { return pluginProcessError("plugin.instance_stale", "invalid plugin generation") }
        let descriptor = match (host.servicePackage(namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let parentId = prepared.source.parentOperationId.getOrThrow()
        let parent = match (operations.loadPlan(parentId, context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let root = prepared.source.operationRoot.getOrThrow()
        if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)) == "" ||
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)) != pluginReceiptText(arguments, "package_digest") ||
            !pluginFilePlanParentIdentity(parent, arguments, namespace, productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest))) ||
            parent.toolName != root.toolName() || !parent.toolName.startsWith("plugin." + namespace + ".") ||
            context.workspaceRoot != workspace.rootPath()) {
            return pluginProcessError("application_plan.source_mismatch", "file plan origin must match the frozen parent and workspace")
        }
        let source = objectValue([
            ValueField("kind", textValue("plugin")),
            ValueField("run_id", textValue(context.runId.value)),
            ValueField("root_operation_id", textValue(parentId.value)),
            ValueField("generation_operation_id", textValue(prepared.operationId.value)),
            ValueField("plugin_namespace", textValue(namespace)),
            ValueField("plugin_version", textValue(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Version)))),
            ValueField("package_digest", textValue(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)))),
            ValueField("contribution", textValue(parent.toolName)),
            ValueField("instance_generation", textValue(generation.toString())),
            ValueField("workspace_id", textValue("workspace:sha256:" + artifactSha256(workspace.rootPath().toArray())))
        ])
        if (arguments.field("managed_binding").isSome()) {
            source.put("parent_implementation_fingerprint", textValue(parent.implementation.implementationFingerprint))
        }
        let summary = match (generateProductApplicationPlanFromOrigin(proposal, source, workspace, artifacts)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        // Immutable internal artifacts may remain after cancellation, but a
        // cancelled/revoked invocation never publishes a successful result or
        // applies workspace writes. Applying needs a separate authorized root.
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (host.servicePackage(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        Result.Ok(ToolResult(prepared.call.callId, summary))
    }
}

func validateStoredApplicationPlanSource(source: AgentValue, schema: String): Result<Unit> {
    if (schema == PRODUCT_FILE_APPLICATION_PLAN_SCHEMA) {
        if (!applicationPlanObjectShape(source,
            ["root_operation_id", "program_id", "program_digest"],
            ["root_operation_id", "program_id", "program_digest"])) {
            return pluginPlanSourceError()
        }
        let rootId = pluginReceiptText(source, "root_operation_id")
        let digest = pluginReceiptText(source, "program_digest")
        if (rootId.trimAscii() == "" || digest == "" ||
            pluginReceiptText(source, "program_id") != PRODUCT_ARTIFACT_PREFIX + digest) {
            return pluginPlanSourceError()
        }
        return Result.Ok(())
    }
    let required = ["kind", "run_id", "root_operation_id", "generation_operation_id", "plugin_namespace",
        "plugin_version", "package_digest", "contribution", "instance_generation"]
    let allowed = ArrayList<String>(required)
    allowed.add("parent_implementation_fingerprint")
    allowed.add("recovery_operation_id")
    allowed.add("recovery_run_id")
    if (schema != PRODUCT_PLUGIN_FILE_APPLICATION_PLAN_SCHEMA ||
        !applicationPlanObjectShape(source, allowed.toArray(), required) ||
        pluginReceiptText(source, "kind") != "plugin") {
        return pluginPlanSourceError()
    }
    if (source.field("recovery_operation_id").isSome() != source.field("recovery_run_id").isSome()) {
        return pluginPlanSourceError()
    }
    for (field in source.fields) {
        if (field.value.unifiedKind != ValueKind.Text || field.value.text.trimAscii() == "" ||
            field.value.text.size > 4096 || field.value.text.contains("\u{0000}")) {
            return pluginPlanSourceError()
        }
    }
    let namespace = pluginReceiptText(source, "plugin_namespace")
    if (!pluginReceiptText(source, "contribution").startsWith("plugin." + namespace + ".") ||
        pluginReceiptText(source, "root_operation_id") == pluginReceiptText(source, "generation_operation_id")) {
        return pluginPlanSourceError()
    }
    let generation = try { UInt64.parse(pluginReceiptText(source, "instance_generation")) }
        catch (_: Exception) { return pluginPlanSourceError() }
    if (generation == 0u64) { return pluginPlanSourceError() }
    let digest = pluginReceiptText(source, "package_digest")
    if (!digest.startsWith("sha256:") || digest.size != 71) { return pluginPlanSourceError() }
    for (byte in digest[7..].toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return pluginPlanSourceError() }
    }
    Result.Ok(())
}

func pluginPlanSourceError(): Result<Unit> {
    applicationPlanError<Unit>(AgentErrorKind.Conflict, "application_plan.source_invalid",
        "the immutable application plan source is invalid or inconsistent")
}

func productApplicationRecoverySource(source: AgentValue, workspaceId: AgentValue,
    recoveryId: OperationId, recoveryRunId: RunId): AgentValue {
    if (source.field("kind").isNone()) {
        // Preserve the already-supported v1 Program continuation format.
        return objectValue([
            ValueField("root_operation_id", textValue(recoveryId.value)),
            ValueField("program_id", source.field("program_id").getOrThrow()),
            ValueField("program_digest", source.field("program_digest").getOrThrow()),
            ValueField("workspace_id", workspaceId)
        ])
    }
    let fields = ArrayList<ValueField>()
    for (field in source.fields where field.name != "recovery_operation_id" && field.name != "recovery_run_id") { fields.add(field) }
    fields.add(ValueField("recovery_operation_id", textValue(recoveryId.value)))
    fields.add(ValueField("recovery_run_id", textValue(recoveryRunId.value)))
    fields.add(ValueField("workspace_id", workspaceId))
    objectValue(fields.toArray())
}

// Content addressing proves bytes, not authorization. A v2 plan must also be
// the exact output of a completed admitted host proposal (or of an explicitly
// committed recovery). Orphan artifacts left by cancellation cannot satisfy
// this check, even if their digest is known or recomputed by the caller.
func validatePluginApplicationPlanEvidence(
    stored: ProductStoredFileApplicationPlan,
    runtime: ?OperationRuntimePort
): Result<Unit> {
    if (pluginReceiptText(stored.plan, "schema") == PRODUCT_FILE_APPLICATION_PLAN_SCHEMA) {
        return validateProgramApplicationPlanEvidence(stored, runtime)
    }
    let port = match (runtime) {
        case Some(value) => value
        case None => return pluginPlanEvidenceError()
    }
    let source = stored.plan.field("source").getOrThrow()
    let runId = RunId(pluginReceiptText(source, "run_id"))
    let parentId = OperationId(pluginReceiptText(source, "root_operation_id"))
    let generationId = OperationId(pluginReceiptText(source, "generation_operation_id"))
    let parent = match (port.loadPlan(parentId, runId)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return pluginPlanEvidenceError()
    }
    if (parent.toolName != pluginReceiptText(source, "contribution")) { return pluginPlanEvidenceError() }
    let parentResult = match (port.loadCommittedToolResult(parentId, runId)) {
        case Result.Ok(Some(value)) => value
        case _ => return pluginPlanEvidenceError()
    }
    if (parentResult.isError) { return pluginPlanEvidenceError() }
    let generation = match (port.loadPlan(generationId, runId)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return pluginPlanEvidenceError()
    }
    if (generation.toolName != PLUGIN_FILE_PLAN_TOOL ||
        generation.effectClass != OperationEffectClass.ReadOnly ||
        !networkPolicyModeIsDenied(generation.networkPolicy.mode) ||
        pluginReceiptText(generation.canonicalArguments, "plugin") != pluginReceiptText(source, "plugin_namespace") ||
        pluginReceiptText(generation.canonicalArguments, "package_digest") != pluginReceiptText(source, "package_digest") ||
        pluginReceiptText(generation.canonicalArguments, "generation") != pluginReceiptText(source, "instance_generation")) {
        return pluginPlanEvidenceError()
    }
    if (!pluginFilePlanParentIdentity(parent, generation.canonicalArguments,
        pluginReceiptText(source, "plugin_namespace"), pluginReceiptText(source, "package_digest")) ||
        (generation.canonicalArguments.field("managed_binding").isSome() &&
            pluginReceiptText(source, "parent_implementation_fingerprint") != parent.implementation.implementationFingerprint) ||
        (generation.canonicalArguments.field("managed_binding").isNone() && source.field("parent_implementation_fingerprint").isSome())) {
        return pluginPlanEvidenceError()
    }
    let receipt = match (port.loadDerivedOperationReceipt(generationId, runId)) {
        case Result.Ok(Some(value)) => value
        case _ => return pluginPlanEvidenceError()
    }
    if (receipt.outcome != OperationOutcome.Completed ||
        pluginReceiptText(receipt.verification, "parent_operation_id") != parentId.value ||
        pluginReceiptText(receipt.verification, "service") != "file.plan.propose" ||
        pluginReceiptText(receipt.detail, "tool") != PLUGIN_FILE_PLAN_TOOL) {
        return pluginPlanEvidenceError()
    }
    let original = match (receipt.detail.field("output")) {
        case Some(value) => value
        case None => return pluginPlanEvidenceError()
    }
    let originalSource = match (original.field("source")) {
        case Some(value) => value
        case None => return pluginPlanEvidenceError()
    }
    let originFields = ArrayList<ValueField>()
    for (field in source.fields where field.name != "recovery_operation_id" && field.name != "recovery_run_id") {
        originFields.add(field)
    }
    if (canonicalAgentValue(originalSource) != canonicalAgentValue(objectValue(originFields.toArray()))) {
        return pluginPlanEvidenceError()
    }
    var expected = original
    if (source.field("recovery_operation_id").isSome()) {
        let recoveryId = OperationId(pluginReceiptText(source, "recovery_operation_id"))
        let recoveryRunId = RunId(pluginReceiptText(source, "recovery_run_id"))
        let recoveryPlan = match (port.loadPlan(recoveryId, recoveryRunId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return pluginPlanEvidenceError()
        }
        if (!isVerifiedApplicationPlanRecovery(recoveryPlan)) { return pluginPlanEvidenceError() }
        let recoveryResult = match (port.loadCommittedToolResult(recoveryId, recoveryRunId)) {
            case Result.Ok(Some(value)) => value
            case _ => return pluginPlanEvidenceError()
        }
        if (recoveryResult.isError) { return pluginPlanEvidenceError() }
        expected = match (recoveryResult.output.field("continuation_plan")) {
            case Some(value) => value
            case None => return pluginPlanEvidenceError()
        }
    }
    if (pluginReceiptText(expected, "plan_ref") != stored.planRef ||
        pluginReceiptText(expected, "plan_digest") != stored.planDigest) {
        return pluginPlanEvidenceError()
    }
    Result.Ok(())
}

func pluginPlanEvidenceError(): Result<Unit> {
    applicationPlanError<Unit>(AgentErrorKind.Conflict, "application_plan.origin_uncommitted",
        "the file plan has no matching completed generation and canonical parent or recovery result")
}

// The original v1 format remains readable, but its Program claim must also be
// backed by canonical facts. Otherwise changing a v2 schema/source and hashing
// the resulting bytes would turn the old format into an authorization bypass.
func validateProgramApplicationPlanEvidence(
    stored: ProductStoredFileApplicationPlan,
    runtime: ?OperationRuntimePort
): Result<Unit> {
    let port = match (runtime) {
        case Some(value) => value
        case None => return pluginPlanEvidenceError()
    }
    let source = stored.plan.field("source").getOrThrow()
    let rootId = OperationId(pluginReceiptText(source, "root_operation_id"))
    let runId = match (port.operationRunId(rootId)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return pluginPlanEvidenceError()
    }
    let root = match (port.loadPlan(rootId, runId)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return pluginPlanEvidenceError()
    }
    let result = match (port.loadCommittedToolResult(rootId, runId)) {
        case Result.Ok(Some(value)) => value
        case _ => return pluginPlanEvidenceError()
    }
    if (result.isError) { return pluginPlanEvidenceError() }
    let expected = if (root.toolName == "run_program") {
        let code = match (root.canonicalArguments.field("source")) {
            case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text }
                else { return pluginPlanEvidenceError() }
            case None => return pluginPlanEvidenceError()
        }
        let digest = artifactSha256(code.toArray())
        if (pluginReceiptText(source, "program_digest") != digest ||
            pluginReceiptText(source, "program_id") != PRODUCT_ARTIFACT_PREFIX + digest) {
            return pluginPlanEvidenceError()
        }
        let value = match (result.output.field("value")) {
            case Some(value) => value
            case None => return pluginPlanEvidenceError()
        }
        match (value.field("application_plan")) {
            case Some(value) => value
            case None => return pluginPlanEvidenceError()
        }
    } else if (isVerifiedApplicationPlanRecovery(root)) {
        match (result.output.field("continuation_plan")) {
            case Some(value) => value
            case None => return pluginPlanEvidenceError()
        }
    } else { return pluginPlanEvidenceError() }
    if (pluginReceiptText(expected, "plan_ref") != stored.planRef ||
        pluginReceiptText(expected, "plan_digest") != stored.planDigest) {
        return pluginPlanEvidenceError()
    }
    Result.Ok(())
}

func isVerifiedApplicationPlanRecovery(plan: NormalizedOperationPlan): Bool {
    // Older recovery implementations checked content addressing, not the
    // original generator's canonical facts. Their successful output cannot
    // attest provenance. Keep those artifacts readable, but do not turn an
    // unverified legacy continuation into a newly trusted plan on upgrade.
    plan.toolName == "recover_file_plan" &&
        plan.implementation.implementationFingerprint == PRODUCT_FILE_RECOVERY_IMPLEMENTATION
}

// Static native tools retain their original package binding. Owned service
// contributions must instead match the exact durable channel parent and its
// copied host binding. A source/fingerprint string alone never satisfies this.
func pluginFilePlanParentIdentity(parent: NormalizedOperationPlan, arguments: AgentValue,
    namespace: String, packageDigest: String): Bool {
    if (arguments.field("managed_binding").isNone()) {
        return parent.implementation.implementationFingerprint == namespace + ":" + packageDigest
    }
    if (!isFrozenChannelParentPlan(parent) || !pluginPlanRequires(parent, CapabilityKind.WorkspaceRead) ||
        !pluginPlanRequires(parent, CapabilityKind.ExtensionInvoke)) { return false }
    let actual = parent.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    canonicalAgentValue(arguments.field("managed_binding").getOrThrow()) == canonicalAgentValue(actual) &&
        pluginReceiptText(actual, "plugin") == namespace && pluginReceiptText(actual, "package_digest") == packageDigest &&
        parent.implementation.implementationFingerprint == pluginReceiptText(actual, "implementation_fingerprint")
}
