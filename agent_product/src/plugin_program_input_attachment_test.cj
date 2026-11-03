package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import agent_extension_runtime.{reserveNativeDocumentPayload}
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginProgramInputAttachmentTests {
    @TestCase
    func absentOperatorOptionKeepsOriginalSingleRootAndPublishesNoInput(): Unit {
        let f = ProgramDelegationFixture()
        try {
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            let result = f.completed(f.direct("input-attachment-default", f.input(code: "return 7;"), budget))
            try {
                @Expect(!result.isError)
                @Expect(result.output.field("program_artifact").isNone())
                @Expect(result.output.field("program_sha256").isNone())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
                @Expect(budget.snapshot().toolCalls, 1)
                @Expect(f.children("input-attachment-default"), 0)
            } finally { result.releasePayload() }
        } finally { f.close() }
    }

    @TestCase
    func actualSingleRootRetainsCompleteUtf8FileAndOriginalReceiptWithoutExtraCall(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            let code = "return \"héllo🙂\\n\";"
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            let result = f.completed(f.direct("input-attachment-complete", f.input(code: code), budget))
            try {
                @Expect(!result.isError)
                let ref = httpIntentText(result.output, "program_artifact")
                let hash = httpIntentText(result.output, "program_sha256")
                @Expect(ref, "blob:sha256:" + modelPolicySha256Text(code))
                @Expect(hash, modelPolicySha256Text(code))
                let read = ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).value().getOrThrow()
                @Expect(read.content, code); @Expect(read.bytes, code.size); @Expect(!read.truncated)
                @Expect(result.receiptId != "")
                let rows = f.database.query("SELECT o.id,o.run_id,receipt.id,a.payload FROM operations o " +
                    "JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
                    "JOIN audit_events a ON a.operation_id=o.id AND a.kind='tool_input_attached' " +
                    "WHERE r.thread_id='input-attachment-complete' AND receipt.outcome='completed'")
                @Expect(rows.size, 1); @Expect(rows[0].required(2), result.receiptId)
                let evidence = f.database.transaction { tx => completedToolInputAttachmentEvidence(tx,
                    OperationId(rows[0].required(0)), RunId(rows[0].required(1))) }.getOrThrow()
                @Expect(toolInputAttachmentEvidenceValid(evidence))
                @Expect(httpIntentText(evidence, "reserved_receipt_id"), result.receiptId)
                @Expect(httpIntentText(evidence.field("artifact").getOrThrow(), "ref"), ref)
                @Expect(budget.snapshot().toolCalls, 1); @Expect(budget.snapshot().activeTools, 0)
                @Expect(f.children("input-attachment-complete"), 0)
            } finally { result.releasePayload() }
        } finally { f.close() }
    }

    @TestCase
    func terminalToolErrorStillOwnsActualInputUntilConsumerAcknowledges(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            let code = "return await fetch(\"https://forbidden.invalid\");"
            let result = f.completed(f.direct("input-attachment-error", f.input(code: code),
                ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)))
            try {
                @Expect(result.isError); @Expect(result.payloadLease.isSome())
                let ref = httpIntentText(result.output, "program_artifact")
                @Expect(ref, "blob:sha256:" + modelPolicySha256Text(code))
                @Expect(ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).value().getOrThrow().content, code)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 1)
                let row = f.database.query("SELECT o.id,o.run_id FROM operations o JOIN runs r ON r.id=o.run_id WHERE r.thread_id='input-attachment-error'")[0]
                @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, OperationId(row.required(0)), RunId(row.required(1))) }.isSome())
                // Close may stop processes, but cannot discharge an output
                // which this actual consumer has not acknowledged.
                @Expect(f.product.close().isError())
            } finally { result.releasePayload() }
        } finally { f.close() }
    }

    @TestCase
    func changedOperatorSelectorCannotCaptureAnotherFieldOrMintInputAuthority(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            let path = f.root + "/settings/plugins/services.json"
            let config = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            config.field("plugins").getOrThrow().items[1].field("tool_input_attachments").getOrThrow().items[0].put("field", textValue("other"))
            File.writeTo(path, stringifyUnifiedJson(config).toArray())
            let denied = f.direct("input-attachment-wrong-selector", f.input(code: "return 7;"), ExecutionBudget(maxToolCalls: 1))
            @Expect(match (denied) { case Result.Err(_) => true; case Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
            @Expect(f.children("input-attachment-wrong-selector"), 0)
        } finally { f.close() }
    }

    @TestCase
    func forgedHostPlanMissingTypedTextAndAbsentWorkspaceCapabilityCannotPersist(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            for (args in [objectValue([]), objectValue([ValueField("code", integerValue(7))]),
                objectValue([ValueField("code", textValue("return 7;")), ValueField("host_plan", objectValue([]))])]) {
                let denied = f.direct("input-attachment-malformed", args, ExecutionBudget(maxToolCalls: 1))
                @Expect(match (denied) { case Result.Err(_) => true; case Result.Ok(ToolInvocationResult.Denied(_)) => true
                    case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
            }
            let denied = f.product.vnext.executeCanonicalTool(SessionId("input-attachment-no-read"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]), ToolCall("input-no-read", f.name, f.input(code: "return 7;")),
                budget: ExecutionBudget(maxToolCalls: 1))
            @Expect(match (denied) { case Result.Err(_) => true; case Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
        } finally { f.close() }
    }

    @TestCase
    func rejectionCancellationAndPostApprovalConfigDriftNeverOpenAnInputFile(): Unit {
        for (mode in ["reject", "cancel", "revoke"]) {
            let f = ProgramDelegationFixture(mode: ApprovalMode.Write, inputAttachment: true)
            try {
                let thread = "input-attachment-approval-" + mode
                let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
                f.product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, f.name, f.input(code: "return 7;"))
                @Expect(session.submit("Review this exact input attachment.").isOk())
                let pending = session.approval().getOrThrow()
                @Expect(pending.toolName, f.name)
                if (mode == "cancel") { @Expect(session.cancel().isOk()) }
                else {
                    if (mode == "revoke") {
                        let path = f.root + "/settings/plugins/services.json"
                        let changed = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
                        changed.field("plugins").getOrThrow().items[1].put("tool_input_attachments", listValue([]))
                        File.writeTo(path, stringifyUnifiedJson(changed).toArray())
                    }
                    let decision = session.decide(pending.operationId.value,
                        if (mode == "reject") { ApprovalDecision.Reject } else { ApprovalDecision.Approve })
                    if (mode == "reject") { @Expect(decision.isOk()) }
                }
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
                @Expect(f.children(thread), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func explicitAttachmentNeverExpandsOriginalThirtyTwoByteProcessOutputBudget(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1,
                processLimits: ExecutionResourceLimits(maxOutputBytes: 32))
            let outcome = f.direct("input-attachment-small-budget", f.input(code: "return 7;"), budget)
            @Expect(match (outcome) {
                case Result.Err(_) => true
                case Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(result)) =>
                    let refused = result.isError; result.releasePayload(); refused
                case _ => false })
            @Expect(budget.snapshot().toolCalls <= 1); @Expect(budget.snapshot().activeTools, 0)
            @Expect(f.children("input-attachment-small-budget"), 0)
            // Error cleanup cannot leave the private 64MiB copy owner active.
            let pressure = reserveNativeDocumentPayload(8388608); pressure.close()
        } finally { f.close() }
    }

    @TestCase
    func HistoricalRootReceiptCallAndArtifactMutationsNeverProduceReadEvidence(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            let code = "return 7;"
            let result = f.completed(f.direct("input-attachment-history", f.input(code: code), ExecutionBudget(maxToolCalls: 1)))
            @Expect(!result.isError)
            let ref = httpIntentText(result.output, "program_artifact")
            let row = f.database.query("SELECT o.id,o.run_id,e.reserved_result_item_id,a.id,a.payload FROM operations o " +
                "JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
                "JOIN audit_events a ON a.operation_id=o.id AND a.kind='tool_input_attached' WHERE r.thread_id='input-attachment-history'")[0]
            result.releasePayload()
            let operation = OperationId(row.required(0)); let run = RunId(row.required(1))
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isSome())
            let originalCall = f.database.query("SELECT i.id,i.payload,i.provenance FROM items i JOIN operations o ON o.tool_call_item_id=i.id WHERE o.id=?",
                [SqlParameter.Text(operation.value)])[0]
            let changedCall = decodeStoredThreadContent(originalCall.required(1))
            let forgedCall = match (changedCall) {
                case ThreadItemContent.ToolCall(id, name, _) => ThreadItemContent.ToolCall(id, name, objectValue([ValueField("code", textValue("return 8;"))]))
                case _ => throw IllegalStateException("actual original ToolCall is required") }
            f.database.execute("UPDATE items SET payload=? WHERE id=?", [SqlParameter.Text(encodeStoredThreadContent(forgedCall)), SqlParameter.Text(originalCall.required(0))])
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isNone())
            f.database.execute("UPDATE items SET payload=? WHERE id=?", [SqlParameter.Text(originalCall.required(1)), SqlParameter.Text(originalCall.required(0))])
            f.database.execute("UPDATE items SET provenance='' WHERE id=?", [SqlParameter.Text(originalCall.required(0))])
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isNone())
            f.database.execute("UPDATE items SET provenance=? WHERE id=?", [SqlParameter.Text(originalCall.required(2)), SqlParameter.Text(originalCall.required(0))])
            let hash = modelPolicySha256Text(code)
            let path = f.root + "/state/blobs/" + hash + ".txt"
            let candidate = GcBlobCandidate(hash); candidate.paths.add(path)
            let collection = f.database.transaction { tx => deleteUnreferencedGcBlob(tx, candidate) }
            @Expect(collection.retained); @Expect(collection.errors.isEmpty()); @Expect(exists(Path(path)))
            File.writeTo(path, "different complete bytes".toArray())
            @Expect(ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).isError())
            File.writeTo(path, code.toArray())
            @Expect(ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).value().getOrThrow().content, code)
            File.writeTo(path, Array<Byte>(0, repeat: 0))
            @Expect(ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).isError())
            File.writeTo(path, code.toArray())
            f.database.execute("UPDATE artifacts SET relative_path=? WHERE hash=?", [SqlParameter.Text("blobs/wrong.txt"), SqlParameter.Text(hash)])
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isNone())
            f.database.execute("UPDATE artifacts SET relative_path=? WHERE hash=?", [SqlParameter.Text("blobs/" + hash + ".txt"), SqlParameter.Text(hash)])
            f.database.execute("UPDATE operation_receipts SET outcome='rejected' WHERE operation_id=?", [SqlParameter.Text(operation.value)])
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isNone())
            f.database.execute("UPDATE operation_receipts SET outcome='completed' WHERE operation_id=?", [SqlParameter.Text(operation.value)])
            let payload = f.database.query("SELECT payload FROM items WHERE id=?", [SqlParameter.Text(row.required(2))])[0].required(0)
            f.database.execute("UPDATE items SET payload='' WHERE id=?", [SqlParameter.Text(row.required(2))])
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isNone())
            f.database.execute("UPDATE items SET payload=? WHERE id=?", [SqlParameter.Text(payload), SqlParameter.Text(row.required(2))])
            let forged = decodeStoredValue(row.required(4)); forged.field("evidence").getOrThrow().put("call_id", textValue("other-call"))
            f.database.execute("UPDATE audit_events SET payload=? WHERE id=?", [SqlParameter.Text(encodeStoredValue(forged)), SqlParameter.Text(row.required(3))])
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isNone())
            f.database.execute("UPDATE audit_events SET payload=? WHERE id=?", [SqlParameter.Text(row.required(4)), SqlParameter.Text(row.required(3))])
            match (f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false, PluginInstallScope.Workspace)) {
                case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
            @Expect(f.database.transaction { tx => completedToolInputAttachmentEvidence(tx, operation, run) }.isSome())
            @Expect(ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).value().getOrThrow().content, code)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 1)
        } finally { f.close() }
    }
}
