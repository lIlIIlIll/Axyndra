package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_PLUGIN_DOCUMENT_TOOL = "host.plugin.document"
public let HOST_PLUGIN_DOCUMENT_FINGERPRINT = "host-plugin-document-v1"
public let PLUGIN_DOCUMENT_INTENT_SCHEMA = "axyndra.plugin-document-intent/v1"
public let PLUGIN_DOCUMENT_PARENT_SCHEMA = "axyndra.plugin-document-parent/v1"
public let PLUGIN_DOCUMENT_MAX_BYTES: Int64 = 8388608

// Descriptive immutable data only. Neither a valid shape nor a matching hash
// is a source, namespace grant, preparation, handoff or permission to write.
// The Host supplies binding from the actual invocation; plugins supply only
// a logical key and a proposal. No database/path/artifact reference is accepted.
public class PluginDocumentIntent {
    private let bindingJson: String
    public let id: String
    public let key: String
    public let compareExchange: Bool
    public let expectedRevision: Int64
    public let expectedJson: String
    public let expectedDigest: String
    public let nextJson: ?String
    public let expectedPayload: ?PluginDocumentPayloadReference
    public let nextPayload: ?PluginDocumentPayloadReference
    public prop referencesPayload: Bool { get() { expectedPayload.isSome() } }

    init(binding: String, id: String, key: String, compareExchange: Bool,
        revision: Int64, expected: String, digest: String, next: ?String,
        expectedPayload!: ?PluginDocumentPayloadReference = None, nextPayload!: ?PluginDocumentPayloadReference = None) {
        this.bindingJson = binding; this.id = id; this.key = key
        this.compareExchange = compareExchange; this.expectedRevision = revision
        this.expectedJson = expected; this.expectedDigest = digest; this.nextJson = next
        this.expectedPayload = expectedPayload; this.nextPayload = nextPayload
    }
    public func binding(): AgentValue { parseUnifiedJson(bindingJson, maxBytes: 16384) }
    public func toValue(): AgentValue {
        if (referencesPayload) {
            return objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),
                ValueField("binding", binding()), ValueField("intent", objectValue([
                    ValueField("id", textValue(id)), ValueField("key", textValue(key)),
                    ValueField("mode", textValue(if (compareExchange) { "compare_exchange" } else { "read" })),
                    ValueField("expected_revision", integerValue(expectedRevision)),
                    ValueField("expected_payload", expectedPayload.getOrThrow().value()),
                    ValueField("next_payload", match (nextPayload) { case Some(value) => value.value(); case None => nullValue() })]))])
        }
        objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_INTENT_SCHEMA)),
            ValueField("binding", binding()), ValueField("intent", objectValue([
                ValueField("id", textValue(id)), ValueField("key", textValue(key)),
                ValueField("mode", textValue(if (compareExchange) { "compare_exchange" } else { "read" })),
                ValueField("expected_revision", integerValue(expectedRevision)),
                ValueField("expected_json", textValue(expectedJson)),
                ValueField("expected_sha256", textValue(expectedDigest)),
                ValueField("next_json", match (nextJson) { case Some(value) => textValue(value); case None => nullValue() })]))])
    }
    public func result(): AgentValue {
        if (referencesPayload) {
            return objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_RESULT_SCHEMA)),
                ValueField("key", textValue(key)), ValueField("revision", integerValue(
                    expectedRevision + (if (compareExchange) { 1 } else { 0 }))),
                ValueField("payload", (nextPayload ?? expectedPayload.getOrThrow()).value())])
        }
        objectValue([ValueField("schema", textValue("axyndra.plugin-document-result/v1")),
            ValueField("key", textValue(key)), ValueField("revision", integerValue(
                expectedRevision + (if (compareExchange) { 1 } else { 0 }))),
            ValueField("json", textValue(match (nextJson) { case Some(value) => value; case None => expectedJson }))])
    }
}

public func validatePluginDocumentBinding(value: AgentValue): Result<Unit> {
    if (!httpIntentExactFields(value, ["namespace", "package_digest", "generation", "configuration_digest",
        "thread_id", "lane_id", "run_id", "epoch", "parent_call_id", "contribution",
        "implementation_fingerprint", "schema_digest"]) ||
        !httpServicePluginNamespace(httpIntentText(value, "namespace")) ||
        !httpServicePackageDigest(httpIntentText(value, "package_digest")) ||
        !httpIntentDigest(httpIntentText(value, "configuration_digest")) ||
        !httpIntentDigest(httpIntentText(value, "schema_digest"))) {
        return pluginDocumentContractError("plugin.document_binding_invalid") }
    for (name in ["thread_id", "lane_id", "run_id", "parent_call_id", "implementation_fingerprint", "contribution"]) {
        let text = httpIntentText(value, name)
        if (text == "" || text.size > 512 || text.contains("\u{0000}") || text.trimAscii() != text) {
            return pluginDocumentContractError("plugin.document_binding_invalid") }
    }
    let prefix = "plugin." + httpIntentText(value, "namespace") + "."
    if (!httpIntentText(value, "contribution").startsWith(prefix) || httpIntentText(value, "contribution").size <= prefix.size) {
        return pluginDocumentContractError("plugin.document_namespace_mismatch") }
    try {
        let generation = UInt64.parse(httpIntentText(value, "generation"))
        if (generation == 0u64 || generation.toString() != httpIntentText(value, "generation") ||
            documentContractInteger(value.field("epoch").getOrThrow()) < 1) {
            return pluginDocumentContractError("plugin.document_binding_invalid") }
    } catch (_: Exception) { return pluginDocumentContractError("plugin.document_binding_invalid") }
    Result.Ok(())
}

public func parsePluginDocumentIntent(value: AgentValue): Result<PluginDocumentIntent> {
    if (httpIntentText(value, "schema") == PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA) {
        return parsePluginDocumentPayloadIntent(value) }
    try {
        if (!httpIntentExactFields(value, ["schema", "binding", "intent"]) ||
            httpIntentText(value, "schema") != PLUGIN_DOCUMENT_INTENT_SCHEMA) {
            return pluginDocumentContractError("plugin.document_intent_invalid") }
        let binding = value.field("binding").getOrThrow()
        match (validatePluginDocumentBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let raw = value.field("intent").getOrThrow()
        if (!httpIntentExactFields(raw, ["id", "key", "mode", "expected_revision", "expected_json", "expected_sha256", "next_json"]) ||
            !documentContractIdentifier(httpIntentText(raw, "id")) || !documentContractIdentifier(httpIntentText(raw, "key"))) {
            return pluginDocumentContractError("plugin.document_intent_invalid") }
        let revision = documentContractInteger(raw.field("expected_revision").getOrThrow())
        let expectedNode = raw.field("expected_json").getOrThrow()
        let expected = expectedNode.text
        // The old raw bytes may be corrupt. They remain visible and can only be
        // replaced against these exact bytes/revision by a separately approved
        // canonical operation. Parsing cannot silently repair legacy history.
        if (revision < 0 || expectedNode.unifiedKind != ValueKind.Text || expected.size > PLUGIN_DOCUMENT_MAX_BYTES ||
            (revision == 0 && expected != "null") || !httpIntentDigest(httpIntentText(raw, "expected_sha256")) ||
            modelPolicySha256Text(expected) != httpIntentText(raw, "expected_sha256")) {
            return pluginDocumentContractError("plugin.document_expected_invalid") }
        let mode = httpIntentText(raw, "mode")
        let next = raw.field("next_json").getOrThrow()
        var replacement: ?String = None
        if (mode == "read") {
            if (next.unifiedKind != ValueKind.Null) { return pluginDocumentContractError("plugin.document_read_mutation") }
        } else if (mode == "compare_exchange") {
            if (revision == 9223372036854775807 || next.unifiedKind != ValueKind.Text || next.text.size > PLUGIN_DOCUMENT_MAX_BYTES) {
                return pluginDocumentContractError("plugin.document_next_invalid") }
            let _ = logicalJsonNodeCount(next.text)
            match (decodeAgentValue(next.text, maxBytes: PLUGIN_DOCUMENT_MAX_BYTES)) {
                case Result.Err(_) => return pluginDocumentContractError("plugin.document_next_invalid")
                case Result.Ok(decoded) => if (encodeAgentValue(decoded) != next.text) {
                    return pluginDocumentContractError("plugin.document_next_noncanonical") }
            }
            replacement = Some(next.text)
        } else { return pluginDocumentContractError("plugin.document_mode_invalid") }
        let frozenBinding = encodeAgentValue(binding)
        if (frozenBinding.size > 16384) { return pluginDocumentContractError("plugin.document_binding_invalid") }
        Result.Ok(PluginDocumentIntent(frozenBinding, httpIntentText(raw, "id"), httpIntentText(raw, "key"),
            mode == "compare_exchange", revision, expected, httpIntentText(raw, "expected_sha256"), replacement))
    } catch (_: Exception) { pluginDocumentContractError("plugin.document_intent_invalid") }
}

// The service frame contains only intent_id. Bytes/namespace/owner never come
// from its execute payload. Full encoded NormalizedPlan limits are still
// checked by ToolPipeline and Store; per-document bounds do not enlarge them.
public func pluginDocumentChildArguments(parent: AgentValue, intentId: String): Result<AgentValue> {
    if(httpIntentText(parent.field("host_plan")??nullValue(),"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        return pluginDocumentRowJournalChildArguments(parent,intentId)}

    if (!httpIntentExactFields(parent, ["input", "configuration", "host_plan"])) {
        return pluginDocumentContractError("plugin.document_parent_invalid") }
    let host = parent.field("host_plan").getOrThrow()
    if (!(httpIntentExactFields(host, ["version", "binding", "intents"]) ||
          httpIntentExactFields(host, ["version", "binding", "intents", "tool_payload_limits"]) ||
          (pluginDocumentFrozenResultValid(host))) ||
        ![PLUGIN_DOCUMENT_PARENT_SCHEMA, PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA].contains(httpIntentText(host, "version"))) {
        return pluginDocumentContractError("plugin.document_parent_invalid") }
    match (validatePluginDocumentBinding(host.field("binding").getOrThrow())) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (host.field("tool_payload_limits")) {
        case Some(value) =>
            let profile = ordinaryToolPayloadLimitsFromValue(value)
            let binding = host.field("binding").getOrThrow()
            if (profile.isNone() || httpIntentText(binding, "contribution") !=
                "plugin." + httpIntentText(binding, "namespace") + "." + profile.getOrThrow().contribution) {
                return pluginDocumentContractError("plugin.document_payload_invalid") }
        case None => () }
    let intents = host.field("intents").getOrThrow()
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty() || intents.items.size > 8) {
        return pluginDocumentContractError("plugin.document_intent_count") }
    let ids = HashSet<String>()
    let keys = HashSet<String>()
    var found: ?AgentValue = None
    for (raw in intents.items) {
        let child = objectValue([ValueField("schema", textValue(if (httpIntentText(host, "version") == PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA) {
                PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA } else { PLUGIN_DOCUMENT_INTENT_SCHEMA })),
            ValueField("binding", host.field("binding").getOrThrow()), ValueField("intent", raw)])
        let intent = match (parsePluginDocumentIntent(child)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        // One frozen address per parent prevents one operation observing an
        // earlier unapproved mutation as the premise of a later mutation.
        if (ids.contains(intent.id) || keys.contains(intent.key)) { return pluginDocumentContractError("plugin.document_duplicate_intent") }
        ids.add(intent.id); keys.add(intent.key)
        if (intent.id == intentId) { found = Some(intent.toValue()) }
    }
    match (found) { case Some(value) => Result.Ok(value); case None => pluginDocumentContractError("plugin.document_intent_missing") }
}

// The Host final v2 plan freezes the complete pure result as immutable content.
// This is descriptive data. Store preparation pins, current source/plan and
// actual child receipts are separate mandatory checks before Product thaws it.
// Default omission retains the original exact frozen-result shape. The
// optional ceiling is powerless descriptive data and may only restrict use.
public func pluginDocumentFrozenResultValid(host: AgentValue): Bool {
    if(httpIntentText(host,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        return pluginDocumentRowJournalFrozenResultValid(host)}

    if(host.field("valid_until_millis").isNone()){return pluginDocumentFrozenResultBaseValid(host)}
    try{
        let _=pluginDocumentResultValidityCeiling(host)
        pluginDocumentFrozenResultBaseValid(objectValue(host.fields.toArray().filter{field=>field.name!="valid_until_millis"}))
    }catch(_:Exception){false}
}
public func pluginDocumentResultValidityCeiling(value:AgentValue):Int64{
    match(value.field("valid_until_millis")){
        case None=>0
        case Some(raw)=>
            if(raw.unifiedKind!=ValueKind.Number){throw IllegalArgumentException("positive canonical result validity integer required")}
            let parsed=Int64.parse(raw.asNumberText())
            if(parsed<1 || parsed.toString()!=raw.asNumberText()){throw IllegalArgumentException("positive canonical result validity integer required")}
            parsed
    }
}
// Historical plans remain decodable after expiration. Only live consumers
// invoke this function with their own current clock; a worker clock is no grant.
public func pluginDocumentFrozenResultCurrent(host:AgentValue,nowMillis:Int64):Result<Unit>{
    if(httpIntentText(host,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        return pluginDocumentRowJournalFrozenResultCurrent(host,nowMillis)}

    if(host.field("valid_until_millis").isNone()){return Result.Ok(())}
    try{
        if(!pluginDocumentFrozenResultValid(host) || nowMillis<1){
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,"plugin.document_result_validity_invalid","invalid frozen result validity ceiling"))}
        if(nowMillis>=pluginDocumentResultValidityCeiling(host)){
            return Result.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_result_expired","frozen document result expired before actual consumption"))}
        Result.Ok(())
    }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.InvalidInput,"plugin.document_result_validity_invalid","invalid frozen result validity ceiling"))}
}

func pluginDocumentFrozenResultBaseValid(host: AgentValue): Bool {
    try {
        if (!(httpIntentExactFields(host,["version","binding","intents","result_payload","result_codec","is_error"]) ||
            httpIntentExactFields(host,["version","binding","intents","tool_payload_limits","result_payload","result_codec","is_error"])) ||
            httpIntentText(host,"version")!=PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA ||
            httpIntentText(host,"result_codec")!="axyndra.agent-value-json/v1" ||
            host.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean) {return false}
        let reference=parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow()
        reference.bytes>0
    }catch(_:Exception){false}
}

public func pluginDocumentParentAllows(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if(httpIntentText(parent.canonicalArguments.field("host_plan")??nullValue(),"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        return pluginDocumentRowJournalParentAllows(parent,child)}

    let parsed = parsePluginDocumentIntent(child.canonicalArguments)
    if (parsed.isError() || !isPluginDocumentChildPlan(child) || !isFrozenPluginDocumentParentPlan(parent)) { return false }
    let intent = parsed.value().getOrThrow()
    let binding = intent.binding()
    let expected = pluginDocumentChildArguments(parent.canonicalArguments, intent.id)
    if (expected.isError() || canonicalAgentValue(expected.value().getOrThrow()) != canonicalAgentValue(child.canonicalArguments) ||
        parent.toolName != httpIntentText(binding, "contribution") ||
        parent.implementation.implementationFingerprint != httpIntentText(binding, "implementation_fingerprint") ||
        parent.implementation.schemaDigest != httpIntentText(binding, "schema_digest") ||
        child.effectClass != (if (intent.compareExchange) { OperationEffectClass.ExternalMutation } else { OperationEffectClass.ReadOnly }) ||
        (intent.compareExchange && parent.effectClass != OperationEffectClass.ExternalMutation) ||
        parent.retryDisposition != OperationRetryDisposition.Never || child.retryDisposition != OperationRetryDisposition.Never || child.idempotencyKey != "" ||
        !networkPolicyModeIsDenied(child.networkPolicy.mode) || !child.resolvedPaths.isEmpty() ||
        !child.resolvedHosts.isEmpty() || !child.relevantEnvironment.isEmpty() || child.requiredCapabilities.size != 1 ||
        child.requiredCapabilities[0].kind != CapabilityKind.ExtensionInvoke ||
        child.requiredCapabilities[0].resource != httpIntentText(binding, "namespace")) { return false }
    if (!CapabilitySet(values: parent.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke, resource: httpIntentText(binding, "namespace"))) { return false }
    if (!(match (parent.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false })) { return false }
    match (child.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}

public func isPluginDocumentChildPlan(plan: NormalizedOperationPlan): Bool {
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA){
        return isPluginDocumentRowJournalChildPlan(plan)}

    let parsed = parsePluginDocumentIntent(plan.canonicalArguments)
    if (parsed.isError() || plan.toolName != HOST_PLUGIN_DOCUMENT_TOOL ||
        plan.implementation.toolVersion != HOST_PLUGIN_DOCUMENT_FINGERPRINT ||
        plan.implementation.implementationFingerprint != HOST_PLUGIN_DOCUMENT_FINGERPRINT ||
        plan.retryDisposition != OperationRetryDisposition.Never || plan.idempotencyKey != "" ||
        !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.networkPolicy.egress.isEmpty() ||
        !plan.networkPolicy.publish.isEmpty() || !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty() ||
        !plan.relevantEnvironment.isEmpty() || plan.requiredCapabilities.size != 1) { return false }
    let intent = parsed.value().getOrThrow()
    plan.effectClass == (if (intent.compareExchange) { OperationEffectClass.ExternalMutation } else { OperationEffectClass.ReadOnly }) &&
        plan.requiredCapabilities[0].kind == CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource == httpIntentText(intent.binding(), "namespace") &&
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}

public func isFrozenPluginDocumentParentPlan(plan: NormalizedOperationPlan): Bool {
    if(httpIntentText(plan.canonicalArguments.field("host_plan")??nullValue(),"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        return isFrozenPluginDocumentRowJournalParentPlan(plan)}

    let host = match (plan.canonicalArguments.field("host_plan")) { case Some(value) => value; case None => return false }
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return false }
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty()) { return false }
    let selected = pluginDocumentChildArguments(plan.canonicalArguments, httpIntentText(intents.items[0], "id"))
    if (selected.isError()) { return false }
    let binding = selected.value().getOrThrow().field("binding").getOrThrow()
    if (plan.toolName != httpIntentText(binding, "contribution") ||
        plan.implementation.implementationFingerprint != httpIntentText(binding, "implementation_fingerprint") ||
        plan.implementation.schemaDigest != httpIntentText(binding, "schema_digest") ||
        plan.retryDisposition != OperationRetryDisposition.Never ||
        !CapabilitySet(values: plan.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke, resource: httpIntentText(binding, "namespace"))) { return false }
    for (intent in intents.items where httpIntentText(intent, "mode") == "compare_exchange") {
        if (plan.effectClass != OperationEffectClass.ExternalMutation) { return false }
    }
    match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}

func documentContractInteger(value: AgentValue): Int64 {
    if (value.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("integer document field required") }
    let result = Int64.parse(value.asNumberText())
    if (result.toString() != value.asNumberText()) { throw IllegalArgumentException("noncanonical document integer") }
    result
}
func documentContractIdentifier(value: String): Bool {
    if (value == "" || value.size > 128 || value == "." || value == "..") { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-' || byte == b'.')) { return false }
    }
    true
}
func pluginDocumentContractError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, "invalid frozen plugin document data contract"))
}
