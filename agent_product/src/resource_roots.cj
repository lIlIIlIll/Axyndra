package agent_product

import agent_host_runtime.*
import agent_domain.*
import std.collection.*
import std.math.*
import tool_runtime.*

// The sole existing artifact owner, URI router, and atomic workspace primitive.
// This private adapter cannot be requested or constructed by plugin frames.
class ProductResourceRootsPort <: HostResourceRootsPort {
    private let artifacts: ?ProductArtifactStore
    private let uris: InternalUriRouter
    private let workspace: LocalWorkspace
    init(artifacts: ?ProductArtifactStore, uris: InternalUriRouter, workspace: LocalWorkspace) {
        this.artifacts = artifacts; this.uris = uris; this.workspace = workspace
    }
    public func read(context: ToolInvocationContext, reference: String, offset: Int64, limit: Int64, unit: String): Result<AgentValue> {
        if (isProductArtifactReference(reference)) {
            if (unit != "bytes") { return productWorkspaceError("artifact.read_unit_invalid") }
            let store = match (artifacts) { case None => return productWorkspaceError("artifact.store_unprovided"); case Some(value) => value }
            return match (store.read(reference, offset: offset, limit: limit)) {
                case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok(value.value()) }
        }
        if (unit != "lines" || offset < 1 || limit > 10000 || !uris.canHandle(reference)) {
            return productWorkspaceError("resource.uri_unprovided") }
        let resource = match (uris.read(context, reference)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (resource.url != reference || resource.content.toArray().size > 16777216) { return productWorkspaceError("resource.uri_limit") }
        let lines = resource.content.split("\n")
        let start = min(lines.size, offset - 1); let end = min(lines.size, start + limit)
        var text = ""
        for (index in start..end) { if (index > start) { text += "\n" }; text += lines[index] }
        if (text.toArray().size > 1048576) { return productWorkspaceError("resource.uri_page_limit") }
        Result.Ok(objectValue([ValueField("reference", textValue(reference)), ValueField("content", textValue(text)),
            ValueField("offset", integerValue(offset)), ValueField("returned_lines", integerValue(end - start)),
            ValueField("bytes", integerValue(resource.content.toArray().size)), ValueField("returned_bytes", integerValue(text.toArray().size)),
            ValueField("content_type", textValue(resource.contentType)), ValueField("immutable", boolValue(resource.immutable)),
            ValueField("notes", listValue(resource.notes.map({value=>textValue(value)}))),
            ValueField("truncated", boolValue(end < lines.size))]))
    }
    public func write(context: ToolInvocationContext, reference: String, content: String): Result<AgentValue> {
        if (!uris.canHandle(reference)) { return productWorkspaceError("resource.uri_unprovided") }
        match (uris.write(context, reference, content)) { case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(objectValue([ValueField("reference", textValue(reference)),
                ValueField("bytes", integerValue(content.toArray().size)), ValueField("applied", boolValue(true))])) }
    }
    public func exportArtifact(context: ToolInvocationContext, reference: String, destination: String): Result<AgentValue> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let store = match (artifacts) { case None => return productWorkspaceError("artifact.store_unprovided"); case Some(value) => value }
        exportProductArtifact(store, reference, workspace, destination)
    }
    public func exportCapability(destination: String): Capability { workspace.writeCapability(destination) }
    public func exportMetadata(destination: String, reference: String): ToolApprovalMetadata {
        let base = workspace.writeApprovalMetadata(destination, "")
        let flags = ArrayList<String>(); flags.add(all: base.assessment.flags); flags.add("artifact_export")
        let reasons = ArrayList<String>(); reasons.add(all: base.assessment.reasons)
        reasons.add("The independent export_artifact Root will atomically write the complete immutable artifact into the workspace")
        let summary: ?WriteApprovalSummary=match(base.writeSummary){
            case Some(value)=>Some(WriteApprovalSummary(value.path,value.action,value.exists,0,0,
                language:value.language,preview:["export "+reference],contentHash:reference,beforeBytes:value.beforeBytes))
            case None=>None}
        ToolApprovalMetadata(base.capabilityLabel,
            RiskAssessment(if (base.assessment.level == ApprovalRiskLevel.Low) { ApprovalRiskLevel.Medium } else { base.assessment.level },
                flags: flags.toArray(), reasons: reasons.toArray()),
            ApprovalGrantScope(base.grantScope.capability, pathPrefix: base.grantScope.pathPrefix, toolName: "export_artifact"),
            writeSummary: summary, sessionApprovalAllowed: false)
    }
    public func cancel(runId: RunId): Result<Unit> { uris.cancel(runId) }
}

func registerProductResourceRoots(catalog: ToolCatalog, workspace: LocalWorkspace,
    uris: InternalUriRouter, artifacts: ?ProductArtifactStore): Result<Unit> {
    hostRegisterResourceRoots(catalog, ProductResourceRootsPort(artifacts, uris, workspace))
}
