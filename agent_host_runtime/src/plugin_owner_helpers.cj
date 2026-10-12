package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import yjson.*
import yjson_support.*

public class HostFrozenPluginContentQuery {
    public let query: AgentValue
    public let selectedIds: Array<String>
    private let charge: ?LogicalJsonOwnerReservation
    public init(query: AgentValue, selectedIds: Array<String>, observed!: Bool = false) {
        let maximum = if (observed) { CONTENT_PAYLOAD_INPUT_BYTES } else { 196608 }
        let reserved: ?LogicalJsonOwnerReservation = if (observed) { Some(reserveNativeContentJson(query, maximum)) } else { None }
        var captured = false
        try {
        let encoded = stringifyUnifiedJson(query)
        if (encoded.size > maximum || selectedIds.size > 128) {
            throw IllegalArgumentException("context.query_limit")
        }
        match (reserved) { case Some(value) => value.ensureDecoded(encoded.size, logicalJsonNodeCount(encoded)); case None => () }
        this.query = parseUnifiedJson(encoded, maxBytes: maximum, maxDepth: 32)
        this.selectedIds = selectedIds.clone()
        this.charge = reserved
        captured = true
        } finally { if (!captured) { match (reserved) { case Some(value) => value.close(); case None => () } } }
    }
    public func close(): Unit { match (charge) { case Some(value) => value.close(); case None => () } }
}

public func hostPathComponentsContain(parent: String, child: String): Bool {
    let left = hostPortablePathParts(parent)
    let right = hostPortablePathParts(child)
    if (left.size == 0 || right.size < left.size) {
        return false
    }
    let caseInsensitive = left[0].endsWith(":") || right[0].endsWith(":")
    for (index in 0..left.size) {
        if (caseInsensitive) {
            if (left[index].toAsciiLower() != right[index].toAsciiLower()) {
                return false
            }
        } else if (left[index] != right[index]) {
            return false
        }
    }
    true
}

public func hostPortablePathParts(value: String): Array<String> {
    let values = ArrayList<String>()
    for (part in value.replace("\\", "/").split("/") where part != "" && part != ".") {
        if (part == "..") {
            if (!values.isEmpty()) {
                values.remove(at: values.size - 1)
            }
        } else if (values.isEmpty() && part.size == 2 && part[1] == b':') {
            values.add(part.toAsciiLower())
        } else {
            values.add(part)
        }
    }
    values.toArray()
}

public func hostSensitiveWritePath(path: String): Bool {
    let home = match (getVariable("HOME")) {
        case Some(value) => Path(value).normalize().toString()
        case None => ""
    }
    let sensitive = ArrayList<String>()
    for (value in ["/etc", "/usr", "/bin", "/sbin", "/boot", "/proc", "/sys", "/dev"]) {
        sensitive.add(value)
    }
    if (home != "") {
        for (suffix in [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube"]) {
            sensitive.add(Path(home).join(suffix).normalize().toString())
        }
    }
    for (candidate in sensitive where hostPathComponentsContain(candidate, path)) {
        return true
    }
    let lower = path.replace("\\", "/").toAsciiLower()
    lower.contains("/credentials/") || lower.endsWith("/credentials") || lower.contains("/keychain/") || lower
        .contains("/cookies/") || lower.contains("/.ssh/") || lower.contains("/.gnupg/") || lower.contains("/.aws/")
}

public func hostSensitiveReadPath(path: String): Bool {
    if (hostSensitiveWritePath(path)) {
        return true
    }
    let lower = path.replace("\\", "/").toAsciiLower()
    let name = Path(path).fileName.toAsciiLower()
    name == ".env" || name == "id_rsa" || name == "id_dsa" || name == "id_ecdsa" || name == "id_ed25519" ||
        name.endsWith(".pem") || name.endsWith(".key") || lower.contains("/cookies") || lower.contains(
        "/credentials")
}

public func hostSchemaProperty(name: String, kind: String): ValueField {
    ValueField(name, objectValue([ValueField("type", textValue(kind))]))
}

public func hostSchemaStringListProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField("items", objectValue([ValueField("type", textValue("string"))]))
            ]
        )
    )
}

public func hostObjectSchema(
    properties: Array<ValueField>,
    required: Array<String>
): AgentValue {
    let requiredValues = ArrayList<AgentValue>()
    for (name in required) {
        requiredValues.add(textValue(name))
    }
    objectValue(
        [
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue(properties)),
            ValueField("required", listValue(requiredValues.toArray())),
            ValueField("additionalProperties", boolValue(false))
        ]
    )
}

public let HOST_FILE_APPLICATION_PROPOSAL_SCHEMA = "axyndra.file-change-proposal/v1"

public let HOST_FILE_APPLICATION_MAX_OPERATIONS: Int64 = 32

public func hostApplicationPlanObjectShape(
    value: AgentValue,
    allowed: Array<String>,
    required: Array<String>
): Bool {
    if (value.unifiedKind != ValueKind.Object) { return false }
    let seen = ArrayList<String>()
    for (field in value.fields) {
        if (!allowed.contains(field.name) || seen.contains(field.name)) { return false }
        seen.add(field.name)
    }
    for (name in required) {
        if (!seen.contains(name)) { return false }
    }
    true
}

public func hostApplicationPlanError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

public let PLUGIN_FILE_PLAN_TOOL = "host.file.plan.propose"

public let PLUGIN_FILE_PLAN_PROPOSAL_BYTES: Int64 = 65536

public func hostValidatePluginFilePlanProposal(proposal: AgentValue): Result<Unit> {
    if (!hostApplicationPlanObjectShape(proposal, ["schema", "operations"], ["schema", "operations"]) ||
        hostPluginReceiptText(proposal, "schema") != HOST_FILE_APPLICATION_PROPOSAL_SCHEMA) {
        return hostApplicationPlanError<Unit>(AgentErrorKind.InvalidInput,
            "application_plan.plugin_proposal_invalid", "file.plan.propose requires only proposal schema and operations; source is host-owned")
    }
    let operations = proposal.field("operations").getOrThrow()
    if (operations.unifiedKind != ValueKind.List || operations.items.isEmpty() ||
        operations.items.size > HOST_FILE_APPLICATION_MAX_OPERATIONS ||
        (stringifyUnifiedJson(proposal).toArray().size > PLUGIN_FILE_PLAN_PROPOSAL_BYTES &&
            !hostBoundedSingleFileProposal(proposal))) {
        return hostApplicationPlanError<Unit>(AgentErrorKind.InvalidInput,
            "application_plan.limit_exceeded", "plugin proposal requires 1..32 operations and at most 64 KiB of encoded JSON")
    }
    for(operation in operations.items where operation.field("expected_sha256").isSome()){
        if(!hostBoundedSingleFileProposal(proposal)){
            return hostApplicationPlanError<Unit>(AgentErrorKind.InvalidInput,
                "application_plan.limit_exceeded","Digest precondition is restricted to one bounded file proposal")}
    }
    Result.Ok(())
}

public func hostLifecycleText(value: AgentValue, name: String): String {
    let field = value.field(name).getOrThrow()
    hostLifecycleRequire(field.unifiedKind == ValueKind.Text)
    field.text
}

public func hostLifecycleInt(value: AgentValue, name: String, maximum: Int64): Int64 {
    let field = value.field(name).getOrThrow()
    hostLifecycleRequire(field.unifiedKind == ValueKind.Number)
    let number = Int64.parse(field.asNumberText())
    hostLifecycleRequire(number >= 1 && number <= maximum)
    number
}

public func hostLifecycleRequire(condition: Bool): Unit {
    hostLifecycleRequire(condition, "plugin.lifecycle_configuration_invalid")
}

public func hostLifecycleRequire(condition: Bool, code: String): Unit {
    if (!condition) { throw IllegalArgumentException(code) }
}

public func hostCompactionDiagnosticRecord(phase: String, started: MonoTime): Unit {
    if (getVariable("AXYNDRA_DIAGNOSTIC_COMPACTION") == Some("1")) {
        println("COMPACTION_TIMING phase=" + phase + " ns=" + (MonoTime.now() - started).toNanoseconds().toString())
    }
}

// A bounded transport exception for one small file. This does not authorize a
// file operation; the original source, read/write gates and atomic CAS remain.
func hostBoundedSingleFileProposal(proposal: AgentValue): Bool {
    if(stringifyUnifiedJson(proposal).toArray().size>229376){return false}
    let operations=proposal.field("operations").getOrThrow()
    if(operations.items.size!=1){return false}
    let operation=operations.items[0];let kind=hostPluginReceiptText(operation,"kind")
    let fields=if(kind=="create"){["kind","path","content"]}
        else if(kind=="replace" && operation.field("expected_sha256").isSome()){
            ["kind","path","expected_sha256","expected_bytes","content"]}
        else if(kind=="replace"){["kind","path","expected_content","content"]}else{return false}
    if(!hostApplicationPlanObjectShape(operation,fields,fields) || operation.field("content").getOrThrow().unifiedKind!=ValueKind.Text ||
        operation.field("path").getOrThrow().unifiedKind!=ValueKind.Text || operation.field("content").getOrThrow().text.toArray().size>32768){return false}
    if(operation.field("expected_content").isSome()){
        let expected=operation.field("expected_content").getOrThrow()
        if(expected.unifiedKind!=ValueKind.Text || expected.text.toArray().size>65536){return false}
    }
    if(operation.field("expected_sha256").isSome()){
        let digest=operation.field("expected_sha256").getOrThrow();let bytes=operation.field("expected_bytes").getOrThrow()
        if(digest.unifiedKind!=ValueKind.Text || !httpIntentDigest(digest.text) || bytes.unifiedKind!=ValueKind.Number){return false}
        let size=try{Int64.parse(bytes.asNumberText())}catch(_:Exception){-1}
        if(size<0 || size>65536){return false}
    }
    true
}
