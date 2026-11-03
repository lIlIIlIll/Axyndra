package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class DirectPreparationContinuationTests {
    @TestCase
    func aBareDecisionCannotApproveTwoPlansOrCreateAnUnexecutedRun(): Unit {
        let root = pluginContractTemp("direct-read-bare-decision")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = documentFixtureInstall(product, root)
            // Existing Some(decision) gateways cannot reinterpret a read-backed
            // contribution as one already-reviewed HostService operation.
            let description = HostServiceOrigin("fixture", productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)),
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "fixture", HostServiceAction.Start, "fixture")
            let result = product.vnext.executeHostServiceTool(SessionId("bare-decision"), description,
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("bare-decision", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update", documentFixtureArguments()),
                approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(match (result) { case Result.Err(error) => error.code == "context.read_separate_approval_required"; case _ => false })
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func actualDirectReadAndMutationHaveIndependentFrozenApprovalOnOneRun(): Unit {
        let root = pluginContractTemp("direct-read-approval")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        let cancellation = CancellationSource()
        let owner = ProductDirectPreparationOwner({ => cancellation.token.check() })
        try {
            let record = documentFixtureInstall(product, root)
            let name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update"
            let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
            let started = product.vnext.executeDeferredCanonicalTool(SessionId("direct-review"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("direct-review", name, documentFixtureArguments()), owner, cancellation.token, budget: budget)
            @Expect(match (started) { case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => true; case _ => false })
            let read = owner.approval().getOrThrow()
            @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='waiting_approval'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(owner.decide("another-operation", ApprovalDecision.Approve).isError())
            @Expect(!read.sessionApprovalAllowed)
            let invalid = owner.decide(read.operationId.value, ApprovalDecision.ApproveSession)
            @Expect(match (invalid) { case Result.Err(error) => error.code == "approval.session_scope_forbidden"; case _ => false })
            @Expect(owner.approval().getOrThrow().operationId.value, read.operationId.value)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='waiting_approval'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            let first = owner.decide(read.operationId.value, ApprovalDecision.Approve)
            @Expect(match (first) { case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => true; case _ => false })
            let mutation = owner.approval().getOrThrow()
            @Expect(mutation.toolName, name); @Expect(mutation.operationId.value != read.operationId.value)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
            let completed = owner.decide(mutation.operationId.value, ApprovalDecision.Approve)
            @Expect(match (completed) { case Result.Ok(ToolInvocationResult.Completed(value)) => !value.isError; case _ => false })
            match (completed) { case Result.Ok(ToolInvocationResult.Completed(value)) =>
                try { expectCanonicalReturnedReceipt(database, value) } finally { value.releasePayload() }
                case _ => () }
            expectCanonicalReservedRootResults(database, "direct-review", 2)
            @Expect(owner.approval().isNone()); @Expect(owner.decide(mutation.operationId.value, ApprovalDecision.Approve).isError())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(budget.snapshot().toolCalls, 3); @Expect(budget.snapshot().activeTools, 0)
        } finally { let _ = cancellation.cancel(); let _ = owner.cancel(); cancellation.close(); database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func rejectingOrCancellingTheActualReadSettlesItsUnpreparedParentWithoutEffect(): Unit {
        for (cancelled in [false, true]) {
            let root = pluginContractTemp("direct-read-reject")
            Directory.create(root + "/workspace", recursive: true)
            let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
            let database = SqliteDatabase(root + "/state/state.db")
            let cancellation = CancellationSource()
            let owner = ProductDirectPreparationOwner({ => cancellation.token.check() })
            try {
                let record = documentFixtureInstall(product, root)
                let result = product.vnext.executeDeferredCanonicalTool(SessionId("direct-reject"),
                    CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                    ToolCall("direct-reject", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update", documentFixtureArguments()),
                    owner, cancellation.token)
                @Expect(match (result) { case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => true; case _ => false })
                let read = owner.approval().getOrThrow()
                if (cancelled) { let _ = cancellation.cancel(); let _ = owner.cancel() }
                else { let _ = owner.decide(read.operationId.value, ApprovalDecision.Reject) }
                @Expect(owner.approval().isNone())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('failed','cancelled')"), 1)
                expectCanonicalReservedRootResults(database, "direct-reject", 2)
            } finally { let _ = cancellation.cancel(); let _ = owner.cancel(); cancellation.close(); database.close(); product.close(); remove(root, recursive: true) }
        }
    }

    @TestCase
    func changedDocumentRightsAfterReadCannotUseTheOldMutationApproval(): Unit {
        let root = pluginContractTemp("direct-read-revoked")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        let cancellation = CancellationSource()
        let owner = ProductDirectPreparationOwner({ => cancellation.token.check() })
        try {
            let record = documentFixtureInstall(product, root)
            let _ = product.vnext.executeDeferredCanonicalTool(SessionId("direct-revoked"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("direct-revoked", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update", documentFixtureArguments()), owner, cancellation.token)
            let read = owner.approval().getOrThrow()
            let _ = owner.decide(read.operationId.value, ApprovalDecision.Approve)
            let mutation = owner.approval().getOrThrow()
            documentFixtureConfigure(root, record, false)
            let result = owner.decide(mutation.operationId.value, ApprovalDecision.Approve)
            @Expect(result.isError() || match (result) { case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => true })
            @Expect(owner.approval().isNone())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        } finally { let _ = cancellation.cancel(); let _ = owner.cancel(); cancellation.close(); database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func actualSqliteReadAdmissionAndReceiptFailuresRetainRecoveryDebt(): Unit {
        for (receiptFailure in [false, true]) {
            let root = pluginContractTemp("direct-read-fault")
            Directory.create(root + "/workspace", recursive: true)
            let product = workspacePluginOpen(root, ApprovalMode.Yolo)
            let database = SqliteDatabase(root + "/state/state.db")
            try {
                let record = documentFixtureInstall(product, root)
                database.execute(if (receiptFailure) {
                    "CREATE TRIGGER direct_read_fault BEFORE INSERT ON operation_receipts BEGIN SELECT RAISE(ABORT,'fixture receipt'); END"
                } else {
                    "CREATE TRIGGER direct_read_fault BEFORE INSERT ON operations WHEN NEW.tool_call_item_id LIKE 'context-read-item-%' BEGIN SELECT RAISE(ABORT,'fixture prepare'); END"
                })
                let result = product.vnext.executeCanonicalTool(SessionId("direct-fault"),
                    CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                    ToolCall("direct-fault", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update", documentFixtureArguments()),
                    budget: ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
                @Expect(result.isError())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='recovery_required'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"), 2)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_direct_preparation_rejection_only'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
            } finally { database.close(); product.close(); remove(root, recursive: true) }
        }
    }

    @TestCase
    func actualOptionalNoReadKeepsOneCanonicalParentAndIndependentUserApproval(): Unit {
        for (mode in ["yolo", "approve", "reject"]) {
            let root = pluginContractTemp("direct-optional-none-" + mode)
            Directory.create(root + "/workspace", recursive: true)
            let product = workspacePluginOpen(root, if (mode == "yolo") { ApprovalMode.Yolo } else { ApprovalMode.AlwaysAsk })
            let database = SqliteDatabase(root + "/state/state.db")
            let cancellation = CancellationSource()
            let owner = ProductDirectPreparationOwner({ => cancellation.token.check() })
            let probe = CanonicalRootSnapshotProbe("optional-none-v1")
            let thread = "optional-none-" + mode
            let name = "fixture_optional_read_none"
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            let reads = AtomicInt64(0)
            try {
                let descriptor = ToolDescriptor(ModelToolDefinition(name, "Actual optional pure preparation",
                    objectValue([ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
                    Capability(CapabilityKind.WorkspaceRead), sideEffecting: true,
                    implementationVersion: "optional-none-v1", preparationReadResolver: Some({ _, _ =>
                        let _ = reads.fetchAdd(1); Result<?ToolPreparationRead>.Ok(None) }))
                product.registerTool(descriptor, probe).value().getOrThrow()
                let call = ToolCall("optional-none-call", name, objectValue([]))
                let ceiling = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
                let started = if (mode == "yolo") { product.vnext.executeCanonicalTool(SessionId(thread), ceiling, call, budget: budget) }
                    else { product.vnext.executeDeferredCanonicalTool(SessionId(thread), ceiling, call, owner, cancellation.token, budget: budget) }
                if (mode == "yolo") {
                    let result = hostServiceEntryCompleted(started)
                    try { @Expect(!result.isError); expectCanonicalReturnedReceipt(database, result) }
                    finally { result.releasePayload() }
                } else {
                    @Expect(match (started) { case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => true; case _ => false })
                    let pending = owner.approval().getOrThrow()
                    @Expect(pending.toolName, name); @Expect(probe.calls, 0)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
                    let finished = owner.decide(pending.operationId.value,
                        if (mode == "approve") { ApprovalDecision.Approve } else { ApprovalDecision.Reject })
                    if (mode == "approve") {
                        let result = hostServiceEntryCompleted(finished)
                        try { @Expect(!result.isError); expectCanonicalReturnedReceipt(database, result) }
                        finally { result.releasePayload() }
                    }
                    @Expect(owner.approval().isNone())
                }
                @Expect(reads.load(), 1)
                @Expect(probe.calls, if (mode == "reject") { 0 } else { 1 })
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.context.read'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
                @Expect(budget.snapshot().activeTools, 0)
                if (mode != "reject") { @Expect(budget.snapshot().toolCalls, 1) }
                expectCanonicalReservedRootResults(database, thread, 1)
            } finally { let _ = cancellation.cancel(); let _ = owner.cancel(); cancellation.close(); database.close(); product.close(); remove(root, recursive: true) }
        }
    }


    @TestCase
    func optionalNoReadDefaultOwnerKeepsOrdinaryPolicyPromptBeforeCanonicalParent(): Unit {
        let root = pluginContractTemp("direct-optional-none-default-prompt")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        let probe = CanonicalRootSnapshotProbe("optional-none-default-v1")
        let reads = AtomicInt64(0)
        let name = "fixture_optional_none_default_prompt"
        let thread = "optional-none-default-prompt"
        let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
        try {
            let descriptor = ToolDescriptor(ModelToolDefinition(name, "Actual optional pure preparation",
                objectValue([ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
                Capability(CapabilityKind.WorkspaceRead), sideEffecting: true,
                implementationVersion: "optional-none-default-v1", preparationReadResolver: Some({ _, _ =>
                    let _ = reads.fetchAdd(1); Result<?ToolPreparationRead>.Ok(None) }))
            product.registerTool(descriptor, probe).value().getOrThrow()
            let result = product.vnext.executeCanonicalTool(SessionId(thread),
                CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("optional-none-default-call", name, objectValue([])), budget: budget)
            @Expect(match (result) {
                case Result.Ok(ToolInvocationResult.NeedsApproval(approval)) =>
                    approval.toolName == name && approval.callId == "optional-none-default-call"
                case _ => false
            })
            @Expect(reads.load(), 1)
            @Expect(probe.calls, 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(budget.snapshot().toolCalls, 0)
            @Expect(budget.snapshot().activeTools, 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }
}
