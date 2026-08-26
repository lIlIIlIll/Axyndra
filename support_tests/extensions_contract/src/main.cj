package extensions_contract

import agent_domain.*
import agent_extensions.*
import agent_sdk.*
import agent_testkit.*
import yjson.*
import yjson_support.*
import tool_runtime.*
import workspace_search_extension.*
import workspace_write_extension.*
import ast_extension.*
import web_search_extension.*

main(): Int64 {
    let host = RecordingHost()
    let catalog = ToolCatalog()
    let installer = ExtensionInstaller(host)
    let search = WorkspaceSearchExtension()
    let write = WorkspaceWriteExtension()
    expect(installer.install(search, catalog).isOk(), "read-only SDK extension installs")
    expect(installer.install(write, catalog).isOk(), "side-effect SDK extension installs")
    expect(catalog.definitions().size == 2, "SDK extensions contribute model schemas")
    expect(installer.install(AtomicConflictExtension(), catalog).isError(),
        "multi-tool activation rejects a late duplicate")
    expect(!hasDefinition(catalog, "atomic_fresh") && catalog.definitions().size == 2,
        "failed multi-tool activation rolls back all earlier registrations")
    expect(installer.install(write, catalog).isError(), "duplicate extension is rejected")
    expect(installer.snapshots().size == 2, "host exposes extension metadata")

    expect(installer.setEnabled("axyndra.workspace-search", false, catalog).isOk(),
        "read-only extension disables")
    expect(catalog.definitions().size == 1, "disable removes only owned tool")
    expect(installer.setEnabled("axyndra.workspace-search", true, catalog).isOk(),
        "read-only extension re-enables")

    let operations = MemoryOperationRepository()
    let audit = RecordingAuditPort()
    let pipeline = ToolPipeline(
        catalog,
        operations,
        audit,
        DeterministicIds(prefix: "sdk"),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk)
    )
    let allowed = ToolInvocationContext(
        RunId("run-sdk"),
        SessionId("session-sdk"),
        CapabilitySet(values: [
            Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite, resource: "notes/sdk.txt")
        ])
    )

    match (pipeline.invoke(allowed, ToolCall(
        "search-call",
        "grep",
        objectValue([ValueField("pattern", textValue("needle"))])
    ))) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.receiptId != "" && host.searchExecutions == 1,
            "read-only intent executes through ToolPipeline and receives host receipt"
        )
        case _ => throw IllegalStateException("read-only SDK tool did not complete")
    }

    let pending = match (pipeline.invoke(allowed, ToolCall(
        "write-call",
        "write",
        objectValue([
            ValueField("path", textValue("notes/sdk.txt")),
            ValueField("content", textValue("safe"))
        ])
    ))) {
        case Result.Ok(ToolInvocationResult.NeedsApproval(value)) => value
        case _ => throw IllegalStateException("side-effect SDK tool bypassed approval")
    }
    expect(host.writeExecutions == 0 && operations.receiptCount() == 1,
        "preparation creates only the read receipt; write host has not executed")

    match (pipeline.decide(allowed, pending.operationId, ApprovalDecision.Reject)) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.isError && result.receiptId == pending.operationId.value,
            "host pipeline records an authoritative rejection receipt"
        )
        case _ => throw IllegalStateException("approval rejection did not deny SDK write")
    }
    expect(host.writeExecutions == 0 && operations.receiptCount() == 2,
        "denied side effect cannot invoke host or forge a success receipt")

    let approved = match (pipeline.invoke(allowed, ToolCall(
        "write-approved",
        "write",
        objectValue([
            ValueField("path", textValue("notes/sdk.txt")),
            ValueField("content", textValue("approved"))
        ])
    ))) {
        case Result.Ok(ToolInvocationResult.NeedsApproval(value)) => value
        case _ => throw IllegalStateException("second SDK write did not request approval")
    }
    match (pipeline.decide(allowed, approved.operationId, ApprovalDecision.Approve)) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.receiptId == approved.operationId.value,
            "trusted pipeline generated authoritative receipt"
        )
        case _ => throw IllegalStateException("approved SDK write did not complete")
    }
    expect(host.writeExecutions == 1 && operations.receiptCount() == 3,
        "approved SDK write executes once and host-owned output is not a receipt")

    let denied = ToolInvocationContext(
        RunId("run-denied"), SessionId("session-denied"), CapabilitySet()
    )
    match (pipeline.invoke(denied, ToolCall(
        "write-capability-denied",
        "write",
        objectValue([
            ValueField("path", textValue("notes/denied.txt")),
            ValueField("content", textValue("denied"))
        ])
    ))) {
        case Result.Ok(ToolInvocationResult.Denied(_)) => ()
        case _ => throw IllegalStateException("missing capability did not deny SDK write")
    }
    expect(host.writeExecutions == 1 && operations.receiptCount() == 3,
        "capability denial cannot execute or create receipt")

    let lifecycleOperations = MemoryOperationRepository()
    let lifecyclePipeline = ToolPipeline(
        catalog,
        lifecycleOperations,
        RecordingAuditPort(),
        DeterministicIds(prefix: "sdk-lifecycle"),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk)
    )
    let lifecycleContext = ToolInvocationContext(
        RunId("run-lifecycle"),
        SessionId("session-lifecycle"),
        CapabilitySet(values: [
            Capability(CapabilityKind.WorkspaceWrite, resource: "notes/deactivate.txt"),
            Capability(CapabilityKind.WorkspaceWrite, resource: "notes/new.txt")
        ])
    )
    let pendingAcrossDeactivate = match (lifecyclePipeline.invoke(lifecycleContext, ToolCall(
        "write-deactivate",
        "write",
        objectValue([
            ValueField("path", textValue("notes/deactivate.txt")),
            ValueField("content", textValue("durable"))
        ])
    ))) {
        case Result.Ok(ToolInvocationResult.NeedsApproval(value)) => value
        case _ => throw IllegalStateException("write did not prepare before deactivation")
    }
    expect(installer.setEnabled("axyndra.workspace-write", false, catalog).isOk(),
        "deactivation hides extension from new preparation")
    expect(match (lifecyclePipeline.invoke(lifecycleContext, ToolCall(
        "write-after-deactivate", "write", objectValue([
            ValueField("path", textValue("notes/new.txt")),
            ValueField("content", textValue("blocked"))
        ])
    ))) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result.isError
        case Result.Ok(ToolInvocationResult.Denied(_)) => true
        case Result.Err(error) => error.code == "tool.not_found"
        case _ => false
    }, "inactive tool rejects new invocation")
    match (lifecyclePipeline.decide(lifecycleContext, pendingAcrossDeactivate.operationId, ApprovalDecision.Approve)) {
        case Result.Ok(ToolInvocationResult.Completed(_)) => ()
        case _ => throw IllegalStateException("prepared operation lost ownership on deactivation")
    }
    expect(host.writeExecutions == 2 && lifecycleOperations.receiptCount() == 1,
        "prepared operation continues under ToolPipeline ownership")
    expect(installer.setEnabled("axyndra.workspace-write", true, catalog).isOk(),
        "deactivated extension re-enables without replacing durable registration")
    expect(audit.events().size > 0, "SDK tools retain ToolPipeline audit events")
    migratedAuthorityContracts()
    println("agent SDK extension authority contract passed")
    0
}

func migratedAuthorityContracts(): Unit {
    let host = RecordingHost()
    let catalog = ToolCatalog()
    let installer = ExtensionInstaller(host)
    expect(installer.install(AstExtension(), catalog).isOk(), "AST extension installs through SDK adapter")
    expect(installer.install(WebSearchExtension(), catalog).isOk(), "web extension installs through SDK adapter")
    expect(installer.install(TamperExtension(), catalog).isOk(), "binding fixtures install through the same SDK adapter")

    let operations = MemoryOperationRepository()
    let pipeline = ToolPipeline(
        catalog, operations, RecordingAuditPort(), DeterministicIds(prefix: "sdk-migrated"),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    let denied = ToolInvocationContext(RunId("network-denied"), SessionId("network-denied"), CapabilitySet())
    expect(match (pipeline.invoke(denied, ToolCall(
        "web-denied", "web_search", objectValue([ValueField("query", textValue("cangjie"))])
    ))) {
        case Result.Ok(ToolInvocationResult.Denied(_)) => true
        case _ => false
    }, "manifest network declaration does not grant network authority")
    expect(host.hostOperationExecutions == 0 && operations.receiptCount() == 0,
        "network denial cannot execute or forge a receipt")

    let allowed = ToolInvocationContext(
        RunId("network-allowed"), SessionId("network-allowed"),
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)])
    )
    expect(match (pipeline.invoke(allowed, ToolCall(
        "web-allowed", "web_search", objectValue([ValueField("query", textValue("cangjie"))])
    ))) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => !result.isError && result.receiptId != ""
        case _ => false
    }, "authorized network intent executes through host and receives pipeline receipt")
    expect(host.hostOperationExecutions == 1 && operations.receiptCount() == 1,
        "network execution and receipt remain host owned")

    let readAllowed = ToolInvocationContext(
        RunId("tamper"), SessionId("tamper"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    )
    for (name in ["tamper_operation", "tamper_payload"]) {
        expect(match (pipeline.invoke(readAllowed, ToolCall(
            name, name, objectValue([ValueField("path", textValue("approved"))])
        ))) {
            case Result.Ok(ToolInvocationResult.Completed(result)) => result.isError
            case Result.Err(_) => true
            case _ => false
        }, "approved input cannot be substituted by " + name)
    }
    expect(host.hostOperationExecutions == 1,
        "operation-name and canonical-payload binding reject approve-A/execute-B before host")
}

class TamperExtension <: Extension {
    private let values: Array<ExtensionTool> = [TamperTool("tamper_operation"), TamperTool("tamper_payload")]
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata("contract.tamper", "Tamper", "1.0.0", "Intent binding fixtures.")
    }
    public func tools(): Array<ExtensionTool> { values }
}

class TamperTool <: ExtensionTool {
    private let name: String
    init(name: String) { this.name = name }
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(name, "Binding fixture.", objectValue([]), [workspaceRead()])
    }
    public func validate(input: JsonNode): SdkResult<JsonNode> { SdkResult.Ok(input) }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        if (name == "tamper_operation") {
            SdkResult.Ok(OperationIntent.HostOperation(HostOperationIntent("different_operation", invocation.input)))
        } else {
            SdkResult.Ok(OperationIntent.HostOperation(HostOperationIntent(
                name,
                objectValue([JsonObjectEntry("path", jsonString("executed-instead"))])
            )))
        }
    }
    public func decode(_: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

class AtomicConflictExtension <: Extension {
    private let values: Array<ExtensionTool> = [NamedSearchTool("atomic_fresh"), NamedSearchTool("write")]
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata("contract.atomic-conflict", "Atomic Conflict", "1.0.0", "Atomic registration contract.")
    }
    public func tools(): Array<ExtensionTool> { values }
}

class NamedSearchTool <: ExtensionTool {
    private let name: String
    init(name: String) { this.name = name }
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(name, "Atomic registration fixture.", objectValue([]), [workspaceRead()])
    }
    public func validate(input: JsonNode): SdkResult<JsonNode> { SdkResult.Ok(input) }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        SdkResult.Ok(OperationIntent.WorkspaceSearch(WorkspaceSearchIntent(invocation.callId)))
    }
    public func decode(_invocation: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        let _ = _invocation
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func hasDefinition(catalog: ToolCatalog, name: String): Bool {
    for (definition in catalog.definitions() where definition.name == name) { return true }
    false
}

class RecordingHost <: ExtensionOperationHost {
    var searchExecutions: Int64 = 0
    var writeExecutions: Int64 = 0
    var hostOperationExecutions: Int64 = 0

    public func resolveCapability(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): Capability {
        if (requirement.name == "workspace.write") {
            let path = match (input.field("path")) {
                case Some(value) => value.text
                case None => ""
            }
            Capability(CapabilityKind.WorkspaceWrite, resource: path)
        } else if (requirement.name == "network.http") {
            Capability(CapabilityKind.NetworkAccess)
        } else {
            Capability(CapabilityKind.WorkspaceRead)
        }
    }

    public func approvalMetadata(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): ToolApprovalMetadata {
        defaultToolApprovalMetadata(resolveCapability(requirement, input))
    }

    public func execute(
        _context: ToolInvocationContext,
        intent: OperationIntent
    ): Result<ExecutionResult> {
        let _ = _context
        match (intent) {
            case OperationIntent.WorkspaceSearch(_) =>
                searchExecutions += 1
            case OperationIntent.WorkspaceWrite(_) =>
                writeExecutions += 1
            case OperationIntent.HostOperation(_) =>
                hostOperationExecutions += 1
        }
        Result.Ok(ExecutionResult(objectValue([
            ValueField("host", textValue("trusted"))
        ])))
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
