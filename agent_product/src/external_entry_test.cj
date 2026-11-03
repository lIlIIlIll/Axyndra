package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ExternalProductAuthorizer <: ExternalIngressAuthorizer {
    let binding: ExternalIngressBinding
    init(binding: ExternalIngressBinding) { this.binding = binding }
    public func currentBinding(): Result<ExternalIngressBinding> { Result.Ok(binding) }
}

class ExternalProductProbe <: ToolExecutor {
    var calls: Int64 = 0
    var connection: ?ExternalIngressConnection = None
    let cancelOnExecute: Bool
    let postCancelKind: ?AgentErrorKind
    var observedCancellation = false
    init(cancelOnExecute: Bool, postCancelKind!: ?AgentErrorKind = None) { this.cancelOnExecute = cancelOnExecute; this.postCancelKind = postCancelKind }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let source = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return Result.Err(AgentError(AgentErrorKind.Internal, "fixture.external_source_missing", "missing source"))
        }
        if (context.trustedControl || source.runId.value != context.runId.value || source.epoch != context.epoch ||
            match (source.origin) { case DirectCallOrigin.External(_) => false; case _ => true }) {
            return Result.Err(AgentError(AgentErrorKind.Internal, "fixture.external_source_invalid", "incorrect live external source"))
        }
        source.validateLiveSource().value().getOrThrow()
        calls += 1
        if (cancelOnExecute) {
            connection.getOrThrow().revoke()
            observedCancellation = context.cancellation.isCancelled()
        }
        match (postCancelKind) {
            case Some(kind) => return Result.Err(AgentError(kind, "fixture.external_uncertain", "exact conservative executor outcome", retryable: false, fallbackAllowed: false))
            case None => ()
        }
        Result.Ok(ToolResult(prepared.call.callId, objectValue([ValueField("origin", directCallOriginValue(source.origin))])))
    }
}

class ExternalProductFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let probe: ExternalProductProbe
    let connection: ExternalIngressConnection
    let call = ToolCall("external-product-call", "fixture_external", objectValue([
        ValueField("principal", textValue("untrusted-input-admin"))]))
    init(label: String, controlOnly!: Bool = false, cancelOnExecute!: Bool = false,
        cancelOnPrepare!: Bool = false, postCancelKind!: ?AgentErrorKind = None) {
        root = pluginContractTemp("external-entry-" + label)
        Directory.create(root, recursive: true)
        product = openProduct(config: ProductConfig(workspaceRoot: root, settingsRoot: root + "/settings",
            stateRoot: root + "/state", fixture: true, approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)).value().getOrThrow()
        database = SqliteDatabase(root + "/state/state.db")
        probe = ExternalProductProbe(cancelOnExecute, postCancelKind: postCancelKind)
        let localProbe = probe
        let resolver: ToolCanonicalArgumentsResolver = { _, value =>
            if (cancelOnPrepare && localProbe.connection.isSome()) { localProbe.connection.getOrThrow().revoke() }
            Result.Ok(value.arguments)
        }
        let descriptor = ToolDescriptor(ModelToolDefinition(call.name, "Actual External gateway fixture",
            objectValue([ValueField("type", textValue("object"))])), Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true, controlOnly: controlOnly, neverReplay: true,
            implementationVersion: "external-entry-fixture-v1", canonicalArgumentsResolver: Some(resolver))
        product.registerTool(descriptor, probe).value().getOrThrow()
        let context = ToolInvocationContext(RunId("export-snapshot"), SessionId("external-product-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]), toolContext: productToolContext(root))
        let plan = normalizedToolOperationPlan(context, call, descriptor.resolved(call))
        let binding = ExternalIngressBinding("product-external-grant", "product-external-connection", "authenticated-principal", 1,
            ThreadId(context.sessionId.value), externalInvocationAuthorityScope(context),
            [ExternalExportBinding(call.name, plan.implementation.toolVersion, plan.implementation.implementationFingerprint, plan.implementation.schemaDigest)],
            context.capabilities.values, agentUtcMillis() + 600000, [])
        connection = openExternalIngressConnection(ExternalProductAuthorizer(binding), { => agentUtcMillis() }).value().getOrThrow()
        probe.connection = Some(connection)
    }
    func invoke(id: String, approval!: ?ApprovalDecision = None): Result<ToolInvocationResult> {
        product.vnext.executeExternalTool(connection, ExternalRequestId(ExternalRequestIdKind.Text, value: id), call,
            approvalDecision: approval, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func close(): Unit { connection.revoke(); let _ = product.close(); database.close(); remove(root, recursive: true) }
}

@Test
class ProductExternalEntryTests {
    @TestCase
    func approvedExternalUsesRealSourceAndReceiptWithoutTrustedControl(): Unit {
        let fixture = ExternalProductFixture("approved")
        try {
            let result = fixture.invoke("request-1", approval: Some(ApprovalDecision.Approve))
            @Expect(hostServiceEntrySucceeded(result), true)
            @Expect(fixture.probe.calls, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals WHERE decision='approved'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.query("SELECT kind FROM lane_inbox_entries")[0].required(0), "external")
            @Expect(match (effectiveDirectCallOrigin(decodeStoredProvenance(fixture.database.query(
                "SELECT provenance FROM items WHERE kind='tool_call'")[0].required(0)))) {
                case DirectCallOrigin.External(value) => value.principalId == "authenticated-principal" && value.requestId.value == "request-1"
                case _ => false
            }, true)
            @Expect(fixture.invoke("request-1", approval: Some(ApprovalDecision.Approve)).isError(), true)
            @Expect(fixture.probe.calls, 1)
        } finally { fixture.close() }
    }

    @TestCase
    func externalDoesNotBypassApprovalOrHostOnlyVisibility(): Unit {
        let fixture = ExternalProductFixture("approval")
        let control = ExternalProductFixture("control", controlOnly: true)
        try {
            @Expect(match (fixture.invoke("request-pending")) { case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => true; case _ => false }, true)
            @Expect(hostServiceEntrySucceeded(fixture.invoke("request-reject", approval: Some(ApprovalDecision.Reject))), false)
            @Expect(hostServiceEntrySucceeded(control.invoke("control-guess", approval: Some(ApprovalDecision.Approve))), false)
            @Expect(fixture.probe.calls, 0)
            @Expect(control.probe.calls, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(control.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
        } finally { control.close(); fixture.close() }
    }

    @TestCase
    func revocationDuringPreparePreventsCanonicalToolCallAndEffect(): Unit {
        let fixture = ExternalProductFixture("prepare-revoke", cancelOnPrepare: true)
        try {
            @Expect(hostServiceEntrySucceeded(fixture.invoke("prepare", approval: Some(ApprovalDecision.Approve))), false)
            @Expect(fixture.probe.calls, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func revocationAfterHandoffCancelsActualTokenAndKeepsUnknownReceipt(): Unit {
        let fixture = ExternalProductFixture("execute-revoke", cancelOnExecute: true)
        try {
            @Expect(hostServiceEntrySucceeded(fixture.invoke("execute", approval: Some(ApprovalDecision.Approve))), false)
            @Expect(fixture.probe.calls, 1)
            @Expect(fixture.probe.observedCancellation, true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
        } finally { fixture.close() }
    }
    @TestCase
    func postExecutorSourceLossRetainsActualUnknownOutcome(): Unit {
        let fixture = ExternalProductFixture("source-unknown", cancelOnExecute: true, postCancelKind: Some(AgentErrorKind.RecoveryRequired))
        try {
            let result = fixture.invoke("source-unknown", approval: Some(ApprovalDecision.Approve))
            @Expect(match (result) { case Result.Err(error) => error.kind == AgentErrorKind.RecoveryRequired &&
                error.code == "fixture.external_uncertain" && !error.retryable && !error.fallbackAllowed; case _ => false }, true)
            @Expect(fixture.probe.calls, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func postExecutorSourceLossRetainsProvedCancellation(): Unit {
        let fixture = ExternalProductFixture("source-cancelled", cancelOnExecute: true, postCancelKind: Some(AgentErrorKind.Cancelled))
        try {
            let result = fixture.invoke("source-cancelled", approval: Some(ApprovalDecision.Approve))
            @Expect(match (result) { case Result.Err(error) => error.kind == AgentErrorKind.Cancelled &&
                error.code == "fixture.external_uncertain"; case _ => false }, true)
            @Expect(fixture.probe.observedCancellation, true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
        } finally { fixture.close() }
    }

}
