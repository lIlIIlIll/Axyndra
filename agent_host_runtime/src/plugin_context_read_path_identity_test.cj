package agent_host_runtime

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func pathIdentityRequire<T>(value: Result<T>): T {
    match (value) { case Result.Ok(item) => item; case Result.Err(error) => throw IllegalStateException(error.code) }
}
private func pathIdentityRequest(source: String, path: String): AgentValue {
    objectValue([ValueField("source", textValue(source)), ValueField("path", textValue(path)),
        ValueField("mode", textValue(CONTEXT_READ_PATH_IDENTITY_KIND))])
}
private func pathIdentityContext(f: LivePolicyCanonicalFixture,
    capabilities!: CapabilitySet = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])): ToolInvocationContext {
    ToolInvocationContext(f.active.runId, SessionId(f.active.threadId.value), capabilities, epoch: f.active.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: f.root, cwd: f.root), cancellation: f.cancellation.token,
        contextProjection: f.active.contextSnapshot)
}

// The optional Tool audit port writes real SQLite rows; it mints no Source,
// approval or Receipt. Those remain in the original Runtime/Store path.
class PathIdentitySqlAudit <: AuditPort {
    private let database: SqliteDatabase
    init(database: SqliteDatabase) { this.database = database }
    public func append(event: AgentEvent): Result<Unit> {
        try {
            database.transaction<Unit>({ tx: SqliteTransaction =>
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                    "VALUES(?, ?, NULL, 'path_identity_tool_fixture', ?, 14)",
                    [SqlParameter.Text("window-thread"), SqlParameter.Text(event.runId.value),
                        SqlParameter.Text(encodeStoredValue(eventProtocolDetail(event)))]) })
            Result.Ok(())
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.Internal,
            "fixture.path_identity_audit", "actual SQLite Tool audit could not append")) }
    }
}

@Test
class HostContextReadPathIdentityTests {
    @TestCase
    func OptinObservesLargeInvalidUtf8BinaryAndDirectoryWithoutContentExpansion(): Unit {
        let f = ReadViewContextMetadataFixture(); let cancellation = CancellationSource()
        try {
            let binary = f.workspace + "/program.bin"
            File.writeTo(binary, Array<Byte>(4194305, repeat: 255))
            File.writeTo(f.workspace + "/sub/child.bin", Array<Byte>(8, repeat: 255))
            let context = f.context(f.workspace, cancellation.token)
            let requests = listValue([pathIdentityRequest("program.bin", "dap/program"), pathIdentityRequest("sub/.", "dap/cwd")])
            @Expect(HostReadViewCollector(context, f.host).collect(requests).isError())
            let collector = HostReadViewCollector(context, f.host, pathIdentityAllowed: true)
            let values = pathIdentityRequire(collector.collect(requests))
            @Expect(values.items.size, 2); @Expect(!collector.requiresApproval)
            @Expect(values.items[0].field("bytes").getOrThrow().asNumberText(), "0")
            @Expect(values.items[0].field("is_directory").getOrThrow().asBool(), false)
            @Expect(values.items[0].field("source").getOrThrow().text, binary)
            @Expect(values.items[0].field("witness").getOrThrow().text.split(":")[4], "4194305")
            @Expect(values.items[1].field("is_directory").getOrThrow().asBool(), true)
            @Expect(values.items[1].field("source").getOrThrow().text, f.workspace + "/sub")
            @Expect(values.items[0].field("text").isNone()); @Expect(values.items[1].field("entries").isNone())
        } finally { cancellation.close(); f.close() }
    }
    @TestCase
    func SamePathChangedKindWitnessLinksAndMissingTargetsRefuseBeforePublication(): Unit {
        let f = ReadViewContextMetadataFixture(); let cancellation = CancellationSource()
        try {
            let context = f.context(f.workspace, cancellation.token); let file = f.workspace + "/program"
            File.writeTo(file, [b'a'])
            let observed = pathIdentityRequire(hostObserveContextReadPathIdentity(f.host, context, file, "dap/program", Option<HostContextReadScopes>.None))
            @Expect(hostValidateContextReadPathIdentity(f.host, context, observed, None).isOk())
            File.writeTo(file, [b'a', b'b'])
            @Expect(hostValidateContextReadPathIdentity(f.host, context, observed, None).isError())
            remove(file); Directory.create(file)
            @Expect(hostValidateContextReadPathIdentity(f.host, context, observed, None).isError())
            SymbolicLink.create(f.workspace + "/alias", to: file)
            for (source in [f.workspace + "/alias", f.workspace + "/missing", f.workspace + "/alias/child"]) {
                @Expect(hostObserveContextReadPathIdentity(f.host, context, source, "dap/program", None).isError()) }
            let duplicate = listValue([pathIdentityRequest(file, "dap/cwd"), pathIdentityRequest(file, "dap/cwd")])
            @Expect(HostReadViewCollector(context, f.host, pathIdentityAllowed: true).collect(duplicate).isError())
            let injected = pathIdentityRequest(file, "dap/cwd"); injected.put("is_directory", boolValue(true))
            @Expect(HostReadViewCollector(context, f.host, pathIdentityAllowed: true).collect(listValue([injected])).isError())
            let _ = cancellation.cancel()
            @Expect(hostObserveContextReadPathIdentity(f.host, context, file, "dap/cwd", None).isError())
        } finally { cancellation.close(); f.close() }
    }
    @TestCase
    func ActualExternalClassificationRetainsNormalReviewAndExactReadCeiling(): Unit {
        let f = ReadViewContextMetadataFixture(); let cancellation = CancellationSource()
        try {
            let external = f.root + "/external.bin"; File.writeTo(external, [b'a'])
            let context = f.context(f.workspace, cancellation.token)
            let call = ToolCall("metadata-classification", HOST_CONTEXT_READ_TOOL, objectValue([
                ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", objectValue([])),
                ValueField("resources", listValue([pathIdentityRequest(external, "dap/source")]))]))
            let canonical = pathIdentityRequire(hostPrepareContextRead(f.host, context, call))
            @Expect(canonical.field("requires_approval").getOrThrow().asBool())
            @Expect(canonical.field("resources").getOrThrow().items[0].field("permission").getOrThrow().text != "workspace.read")
            let plan = NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, canonical, hostContextReadCapabilities(ToolCall(call.callId, call.name, canonical)),
                OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(canonical)),
                toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION, implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
            @Expect(DefaultCapabilityPolicy().evaluate(context, plan).requirement, PermissionRequirement.Confirm)
            let narrow = f.context(f.workspace, cancellation.token,
                caps: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: f.workspace + "/sub")]))
            @Expect(hostPrepareContextRead(f.host, narrow, call).isError())
            @Expect(!context.capabilities.allows(CapabilityKind.ProcessSpawn))
            @Expect(!context.capabilities.allows(CapabilityKind.WorkspaceWrite))
        } finally { cancellation.close(); f.close() }
    }
    @TestCase
    func ActualRootPipelineHandoffCommitsTheWholeZeroContentWitnessFact(): Unit {
        let f = LivePolicyCanonicalFixture(); let host = HostJavaScriptPluginHost({ path => HostLocalReadTargetInspector(path) })
        try {
            let file = f.root + "/program.bin"; File.writeTo(file, Array<Byte>(4194305, repeat: 255))
            let context = pathIdentityContext(f); let catalog = ToolCatalog()
            let _ = pathIdentityRequire(hostRegisterContextRead(catalog, host, f.store))
            let pipeline = ToolPipeline(catalog, f.store, PathIdentitySqlAudit(f.database), HostIds())
            let request = objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", objectValue([])),
                ValueField("resources", listValue([pathIdentityRequest(file, "dap/program"), pathIdentityRequest(f.root, "dap/cwd")]))])
            let call = ToolCall("path-identity-read-call", HOST_CONTEXT_READ_TOOL, request)
            let packageDigest = httpIntentText(f.binding, "package_digest"); let configurationDigest = httpIntentText(f.binding, "configuration_digest")
            let read = ToolPreparationRead("axyndra:live-fixture", packageDigest, configurationDigest, request,
                { _, _ => Result<AgentValue>.Ok(objectValue([])) }, boundary: Some({ _, _ => f.current() }))
            let admission = pathIdentityRequire(f.runtime.beginContextRead(call, read.ownerNamespace, packageDigest, configurationDigest,
                "path-identity-read", f.active.runId, f.active.epoch, contextReadProjectionDigest(f.active.contextSnapshot), parent: Some(f.parent)))
            let prepared = match (pathIdentityRequire(pipeline.prepareContextRead(context, call, admission, read: Some(read)))) {
                case ToolPreparation.Ready(value) => value
                case _ => throw IllegalStateException("real workspace identity unexpectedly denied or required approval") }
            let canonicalCall = ToolCall(call.callId, call.name, prepared.operationPlan.canonicalArguments)
            let source = pathIdentityRequire(f.runtime.commitContextReadToolCall(admission, ItemId("path-identity-read-item"),
                prepared.operationId, canonicalCall, prepared.operationPlan))
            let _ = pathIdentityRequire(f.store.prepareDirectOperation(source, prepared.operationPlan))
            let bound = pathIdentityRequire(pipeline.bindDirectRoot(context, prepared, source))
            let result = match (pathIdentityRequire(pipeline.executePrepared(context, bound))) {
                case ToolInvocationResult.Completed(value) => value
                case _ => throw IllegalStateException("real context read did not return its complete physical observation") }
            @Expect(!result.isError); @Expect(result.output.field("resources").getOrThrow().items.size, 2)
            let observed = result.output.field("resources").getOrThrow().items[0]
            @Expect(observed.field("text").getOrThrow().text, "")
            @Expect(observed.field("sha256").getOrThrow().text, modelPolicySha256Text(""))
            @Expect(observed.field("is_directory").getOrThrow().asBool(), false)
            @Expect(observed.field("witness").getOrThrow().text, prepared.operationPlan.canonicalArguments.field("resources").getOrThrow().items[0].field("witness").getOrThrow().text)
            let slots = f.database.query("SELECT reserved_receipt_id,reserved_result_item_id FROM operation_effect_records WHERE operation_id=? AND run_id=?",
                [SqlParameter.Text(prepared.operationId.value), SqlParameter.Text(f.active.runId.value)])
            @Expect(slots.size, 1)
            let resolved = pathIdentityRequire(f.runtime.resolveOperation(ItemId(slots[0].required(1)), prepared.operationId,
                CanonicalToolCallId(call.callId), prepared.operationPlan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(result)), slots[0].required(0), 13,
                expectedRunId: Some(f.active.runId), expectedEpoch: Some(f.active.epoch)))
            @Expect(resolved.semanticCommit.isSome())
            match (resolved.semanticCommit.getOrThrow()) { case SemanticCommitDecision.Committed(_, _) => ()
                case _ => throw IllegalStateException("real identity Receipt/result failed canonical commit") }
            let fact = pathIdentityRequire(f.store.loadContextReadFact(prepared.operationId, f.active.runId))
            @Expect(canonicalAgentValue(fact.output()), canonicalAgentValue(result.output))
            @Expect(fact.outputDigest, modelPolicySha256Text(stringifyUnifiedJson(result.output)))
            @Expect(fact.origin.parentCallItemId, f.parent.itemId().value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'"), 1)
            // Corrupting a retained result cannot manufacture a valid fact:
            // the original Store independently compares full item/Receipt.
            f.database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id=?",
                [SqlParameter.Text(encodeStoredValue(objectValue([]))), SqlParameter.Text(prepared.operationId.value)])
            @Expect(f.store.loadContextReadFact(prepared.operationId, f.active.runId).isError())
        } finally { let _ = host.close(); f.close() }
    }
}
