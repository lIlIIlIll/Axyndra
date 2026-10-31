package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_READ_VIEW_TOOL = "host.process.readview"
public let HOST_READ_VIEW_VERSION = "read-view-intents/v2"
public let HOST_READ_VIEW_FINGERPRINT = "host-read-view-v2"
public let HOST_READ_VIEW_MAX_FILES: Int64 = 1024
public let HOST_READ_VIEW_MAX_BYTES: Int64 = 16777216

// These codecs describe immutable intent. They never mint permission. Only the
// actual parent Source/plan/handoff and operator-bound Product loader do that.
public func parseOrdinaryToolReadGrants(value: AgentValue): Result<Array<String>> {
    if (value.unifiedKind != ValueKind.List || value.items.size > 64) {
        return readViewError("read_view.grant_invalid", "ordinary Tool grants must be a bounded list")
    }
    let names = ArrayList<String>()
    for (grant in value.items) {
        let name = httpIntentText(grant, "name")
        if (!httpIntentExactFields(grant, ["kind", "name", "effect", "services"]) ||
            httpIntentText(grant, "kind") != "tool" || httpIntentText(grant, "effect") != "read_only" ||
            !channelIntentIdentifier(name) || name.size > 128 || names.contains(name)) {
            return readViewError("read_view.grant_invalid", "grant must name one exact ordinary Tool contribution")
        }
        let services = grant.field("services").getOrThrow()
        if (services.unifiedKind != ValueKind.List || services.items.size != 1 ||
            services.items[0].unifiedKind != ValueKind.Text || services.items[0].text != "process.readview") {
            return readViewError("read_view.grant_invalid", "read grant only permits the host-controlled read view")
        }
        names.add(name)
    }
    Result.Ok(names.toArray())
}

public func readViewRelativePath(path: String, rootAllowed!: Bool = false): Bool {
    if (rootAllowed && path == ".") { return true }
    if (path == "" || path.size > 4096 || path.startsWith("/") || path.contains("\\") || path.contains(":")) { return false }
    for (byte in path.toArray() where byte < 32u8 || byte == 127u8) { return false }
    for (part in path.split("/")) { if (part == "" || part == "." || part == "..") { return false } }
    true
}

public func readViewAbsolutePath(path: String): Bool {
    if (!path.startsWith("/") || path.size < 2 || path.size > 4096 || path.contains("\\")) { return false }
    for (byte in path.toArray() where byte < 32u8 || byte == 127u8) { return false }
    for (part in path[1..].split("/")) { if (part == "" || part == "." || part == "..") { return false } }
    true
}

// An opaque reference has no content view and never authorizes resource IO.
// The worker may return a proposal; an independent ordinary Root performs IO.
public func readViewResourceReference(source: String): Bool {
    if (source.startsWith("blob:sha256:")) {
        if (source.size != 76) { return false }
        for (byte in source[12..].toArray() where !((byte >= 48u8 && byte <= 57u8) || (byte >= 97u8 && byte <= 102u8))) { return false }
        return true
    }
    if (source.size < 4 || source.size > 4096 || !source.contains("://")) { return false }
    for (byte in source.toArray() where byte < 33u8 || byte == 127u8) { return false }
    let colon = source.indexOf(":").getOrThrow()
    if (colon < 1 || colon > 64) { return false }
    for (index in 0..colon) {
        let byte = source.toArray()[index]
        if (!((byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) ||
            (index > 0 && ((byte >= 48u8 && byte <= 57u8) || byte == 43u8 || byte == 45u8 || byte == 46u8)))) { return false }
    }
    if (source.startsWith("blob://")) { return false }
    true
}

public let HOST_READ_VIEW_INPUT_PATH = ".axyndra-worker-input.json"
public let HOST_READ_VIEW_INPUT_BYTES: Int64 = 229376
public let HOST_READ_VIEW_INPUT_OUTPUT_BYTES: Int64 = 229376

public func readViewReservedInputPath(path: String): Bool {
    path == HOST_READ_VIEW_INPUT_PATH || path.startsWith(HOST_READ_VIEW_INPUT_PATH + "/")
}

public func validateDefaultReadViewIntent(intent: AgentValue): Result<Unit> {
    if (!httpIntentExactFields(intent, ["id", "request", "resources", "requires_approval"]) ||
        !httpIntentIdentifier(httpIntentText(intent, "id")) ||
        intent.field("requires_approval").getOrThrow().unifiedKind != ValueKind.Boolean) {
        return readViewError("read_view.intent_invalid", "read view intent has invalid fixed fields")
    }
    let request = intent.field("request").getOrThrow()
    if ((!httpIntentExactFields(request, ["executable", "arguments", "timeout_ms"]) &&
        !httpIntentExactFields(request, ["executable", "arguments", "timeout_ms", "input"])) ||
        !readViewRelativePath(httpIntentText(request, "executable"))) {
        return readViewError("read_view.intent_invalid", "worker must be a package-relative executable")
    }
    match (request.field("input")) {
        case Some(input) => if (input.unifiedKind != ValueKind.Object || stringifyUnifiedJson(input).size > HOST_READ_VIEW_INPUT_BYTES) {
            return readViewError("read_view.intent_invalid", "frozen worker input must be a bounded object") }
        case None => ()
    }
    let argv = request.field("arguments").getOrThrow()
    let timeout = request.field("timeout_ms").getOrThrow()
    if (argv.unifiedKind != ValueKind.List || argv.items.size > 128 || timeout.unifiedKind != ValueKind.Number) {
        return readViewError("read_view.intent_invalid", "worker argv or timeout is invalid")
    }
    let millis = try { Int64.parse(timeout.asNumberText()) } catch (_: Exception) { -1 }
    if (millis < 1 || millis > 60000) { return readViewError("read_view.intent_invalid", "worker timeout is outside its bound") }
    var argvBytes: Int64 = 0
    for (arg in argv.items) {
        if (arg.unifiedKind != ValueKind.Text || arg.text.contains("\u{0000}")) {
            return readViewError("read_view.intent_invalid", "worker arguments must be NUL-free strings")
        }
        argvBytes += arg.text.size
    }
    if (argvBytes > 65536) { return readViewError("read_view.intent_invalid", "worker arguments exceed their bound") }
    let resources = intent.field("resources").getOrThrow()
    if (resources.unifiedKind != ValueKind.List || resources.items.size < 1 || resources.items.size > HOST_READ_VIEW_MAX_FILES) {
        return readViewError("read_view.intent_invalid", "read view resources are empty or exceed their bound")
    }
    let paths = HashSet<String>(); var total: Int64 = 0
    for (resource in resources.items) {
        let kind = httpIntentText(resource, "kind"); let path = httpIntentText(resource, "path")
        let source = httpIntentText(resource, "source"); let witness = httpIntentText(resource, "witness")
        let permission = httpIntentText(resource, "permission")
        if (!httpIntentExactFields(resource, ["kind", "source", "path", "witness", "bytes", "permission"]) ||
            (kind != "file" && kind != "directory" && kind != "reference") ||
            !readViewRelativePath(path, rootAllowed: kind == "directory") || readViewReservedInputPath(path) ||
            (if (kind == "reference") { !readViewResourceReference(source) } else { !readViewAbsolutePath(source) }) ||
            witness == "" || witness.size > 256 || paths.contains(path) ||
            !["workspace.read", "temp.read", "outside-workspace.read", "sensitive-path.read"].contains(permission)) {
            return readViewError("read_view.intent_invalid", "read view contains an invalid or duplicate resource")
        }
        if (kind == "reference" && (permission != "workspace.read" || witness != "r:" + modelPolicySha256Text(source))) {
            return readViewError("read_view.intent_invalid", "opaque reference has invalid frozen metadata")
        }
        if (permission != "workspace.read" && !intent.field("requires_approval").getOrThrow().asBool()) {
            return readViewError("read_view.intent_invalid", "special resource omitted its approval classification")
        }
        let bytes = resource.field("bytes").getOrThrow()
        if (bytes.unifiedKind != ValueKind.Number) { return readViewError("read_view.intent_invalid", "invalid byte reservation") }
        let size = try { Int64.parse(bytes.asNumberText()) } catch (_: Exception) { -1 }
        if (size < 0 || size > HOST_READ_VIEW_MAX_BYTES || ((kind == "directory" || kind == "reference") && size != 0)) {
            return readViewError("read_view.intent_invalid", "resource exceeds its byte bound")
        }
        total += size; paths.add(path)
    }
    if (total > HOST_READ_VIEW_MAX_BYTES || stringifyUnifiedJson(intent).size > 1048576) {
        return readViewError("read_view.intent_invalid", "view exceeds total byte or metadata bound")
    }
    Result.Ok(())
}

public func readViewChildArguments(parent: AgentValue, id: String): Result<AgentValue> {
    if (!httpIntentExactFields(parent, ["input", "host_plan"])) {
        return readViewError("read_view.parent_invalid", "read view requires its frozen parent envelope")
    }
    let host = parent.field("host_plan").getOrThrow()
    if (!httpIntentExactFields(host, ["version", "plugin", "package_digest", "generation", "configuration_digest", "contribution", "read_granted", "tool_payload_limits", "intents"]) ||
        httpIntentText(host, "version") != HOST_READ_VIEW_VERSION ||
        !httpServicePluginNamespace(httpIntentText(host, "plugin")) ||
        !httpServicePackageDigest(httpIntentText(host, "package_digest")) ||
        !httpIntentDigest(httpIntentText(host, "configuration_digest")) ||
        !channelIntentIdentifier(httpIntentText(host, "contribution")) ||
        host.field("read_granted").getOrThrow().unifiedKind != ValueKind.Boolean) {
        return readViewError("read_view.parent_invalid", "read view parent identity is invalid")
    }
    if (!readViewPayloadProfileValid(host)) { return readViewError("read_view.payload_invalid", "read view payload profile must match its exact contribution") }
    let generation = try { UInt64.parse(httpIntentText(host, "generation")) } catch (_: Exception) { 0u64 }
    let intents = host.field("intents").getOrThrow()
    if (generation == 0u64 || intents.unifiedKind != ValueKind.List || intents.items.size != 1) {
        return readViewError("read_view.parent_invalid", "read view requires one bounded intent and a live generation")
    }
    let intent = intents.items[0]
    match (validateReadViewIntent(intent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (httpIntentText(intent, "id") != id) { return readViewError("read_view.intent_missing", "request does not name the frozen intent") }
    let fields = ArrayList<ValueField>()
    for (name in ["plugin", "package_digest", "generation", "configuration_digest", "contribution", "tool_payload_limits"]) {
        fields.add(ValueField(name, host.field(name).getOrThrow()))
    }
    fields.add(ValueField("intent", intent))
    Result.Ok(objectValue(fields.toArray()))
}

public func readViewRequiredCapabilities(args: AgentValue): Array<Capability> {
    let output = ArrayList<Capability>()
    match (args.field("intent")) {
        case None => return [Capability(CapabilityKind.WorkspaceRead)]
        case Some(intent) => match (intent.field("resources")) {
            case None => return [Capability(CapabilityKind.WorkspaceRead)]
            case Some(resources) => for (resource in resources.items) {
                let source = httpIntentText(resource, "source")
                var seen = false
                for (cap in output where cap.resource == source) { seen = true }
                if (!seen) { output.add(Capability(CapabilityKind.WorkspaceRead, resource: source)) }
            }
        }
    }
    if (output.isEmpty()) { [Capability(CapabilityKind.WorkspaceRead, resource: "invalid-read-view")] } else { output.toArray() }
}

public func isReadViewServiceChildPlan(plan: NormalizedOperationPlan): Bool {
    if (plan.toolName != HOST_READ_VIEW_TOOL || plan.implementation.implementationFingerprint != HOST_READ_VIEW_FINGERPRINT ||
        plan.implementation.toolVersion != HOST_READ_VIEW_FINGERPRINT || plan.effectClass != OperationEffectClass.ReadOnly ||
        plan.networkPolicy.mode != NetworkPolicyMode.Denied || plan.retryDisposition != OperationRetryDisposition.Never ||
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true } ||
        !httpIntentExactFields(plan.canonicalArguments, ["plugin", "package_digest", "generation", "configuration_digest", "contribution", "tool_payload_limits", "intent"]) ||
        !readViewPayloadProfileValid(plan.canonicalArguments)) { return false }
    if (validateReadViewIntent(plan.canonicalArguments.field("intent").getOrThrow()).isError()) { return false }
    let required = readViewRequiredCapabilities(plan.canonicalArguments)
    if (required.size != plan.requiredCapabilities.size) { return false }
    for (index in 0..required.size) {
        if (required[index].kind != plan.requiredCapabilities[index].kind || required[index].resource != plan.requiredCapabilities[index].resource) { return false }
    }
    true
}

public func isFrozenReadViewParentPlan(plan: NormalizedOperationPlan): Bool {
    let host = match (plan.canonicalArguments.field("host_plan")) { case Some(value) => value; case None => return false }
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return false }
    if (intents.unifiedKind != ValueKind.List || intents.items.size != 1) { return false }
    let bound = match (readViewChildArguments(plan.canonicalArguments, httpIntentText(intents.items[0], "id"))) {
        case Result.Ok(value) => value; case Result.Err(_) => return false
    }
    let ceiling = CapabilitySet(values: plan.requiredCapabilities)
    if (!ceiling.allows(CapabilityKind.ExtensionInvoke, resource: plan.toolName)) { return false }
    for (cap in plan.requiredCapabilities where cap.kind == CapabilityKind.ExtensionInvoke &&
        cap.resource != "" && cap.resource != plan.toolName) { return false }
    let expectedEffect = if (host.field("read_granted").getOrThrow().asBool() &&
        !intents.items[0].field("requires_approval").getOrThrow().asBool()) {
        OperationEffectClass.ReadOnly
    } else { OperationEffectClass.ExternalMutation }
    plan.toolName == "plugin." + httpIntentText(bound, "plugin") + "." + httpIntentText(bound, "contribution") &&
        plan.implementation.implementationFingerprint == httpIntentText(bound, "plugin") + ":" + httpIntentText(bound, "package_digest") &&
        plan.networkPolicy.mode == NetworkPolicyMode.Denied && plan.effectClass == expectedEffect &&
        plan.retryDisposition == OperationRetryDisposition.Never &&
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}

public func readViewServiceChildAllowed(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if (!isFrozenReadViewParentPlan(parent) || !isReadViewServiceChildPlan(child)) { return false }
    let args = child.canonicalArguments
    let expected = match (readViewChildArguments(parent.canonicalArguments, httpIntentText(args.field("intent").getOrThrow(), "id"))) {
        case Result.Ok(value) => value; case Result.Err(_) => return false
    }
    if (canonicalAgentValue(expected) != canonicalAgentValue(args)) { return false }
    let ceiling = CapabilitySet(values: parent.requiredCapabilities)
    if (!ceiling.allows(CapabilityKind.ExtensionInvoke, resource: parent.toolName)) { return false }
    for (cap in parent.requiredCapabilities where cap.kind == CapabilityKind.ExtensionInvoke &&
        cap.resource != "" && cap.resource != parent.toolName) { return false }
    for (required in child.requiredCapabilities where !ceiling.allows(required.kind, resource: required.resource)) { return false }
    true
}

func readViewPayloadProfileValid(value: AgentValue): Bool {
    let raw = match (value.field("tool_payload_limits")) { case Some(item) => item; case None => return false }
    if (raw.unifiedKind == ValueKind.Null) { return true }
    let profile = ordinaryToolPayloadLimitsFromValue(raw)
    profile.isSome() && profile.getOrThrow().contribution == httpIntentText(value, "contribution")
}

func readViewError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code, message))
}
