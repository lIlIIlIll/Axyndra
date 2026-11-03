package agent_host_runtime

import agent_domain.*
import std.convert.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Trusted composition only. These ports borrow resource owners; they neither
// grant access nor expose an RPC/JS/SDK callback or a database connection.
public interface HostResourceRootsPort {
    func read(context: ToolInvocationContext, reference: String, offset: Int64, limit: Int64, unit: String): Result<AgentValue>
    func write(context: ToolInvocationContext, reference: String, content: String): Result<AgentValue>
    func exportArtifact(context: ToolInvocationContext, reference: String, destination: String): Result<AgentValue>
    func exportCapability(destination: String): Capability
    func exportMetadata(destination: String, reference: String): ToolApprovalMetadata
    func cancel(runId: RunId): Result<Unit>
}

public func hostRegisterResourceRoots(catalog: ToolCatalog, port: HostResourceRootsPort): Result<Unit> {
    let readSchema = parseUnifiedJson("{\"type\":\"object\",\"properties\":{\"reference\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":1048576},\"unit\":{\"type\":\"string\",\"enum\":[\"bytes\",\"lines\"]}},\"required\":[\"reference\",\"offset\",\"limit\",\"unit\"],\"additionalProperties\":false}")
    let writeSchema = hostObjectSchema([hostSchemaProperty("reference", "string"), hostSchemaProperty("content", "string")], ["reference", "content"])
    let exportSchema = hostObjectSchema([hostSchemaProperty("reference", "string"), hostSchemaProperty("destination", "string")], ["reference", "destination"])
    for ((name, schema) in [("read_resource", readSchema), ("write_resource", writeSchema), ("export_artifact", exportSchema)]) {
        let write = name != "read_resource"
        let result = catalog.register(ToolDescriptor(ModelToolDefinition(name,
            "Perform one explicitly selected resource operation through its independent canonical Root.", schema),
            Capability(if (write) { CapabilityKind.WorkspaceWrite } else { CapabilityKind.WorkspaceRead }),
            sideEffecting: write, neverReplay: true,
            implementationVersion: "resource-roots-v1", implementationFingerprint: "resource-roots-v1",
            capabilityResolver: Some({ call => if (call.name == "export_artifact") {
                port.exportCapability(httpIntentText(call.arguments, "destination"))
            } else { Capability(if (call.name == "write_resource") { CapabilityKind.WorkspaceWrite } else { CapabilityKind.WorkspaceRead },
                resource: httpIntentText(call.arguments, "reference")) } }),
            approvalMetadataResolver: Some({ call => if (call.name == "export_artifact") {
                port.exportMetadata(httpIntentText(call.arguments, "destination"), httpIntentText(call.arguments, "reference"))
            } else { ToolApprovalMetadata(if (call.name == "write_resource") { "workspace.write" } else { "workspace.read" },
                RiskAssessment(if (call.name == "write_resource") { ApprovalRiskLevel.High } else { ApprovalRiskLevel.Low },
                    reasons: ["Access this exact resource through a separate canonical Root"]),
                ApprovalGrantScope(if (call.name == "write_resource") { "workspace.write" } else { "workspace.read" },
                    pathPrefix: httpIntentText(call.arguments, "reference"), toolName: call.name), sessionApprovalAllowed: false) } }),
            networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })), HostResourceRootExecutor(port))
        match (result) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    }
    Result.Ok(())
}

class HostResourceRootExecutor <: ToolExecutor {
    private let port: HostResourceRootsPort
    init(port: HostResourceRootsPort) { this.port = port }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.operationRoot.isNone() || prepared.source.kind == PreparedInvocationSourceKind.Derived ||
            prepared.source.runId.value != context.runId.value || prepared.source.sessionId.value != context.sessionId.value ||
            prepared.source.epoch != context.epoch || !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return hostResourceRootError("resource.root_required", "Resource IO requires its actual independent canonical Root") }
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let args = prepared.operationPlan.canonicalArguments
        let reference = httpIntentText(args, "reference")
        if (!readViewResourceReference(reference)) { return hostResourceRootError("resource.reference_invalid", "Resource reference is invalid") }
        let result: Result<AgentValue> = match (prepared.call.name) {
            case "read_resource" => 
                if (!httpIntentExactFields(args, ["reference", "offset", "limit", "unit"])) {
                    return hostResourceRootError("resource.arguments_invalid", "Read resource arguments changed") }
                let offset = try { Int64.parse(args.field("offset").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
                let limit = try { Int64.parse(args.field("limit").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
                let unit = httpIntentText(args, "unit")
                if (offset < 0 || limit < 1 || limit > 1048576 || !["bytes", "lines"].contains(unit) ||
                    !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: reference)) {
                    return hostResourceRootError("resource.read_denied", "Read resource exceeds its actual capability or byte ceiling") }
                port.read(context, reference, offset, limit, unit)
            
            case "write_resource" => 
                let content = httpIntentText(args, "content")
                if (!httpIntentExactFields(args, ["reference", "content"]) || args.field("content").getOrThrow().unifiedKind != ValueKind.Text ||
                    content.toArray().size > 32768 || content.contains("\u{0000}") || reference.startsWith("blob:") ||
                    !context.capabilities.allows(CapabilityKind.WorkspaceWrite, resource: reference)) {
                    return hostResourceRootError("resource.write_denied", "URI write exceeds its immutable-resource or actual capability boundary") }
                port.write(context, reference, content)
            
            case "export_artifact" => 
                let destination = httpIntentText(args, "destination")
                let cap = port.exportCapability(destination)
                if (!httpIntentExactFields(args, ["reference", "destination"]) || !reference.startsWith("blob:sha256:") ||
                    !readViewRelativePath(destination) || cap.kind != CapabilityKind.WorkspaceWrite ||
                    !context.capabilities.allows(cap.kind, resource: cap.resource)) {
                    return hostResourceRootError("artifact.export_denied", "Export requires its exact approved workspace destination") }
                port.exportArtifact(context, reference, destination)
            
            case _ => return hostResourceRootError("resource.tool_invalid", "This executor has no resource operation for the requested tool")
        }
        match (result) { case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(ToolResult(prepared.call.callId, value)) }
    }
    public func cancel(runId: RunId): Result<Unit> { port.cancel(runId) }
}

func hostResourceRootError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code, message))
}
