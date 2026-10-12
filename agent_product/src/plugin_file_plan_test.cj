package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func pluginPlanTestProposal(): AgentValue {
    objectValue([
        ValueField("schema", textValue(PRODUCT_FILE_APPLICATION_PROPOSAL_SCHEMA)),
        ValueField("operations", listValue([objectValue([
            ValueField("kind", textValue("replace")), ValueField("path", textValue("input.txt")),
            ValueField("expected_content", textValue("original\n")), ValueField("content", textValue("changed\n"))
        ])]))
    ])
}

@Test
class PluginFilePlanServiceTests {
    @TestCase
    func legacyRecoveryReceiptCannotLaunderUnprovenProgramSource(): Unit {
        let root = pluginContractTemp("legacy-recovery-origin")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/input.txt", "original\n".toArray())
        let product = openProcessServiceProduct(root)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let workspace = LocalWorkspace(root)
            let artifacts = ProductArtifactStore(root + "/state", database: Some(database))
            let programDigest = "0000000000000000000000000000000000000000000000000000000000000000"
            let workspaceId = textValue("workspace:sha256:" + artifactSha256(root.toArray()))
            let original = generateProductApplicationPlanFromOrigin(pluginPlanTestProposal(), objectValue([
                ValueField("root_operation_id", textValue("absent-program-operation")),
                ValueField("program_id", textValue(PRODUCT_ARTIFACT_PREFIX + programDigest)),
                ValueField("program_digest", textValue(programDigest)),
                ValueField("workspace_id", workspaceId)
            ]), workspace, artifacts).value().getOrThrow()
            let operation = OperationId("legacy-recovery-operation")
            // Reproduce the old recovery executor's output: it copied the
            // unverified Program claim and replaced only the root Operation.
            let continuation = generateProductApplicationPlanFromOrigin(pluginPlanTestProposal(), objectValue([
                ValueField("root_operation_id", textValue(operation.value)),
                ValueField("program_id", textValue(PRODUCT_ARTIFACT_PREFIX + programDigest)),
                ValueField("program_digest", textValue(programDigest)),
                ValueField("workspace_id", workspaceId)
            ]), workspace, artifacts).value().getOrThrow()
            let stored = loadProductStoredFileApplicationPlan(original, workspace, artifacts).value().getOrThrow()
            let output = productApplicationRecoveryOutput("continuation_ready", stored,
                [objectValue([ValueField("ordinal", integerValue(0)), ValueField("operation", textValue("replace")),
                    ValueField("path", textValue("input.txt")), ValueField("status", textValue("not_started"))])],
                Some(continuation))

            let sink = SqliteThreadCommitSink(database)
            let thread = ThreadId("legacy-recovery-thread")
            let turn = SemanticTurnId("legacy-recovery-turn")
            let run = RunId("legacy-recovery-run")
            let callItem = ItemId("legacy-recovery-call-item")
            let callId = CanonicalToolCallId("legacy-recovery-call")
            let coordinator = ThreadCoordinator(sink.createThread(thread, root), sink)
            let active = coordinator.startTurn(turn, run, ItemId("legacy-recovery-user"),
                ThreadItemContent.UserMessage(textMessageParts("historical recovery")), createdAtMillis: 10)
                .value().getOrThrow()
            @Expect(match (coordinator.commit(ResultEnvelope(thread, turn, run, active.activeEpoch, 1,
                ThreadItemDraft(callItem, ThreadItemContent.ToolCall(callId, "recover_file_plan", original),
                    ItemProvenance("direct_tool", runId: Some(run), operationId: Some(operation)))))) {
                case SemanticCommitDecision.Committed(_, _) => true
                case _ => false
            }, true)
            let plan = NormalizedOperationPlan("recover_file_plan", original,
                [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly,
                OperationRetryDisposition.Safe, "legacy-recovery-binding",
                toolVersion: "product-file-plan-recovery-v1",
                implementationFingerprint: "product-file-plan-recovery-v1")
            let operations = DurableOperationStore(database)
            operations.prepareTrustedControlOperation(operation, run, callItem, plan).value().getOrThrow()
            operations.markExecuting(operation, run, plan, 11, false).value().getOrThrow()
            operations.markExecutionHandoff(operation, run, thread, 12).value().getOrThrow()
            let receiptId = "receipt-" + operation.value
            @Expect(match (coordinator.commitOperationResult(ResultEnvelope(thread, turn, run, active.activeEpoch, 2,
                ThreadItemDraft(ItemId("legacy-recovery-result"), ThreadItemContent.ToolResult(callId, operation,
                    receiptId, output, false), ItemProvenance("operation", runId: Some(run), operationId: Some(operation)),
                    createdAtMillis: 13)),
                VNextOperationReceipt(receiptId, operation, OperationOutcome.Completed, output,
                    objectValue([ValueField("stage", textValue("executing"))]), 13), "running")) {
                case SemanticCommitDecision.Committed(_, _) => true
                case _ => false
            }, true)
            coordinator.completeTurn(turn, run, active.activeEpoch, finishedAtMillis: Some(14)).value().getOrThrow()
            let committed = operations.loadCommittedToolResult(operation, run).value().getOrThrow().getOrThrow()
            @Expect(committed.isError, false)
            @Expect(pluginReceiptText(committed.output.field("continuation_plan").getOrThrow(), "plan_ref"),
                pluginReceiptText(continuation, "plan_ref"))
            @Expect(pluginReceiptText(committed.output.field("continuation_plan").getOrThrow(), "plan_digest"),
                pluginReceiptText(continuation, "plan_digest"))
            @Expect(operations.operationRunId(operation).value().getOrThrow().value, run.value)
            @Expect(operations.operationRunId(OperationId("absent-program-operation")).isError(), true)

            let handle = objectValue([ValueField("plan_ref", continuation.field("plan_ref").getOrThrow()),
                ValueField("plan_digest", continuation.field("plan_digest").getOrThrow())])
            for (tool in ["apply_file_plan", "recover_file_plan"]) {
                let rejected = product.invokeLocalTool(SessionId("legacy-recovery-reject-" + tool), tool, handle)
                @Expect(rejected.isOk(), false)
                @Expect(rejected.error().getOrThrow().code, "application_plan.origin_uncommitted")
                @Expect(String.fromUtf8(File.readFrom(root + "/input.txt")), "original\n")
            }
            @Expect(artifacts.read(pluginReceiptText(continuation, "plan_ref")).isOk(), true)
            @Expect(operations.loadCommittedToolResult(operation, run).value().getOrThrow().isSome(), true)
            @Expect(database.query("PRAGMA foreign_key_check").isEmpty(), true)
        } finally {
            database.close()
            product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func pluginCannotSupplyIdentityOrOriginThroughProposalService(): Unit {
        let binding = ProductPluginServiceIdentity(ProductJavaScriptPluginHost(), "unmounted", 1u64)
        let proposal = pluginPlanTestProposal()
        for (name in ["plugin", "generation", "package_digest", "source"]) {
            let result = binding.filePlanArguments(objectValue([
                ValueField("proposal", proposal), ValueField(name, textValue("forged"))
            ]))
            @Expect(result.isOk(), false)
            @Expect(result.error().getOrThrow().code, "extension.file_plan_arguments_invalid")
        }
        let fields = ArrayList<ValueField>(proposal.fields)
        fields.add(ValueField("source", objectValue([ValueField("root_operation_id", textValue("forged"))])))
        let forged = binding.filePlanArguments(objectValue([ValueField("proposal", objectValue(fields.toArray()))]))
        @Expect(forged.isOk(), false)
        @Expect(forged.error().getOrThrow().code, "application_plan.plugin_proposal_invalid")
    }

    @TestCase
    func orphanArtifactsAndDowngradedSourcesCannotApplyOrRecover(): Unit {
        let root = pluginContractTemp("orphan-file-plan")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/input.txt", "original\n".toArray())
        let product = openProcessServiceProduct(root)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let artifacts = ProductArtifactStore(root + "/state", database: Some(database))
            let zeroDigest = "0000000000000000000000000000000000000000000000000000000000000000"
            let source = objectValue([
                ValueField("kind", textValue("plugin")), ValueField("run_id", textValue("orphan-run")),
                ValueField("root_operation_id", textValue("orphan-parent")),
                ValueField("generation_operation_id", textValue("orphan-proposal")),
                ValueField("plugin_namespace", textValue("orphan")), ValueField("plugin_version", textValue("1.0.0")),
                ValueField("package_digest", textValue("sha256:" + zeroDigest)),
                ValueField("contribution", textValue("plugin.orphan.edit")),
                ValueField("instance_generation", textValue("1")),
                ValueField("workspace_id", textValue("workspace:sha256:" + artifactSha256(root.toArray())))
            ])
            let summary = generateProductApplicationPlanFromOrigin(
                pluginPlanTestProposal(), source, LocalWorkspace(root), artifacts).value().getOrThrow()
            let fields = ArrayList<ValueField>()
            for (field in summary.fields where field.name != "schema" && field.name != "source" &&
                field.name != "plan_ref" && field.name != "plan_digest") { fields.add(field) }
            fields.add(ValueField("schema", textValue(PRODUCT_FILE_APPLICATION_PLAN_SCHEMA)))
            fields.add(ValueField("source", objectValue([
                ValueField("root_operation_id", textValue("orphan-parent")),
                ValueField("program_id", textValue(PRODUCT_ARTIFACT_PREFIX + zeroDigest)),
                ValueField("program_digest", textValue(zeroDigest))
            ])))
            let downgraded = artifacts.persistText(stringifyUnifiedJson(objectValue(fields.toArray()))).value().getOrThrow()
            let handles = [objectValue([
                ValueField("plan_ref", summary.field("plan_ref").getOrThrow()),
                ValueField("plan_digest", summary.field("plan_digest").getOrThrow())
            ]), objectValue([
                ValueField("plan_ref", textValue(downgraded.reference)),
                ValueField("plan_digest", textValue(downgraded.sha256))
            ])]
            for (handle in handles) {
                for (tool in ["apply_file_plan", "recover_file_plan"]) {
                    let rejected = product.invokeLocalTool(SessionId("orphan-plan-check"), tool, handle)
                    @Expect(rejected.isOk(), false)
                    @Expect(rejected.error().getOrThrow().code, "application_plan.origin_uncommitted")
                    @Expect(String.fromUtf8(File.readFrom(root + "/input.txt")), "original\n")
                }
            }
            // Rejection never destroys old-format or orphan artifact bytes.
            @Expect(artifacts.read(downgraded.reference).isOk(), true)
            @Expect(artifacts.read(summary.field("plan_ref").getOrThrow().text).isOk(), true)
            let blankSource = objectValue([
                ValueField("root_operation_id", textValue(" \t\n")),
                ValueField("program_id", textValue(PRODUCT_ARTIFACT_PREFIX + zeroDigest)),
                ValueField("program_digest", textValue(zeroDigest))
            ])
            @Expect(validateStoredApplicationPlanSource(blankSource, PRODUCT_FILE_APPLICATION_PLAN_SCHEMA).isOk(), false)
            let blankPluginFields = ArrayList<ValueField>()
            for (field in summary.field("source").getOrThrow().fields) {
                blankPluginFields.add(if (field.name == "run_id") { ValueField("run_id", textValue(" \t\n")) } else { field })
            }
            @Expect(validateStoredApplicationPlanSource(objectValue(blankPluginFields.toArray()),
                PRODUCT_PLUGIN_FILE_APPLICATION_PLAN_SCHEMA).isOk(), false)
        } finally {
            database.close()
            product.close()
            remove(root, recursive: true)
        }
    }
}
