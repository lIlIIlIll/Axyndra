package agent_product

import agent_domain.*
import agent_extension_runtime.reserveNativeDocumentPayload
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.convert.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func continuationObservationTool(f: WorkflowCommandFixture, call: String, operation: String): Unit {
    continuationObservationInput(f, call, objectValue([ValueField("op", textValue(operation))]))
}
func continuationObservationInput(f: WorkflowCommandFixture, call: String, input: AgentValue): Unit {
    let result = f.product.vnext.executeCanonicalTool(f.session.id(),
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
        ToolCall(call, "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal", input))
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => try { @Expect(!value.isError) } finally { value.releasePayload() }
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("canonical Goal mutation did not complete")
    }
}

func continuationObservationProgress(f: WorkflowCommandFixture, call: String): Unit {
    // A separate Application has no continuation owner. Its real model Run
    // changes canonical usage, so the next Goal get must persist progress even
    // if the clock has not advanced a millisecond.
    let ordinary = f.product.applicationSession(sessionId: Some(f.session.id()))
    @Expect(ordinary.submit("Record one ordinary model reply.").isOk())
    continuationObservationTool(f, call, "get")
}

func continuationObservationChain(f: WorkflowCommandFixture): Result<Array<AgentValue>> {
    let config = loadProductPluginDocumentConfiguration(f.root + "/settings", productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),
        productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest))).value().getOrThrow()
    let current = f.document("goal")
    let packageGeneration = f.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))
    let scope = ContinuationDocumentReadScope({ bytes => reserveNativeDocumentPayload(bytes) })
    try { f.database.readTransaction<Result<Array<AgentValue>>>({ tx =>
        let pin = tx.query("SELECT operation_id,payload FROM audit_events WHERE thread_id=? AND kind='host_continuation_control_document_v1' ORDER BY id DESC LIMIT 1",
            [SqlParameter.Text(f.session.id().value)])[0]
        let data = decodeStoredValue(pin.required(1))
        let chain = observeContinuationDocumentChain(tx, current, pin.required(0), Int64.parse(data.field("revision").getOrThrow().asNumberText()),
            httpIntentText(data, "sha256"), "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal", productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)),
            packageGeneration.toString(), config.digest, scope: scope)
        match (chain) { case Result.Err(error) => Result.Err(error)
            case Result.Ok(values) => Result.Ok(Array<AgentValue>(values.size, { index => values[index].descriptor() })) }
    }) } finally { scope.close() }
}

// Read the actual canonical v1 model input, not an obsolete duplicate prompt.
// The complete request remains bound to the consumed claim's original digest.
func expectConsumedContinuationObjective(claim: AgentValue, origin: ContinuationRunOrigin,
    objective: String): Unit {
    let request = claim.field("request").getOrThrow()
    @Expect(httpIntentText(request, "schema"), "axyndra.host-continuation-request/v1")
    @Expect(httpIntentText(request, "run_id"), origin.runId)
    @Expect(httpIntentText(request, "thread_id"), origin.threadId)
    @Expect(modelPolicySha256Text(canonicalAgentValue(request)), origin.requestDigest)
    let input = modelRequestFromSnapshotValue(request.field("model_input").getOrThrow(), "").value().getOrThrow()
    @Expect(input.messages.size, 1)
    @Expect(input.messages[0].role == ModelRole.User)
    @Expect(input.messages[0].blocks.size >= 1)
    @Expect(input.messages[0].blocks[0].kind == ModelBlockKind.Text)
    @Expect(input.messages[0].blocks[0].text.contains(objective))
}

@Test
class PluginContinuationObservationTests {
    @TestCase
    func expiredPreparationWindowCannotStartAPureWorkerOrAnActualRun(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        let cancellation = CancellationSource()
        try {
            var expired = false
            try { let _ = ProductContinuationPreparationDeadline(ResourceBudget(deadlineMillis: nowMillis() - 1)) }
            catch (_: Exception) { expired = true }
            @Expect(expired)
            let deadline = MonoTime.now() - Duration.second
            let outcome = queryProductPluginPolicy(f.product.vnext.javascriptPlugins, productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), "propose",
                productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)), objectValue([]), ThreadId(f.session.id().value), cancellation.token,
                "expired-continuation-observation", deadline: Some(deadline))
            @Expect(outcome.isError()); @Expect(outcome.error().getOrThrow().code, "policy.deadline_exceeded")
            @Expect(policyQueryRemaining(Some(deadline)) <= 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
        } finally { cancellation.close(); f.close() }
    }

    @TestCase
    func canonicalDirectAndCommittedProgressKeepTheActualUserBudgetAndTypedRunSource(): Unit {
        for (mode in ["direct", "committed"]) {
            let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
            try {
                @Expect(f.command("goal", "set Keep this exact user objective").isOk())
                @Expect(f.command("goal", "budget 128").isOk())
                let before = f.facts().getOrThrow()
                let approved = f.document("goal")
                if (mode == "direct") { continuationObservationProgress(f, "direct-progress") }
                else { f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("model-progress", "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal",
                    objectValue([ValueField("op", textValue("get"))])) }
                @Expect(f.session.submit("Return a short acknowledgement.").isOk())
                @Expect(f.document("goal").revision > approved.revision)
                let rows = f.database.query("SELECT run_id,payload FROM audit_events WHERE kind='host_continuation_claim_consumed_v1' ORDER BY id")
                @Expect(rows.size >= 2); @Expect(rows.size < 128)
                for (row in rows) {
                    let claim = decodeStoredValue(row.required(1))
                    let origin = continuationRunOriginFromValue(claim.field("origin").getOrThrow())
                    @Expect(origin.runId, row.required(0)); @Expect(origin.controlSourceDigest, before.controlSourceDigest)
                    @Expect(origin.documentObservation.isSome())
                    let observation = origin.documentObservation.getOrThrow().value()
                    @Expect(httpIntentText(observation, "original_document_sha256"), modelPolicySha256Text(approved.encoded))
                    @Expect(observation.field("chain").getOrThrow().items.size >= 1)
                    if (row.required(0) == rows[0].required(0)) { @Expect(observation.field("chain").getOrThrow().items.size >= 2) }
                    else {
                        @Expect(httpIntentText(observation, "anchor_run_id") != "")
                        @Expect(observation.field("chain").getOrThrow().items.size, 1)
                    }
                    expectConsumedContinuationObjective(claim, origin, "Keep this exact user objective")
                }
                @Expect(f.facts().getOrThrow().eventId, before.eventId)
                @Expect(f.facts().getOrThrow().tokenBudget, before.tokenBudget)
                @Expect(!f.facts().getOrThrow().hasRemainingTokens())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','recovery_required')"), 0)
                if (mode == "committed") {
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM decision_operations source JOIN operation_effect_records e ON e.operation_id=source.operation_id WHERE e.tool_id LIKE 'plugin.%'"), 1)
                }
            } finally { f.close() }
        }
    }

    @TestCase
    func intermediateCanonicalPauseCannotBeHiddenByAResumeBeforeTheNextObservation(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "set Preserve every intermediate stop").isOk())
            @Expect(f.command("goal", "budget 128").isOk())
            let before = f.facts().getOrThrow()
            continuationObservationInput(f, "canonical-model-pause", objectValue([ValueField("method", textValue("pause"))]))
            @Expect(httpIntentText(f.document("goal").decode().value().getOrThrow(), "status"), "paused")
            continuationObservationTool(f, "canonical-model-resume", "resume")
            @Expect(httpIntentText(f.document("goal").decode().value().getOrThrow(), "status"), "active")
            @Expect(continuationObservationChain(f).value().getOrThrow().size, 3)
            @Expect(f.session.submit("Current active data cannot erase the earlier pause.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
            @Expect(f.session.submit("The original owner stays stopped.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
            @Expect(f.facts().getOrThrow().eventId, before.eventId)
        } finally { f.close() }
    }

    @TestCase
    func observedStopCannotBeUndoneByLaterModelDataOrAnotherApplicationOwner(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "set A terminal objective").isOk())
            @Expect(f.command("goal", "budget 64").isOk())
            let before = f.facts().getOrThrow()
            continuationObservationTool(f, "complete-goal", "complete")
            @Expect(f.session.submit("Acknowledge the completed document.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
            // A later canonical model/user Tool can change document data; it
            // does not recreate the revoked Application control owner.
            continuationObservationTool(f, "drop-completed", "drop")
            let other = f.product.applicationSession(sessionId: Some(f.session.id()))
            @Expect(other.submit("Return another acknowledgement.").isOk())
            @Expect(f.session.submit("The original owner remains stopped.").isOk())
            @Expect(f.facts().getOrThrow().eventId, before.eventId)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func repositoryCasAndTombstoneCannotSubstituteForCanonicalMutationReceipts(): Unit {
        for (tombstone in [false, true]) {
            let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
            try {
                @Expect(f.command("goal", "set No repository minting").isOk())
                @Expect(f.command("goal", "budget 64").isOk())
                let before = f.facts().getOrThrow()
                let snapshot = f.document("goal")
                let next = if (tombstone) { nullValue() } else { snapshot.decode().value().getOrThrow() }
                @Expect(SqlitePluginDocumentRepository(f.database).compareExchange(snapshot, next, { _ => Result<Unit>.Ok(()) }).isOk())
                @Expect(continuationObservationChain(f).isError())
                @Expect(f.session.submit("Acknowledge without admitting a continuation.").isOk())
                @Expect(f.facts().getOrThrow().eventId, before.eventId)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func revokedOperatorReadRightsStopTheOwnerEvenAfterBytesAreRestored(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "set A revocable continuation").isOk())
            @Expect(f.command("goal", "budget 64").isOk())
            let file = f.root + "/settings/plugins/documents.json"
            let prior = File.readFrom(file)
            File.writeTo(file, "{\"version\":1,\"plugins\":[]}".toArray())
            let _ = f.session.submit("Observe the revoked read right.")
            File.writeTo(file, prior)
            @Expect(f.session.submit("Restoration is not a new user control.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualCompletedChainRejectsReceiptPlanScopeAndHandoffTampering(): Unit {
        for (fault in ["receipt", "plan", "scope", "handoff"]) {
            let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
            try {
                @Expect(f.command("goal", "set Exact historical mutation proof").isOk())
                continuationObservationProgress(f, "progress-before-tamper")
                let chain = continuationObservationChain(f).value().getOrThrow()
                @Expect(chain.size >= 2)
                let last = chain[chain.size - 1]
                if (fault == "receipt") { f.database.execute("UPDATE operation_receipts SET detail='damaged' WHERE id=?", [SqlParameter.Text(httpIntentText(last, "receipt_id"))]) }
                else if (fault == "plan") { f.database.execute("UPDATE operation_effect_records SET normalized_plan='damaged' WHERE operation_id=?", [SqlParameter.Text(httpIntentText(last, "operation_id"))]) }
                else if (fault == "scope") { f.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id=?", [SqlParameter.Text(httpIntentText(last, "run_id"))]) }
                else { f.database.execute("DELETE FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'", [SqlParameter.Text(httpIntentText(last, "operation_id"))]) }
                @Expect(continuationObservationChain(f).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='executing'"), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func failedActualNextRunTransactionLeavesNoClaimOrContinuationItem(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "set Atomic continuation admission").isOk())
            @Expect(f.command("goal", "budget 64").isOk())
            let control = f.facts().getOrThrow()
            continuationObservationProgress(f, "actual-progress-before-admission")
            f.database.execute("CREATE TRIGGER reject_actual_continuation BEFORE INSERT ON audit_events " +
                "WHEN NEW.kind='host_continuation_claim_consumed_v1' BEGIN SELECT RAISE(ABORT,'fixture continuation admission'); END")
            @Expect(f.session.submit("The completed ordinary Run stays intact.").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('accepted','running','recovery_required')"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE active_turn_id IS NOT NULL"), 0)
            @Expect(f.facts().getOrThrow().eventId, control.eventId)
        } finally { f.close() }
    }
}
