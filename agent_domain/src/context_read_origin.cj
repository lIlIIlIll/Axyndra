package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

// Descriptive durable data only. Runtime's current owner must mint the sealed
// admission and Store must verify the exact read plan. Decoding this DTO cannot
// grant a read, create an Operation source, or authorize a later write.
public class ContextReadOrigin {
    public let ownerNamespace: String
    public let packageDigest: String
    public let configurationDigest: String
    public let projectionDigest: String
    public let readPlanDigest: String
    public let requestId: String
    public let parentCallItemId: String
    public let parentKind: String
    public let parentOperationId: String
    public let parentDecisionId: String
    public let parentScopedCallId: String

    public init(ownerNamespace: String, packageDigest: String, configurationDigest: String,
        projectionDigest: String, readPlanDigest: String, requestId: String, parentCallItemId: String,
        parentDecisionId!: String = "", parentScopedCallId!: String = "",
        parentKind!: String = "", parentOperationId!: String = "") {
        if (!directOriginIdentifier(ownerNamespace, 256) || packageDigest.size != 71 ||
            !packageDigest.startsWith("sha256:") || !directOriginDigest(packageDigest[7..]) ||
            !directOriginDigest(configurationDigest) || !directOriginDigest(projectionDigest) ||
            !directOriginDigest(readPlanDigest) || !directOriginIdentifier(requestId, 128) ||
            parentCallItemId.size > 512 || parentCallItemId.contains("\u{0000}") ||
            (parentCallItemId == "" && (parentKind != "" || parentOperationId != "" || parentDecisionId != "" || parentScopedCallId != "")) ||
            (parentCallItemId != "" && !(
                (parentKind == "committed" && parentOperationId == "" && directOriginIdentifier(parentDecisionId, 512) && directOriginIdentifier(parentScopedCallId, 512)) ||
                (parentKind == "direct" && directOriginIdentifier(parentOperationId, 512) && parentDecisionId == "" && parentScopedCallId == "")))) {
            throw IllegalArgumentException("context read origin requires exact bounded host bindings")
        }
        this.ownerNamespace = ownerNamespace; this.packageDigest = packageDigest
        this.configurationDigest = configurationDigest; this.projectionDigest = projectionDigest
        this.readPlanDigest = readPlanDigest; this.requestId = requestId; this.parentCallItemId = parentCallItemId
        this.parentDecisionId = parentDecisionId; this.parentScopedCallId = parentScopedCallId
        this.parentKind = parentKind; this.parentOperationId = parentOperationId
    }
}

public func contextReadOriginValue(value: ContextReadOrigin): AgentValue {
    objectValue([
        ValueField("schema", textValue("axyndra.direct-origin/v4")), ValueField("kind", textValue("context_read")),
        ValueField("owner_namespace", textValue(value.ownerNamespace)), ValueField("package_digest", textValue(value.packageDigest)),
        ValueField("configuration_digest", textValue(value.configurationDigest)), ValueField("projection_digest", textValue(value.projectionDigest)),
        ValueField("read_plan_digest", textValue(value.readPlanDigest)), ValueField("request_id", textValue(value.requestId)),
        ValueField("parent_call_item_id", textValue(value.parentCallItemId)),
        ValueField("parent_kind", textValue(value.parentKind)), ValueField("parent_operation_id", textValue(value.parentOperationId)),
        ValueField("parent_decision_id", textValue(value.parentDecisionId)), ValueField("parent_scoped_call_id", textValue(value.parentScopedCallId))])
}

public func contextReadOriginFromValue(value: AgentValue): ContextReadOrigin {
    let fields = ["schema", "kind", "owner_namespace", "package_digest", "configuration_digest", "projection_digest",
        "read_plan_digest", "request_id", "parent_call_item_id", "parent_decision_id", "parent_scoped_call_id", "parent_kind", "parent_operation_id"]
    if (value.unifiedKind != ValueKind.Object || value.fields.size != fields.size) {
        throw IllegalArgumentException("context read origin has unsupported fields")
    }
    let observed = HashSet<String>()
    for (field in value.fields) {
        if (!fields.contains(field.name) || observed.contains(field.name) || field.value.unifiedKind != ValueKind.Text) {
            throw IllegalArgumentException("context read origin field is repeated, unknown or not text")
        }
        observed.add(field.name)
    }
    if (directOriginText(value, "schema") != "axyndra.direct-origin/v4" || directOriginText(value, "kind") != "context_read") {
        throw IllegalArgumentException("unsupported context read origin schema")
    }
    ContextReadOrigin(directOriginText(value, "owner_namespace"), directOriginText(value, "package_digest"),
        directOriginText(value, "configuration_digest"), directOriginText(value, "projection_digest"),
        directOriginText(value, "read_plan_digest"), directOriginText(value, "request_id"), directOriginText(value, "parent_call_item_id"),
        parentDecisionId: directOriginText(value, "parent_decision_id"), parentScopedCallId: directOriginText(value, "parent_scoped_call_id"),
        parentKind: directOriginText(value, "parent_kind"), parentOperationId: directOriginText(value, "parent_operation_id"))
}

public let HOST_CONTEXT_READ_TOOL = "host.context.read"
public let HOST_CONTEXT_READ_IMPLEMENTATION = "host-context-read-v3"

// This shape narrows authority; successful policy/approval and the live source
// are still independently required. It cannot become a transport or write root.
public func isContextReadPlan(plan: NormalizedOperationPlan): Bool {
    if (plan.toolName != HOST_CONTEXT_READ_TOOL ||
        plan.implementation.implementationFingerprint != HOST_CONTEXT_READ_IMPLEMENTATION ||
        plan.implementation.toolVersion != HOST_CONTEXT_READ_IMPLEMENTATION ||
        plan.effectClass != OperationEffectClass.ReadOnly ||
        plan.networkPolicy.mode != NetworkPolicyMode.Denied ||
        plan.retryDisposition != OperationRetryDisposition.Never ||
        plan.requiredCapabilities.isEmpty() || !plan.contextReadFacts.isEmpty() ||
        !plan.resolvedHosts.isEmpty() || plan.approvalMetadata.writeSummary.isSome()) { return false }
    match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => (); case _ => return false }
    if (httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_PEER_READ111) {
        return pluginPeerReadAuthority111(plan) }
    // The declared new dialect is closed even when its binding is malformed;
    // it must never fall back to the generic WorkspaceRead shape.
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA){
        return pluginDocumentJournalStreamReadAuthority(plan)}
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_JOURNAL_STREAM_READ_SCHEMA){
        return pluginDocumentContextJournalStreamReadAuthority(plan)}
    // Explicitly declared v3 schemas never fall back to filesystem reads,
    // including when their untrusted binding or either frozen digest is bad.
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return pluginDocumentLatestJournalStreamReadAuthority(plan)}
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return pluginDocumentContextLatestJournalStreamReadAuthority(plan)}
    if(pluginDocumentRowJournalReadRequestValid(plan.canonicalArguments)){
        return pluginDocumentRowJournalReadAuthority(plan)}
    if(pluginDocumentContextWindowReadRequestValid(plan.canonicalArguments)){
        return pluginDocumentContextWindowReadAuthority(plan)}
    if (pluginDocumentReadRequestValid(plan.canonicalArguments)) {
        return pluginDocumentReadAuthority(plan)
    }
    for (capability in plan.requiredCapabilities where capability.kind != CapabilityKind.WorkspaceRead) { return false }
    true
}

public func contextReadProjectionDigest(projection: InvocationContextProjection): String {
    modelPolicySha256Text(canonicalAgentValue(contextSnapshotValue(projection)))
}

public func isContextReadItem(item: ThreadItem): Bool {
    match (item.provenance.directOrigin) { case Some(DirectCallOrigin.ContextRead(_)) => true; case _ => false }
}

// Complete authority projection for this deliberately narrow plan kind. The
// caller-provided bindingDigest alone is not proof that other fields agree.
public func contextReadPlanDigest(plan: NormalizedOperationPlan): String {
    if (!isContextReadPlan(plan)) { throw IllegalArgumentException("invalid context read plan") }
    let capabilities = ArrayList<AgentValue>()
    let peerRead = pluginPeerReadRequestValid111(plan.canonicalArguments)
    let documentRead = pluginDocumentLatestJournalStreamReadRequestValid(plan.canonicalArguments) ||
        pluginDocumentContextLatestJournalStreamReadRequestValid(plan.canonicalArguments) ||
        pluginDocumentReadRequestValid(plan.canonicalArguments) ||
        pluginDocumentRowJournalReadRequestValid(plan.canonicalArguments) ||
        pluginDocumentContextWindowReadRequestValid(plan.canonicalArguments) ||
        pluginDocumentJournalStreamReadRequestValid(plan.canonicalArguments) ||
        pluginDocumentContextJournalStreamReadRequestValid(plan.canonicalArguments)
    for (required in plan.requiredCapabilities) {
        if (peerRead) {
            capabilities.add(objectValue([ValueField("kind",textValue(if(required.kind==CapabilityKind.PeerMessage) {
                "peer.message" } else { "extension.invoke" })),ValueField("resource",textValue(required.resource))]))
            continue
        }
        capabilities.add(if (documentRead) { objectValue([ValueField("kind", textValue("extension.invoke")),
            ValueField("resource", textValue(required.resource))]) } else { textValue(required.resource) })
    }
    let paths = ArrayList<AgentValue>()
    for (path in plan.resolvedPaths) { paths.add(textValue(path)) }
    let metadata = plan.approvalMetadata
    let flags = ArrayList<AgentValue>(); let reasons = ArrayList<AgentValue>()
    for (value in metadata.assessment.flags) { flags.add(textValue(value)) }
    for (value in metadata.assessment.reasons) { reasons.add(textValue(value)) }
    let value = objectValue([ValueField("version", textValue(if (peerRead) { "context-peer-read-plan/v1" } else if (documentRead) { "context-document-read-plan/v1" } else { "context-read-plan/v1" })),
        ValueField("tool", textValue(plan.toolName)), ValueField("arguments", plan.canonicalArguments),
        ValueField("capabilities", listValue(capabilities.toArray())), ValueField("paths", listValue(paths.toArray())),
        ValueField("network", networkPolicyCanonicalValue(plan.networkPolicy)), ValueField("cwd", textValue(plan.cwd)),
        ValueField("environment", objectValue(plan.relevantEnvironment)),
        ValueField("idempotency", textValue(plan.idempotencyKey)), ValueField("digest", textValue(plan.bindingDigest)),
        ValueField("tool_version", textValue(plan.implementation.toolVersion)),
        ValueField("implementation", textValue(plan.implementation.implementationFingerprint)),
        ValueField("schema", textValue(plan.implementation.schemaDigest)),
        ValueField("arguments_digest", textValue(plan.implementation.effectiveArgumentsDigest)),
        ValueField("replay_contract_version", integerValue(Int64(plan.implementation.replayContractVersion))),
        ValueField("approval", objectValue([ValueField("label", textValue(metadata.capabilityLabel)),
            ValueField("session_allowed", boolValue(metadata.sessionApprovalAllowed)),
            ValueField("risk", textValue(approvalRiskLevelName(metadata.assessment.level))),
            ValueField("flags", listValue(flags.toArray())), ValueField("reasons", listValue(reasons.toArray())),
            ValueField("grant", objectValue([ValueField("capability", textValue(metadata.grantScope.capability)),
                ValueField("path", textValue(metadata.grantScope.pathPrefix)), ValueField("tool", textValue(metadata.grantScope.toolName)),
                ValueField("host", textValue(metadata.grantScope.host)), ValueField("session_only", boolValue(metadata.grantScope.sessionOnly))]))]))])
    modelPolicySha256Text(canonicalAgentValue(value))
}
