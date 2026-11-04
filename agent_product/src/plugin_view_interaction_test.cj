package agent_product

import agent_domain.*
import agent_extension_runtime.nativeControlMetadataUsage113
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func workflowViewTestOpen(session: ApplicationSession, namespace: String, source: String): AgentValue {
    let observed = lifecycleTestRequire(session.withJavaScriptPluginViewDocument<String>(
        "plugin." + namespace + ".plan_review", "{}", "views-v1", { metadata, model, primary =>
            if (source.contains(PLAN_CONTRACT_OPEN)) {
                @Expect(primary, source)
            } else {
                @Assert(primary.startsWith(source + "\n\n<plan-review-checks>\n[]\n</plan-review-checks>" + PLAN_CONTRACT_OPEN))
                @Assert(primary.endsWith(PLAN_CONTRACT_CLOSE))
            }
            let contract = lifecycleTestRequire(planReviewContract(primary))
            @Assert(contract.targetRoots.size == 1)
            @Assert(contract.steps.size == 1)
            @Expect(contract.steps[0].id.value, "view-verify")
            @Assert(contract.steps[0].actions.size == 1)
            let action = contract.steps[0].actions[0]
            @Expect(action.id, "view-readonly")
            @Assert(action.toolNames.size == 1)
            @Expect(action.toolNames[0], "command_probe")
            @Expect(action.effectCeiling, OperationEffectClass.ReadOnly)
            @Expect(action.maxAttempts, 1)
            @Expect(action.exactArguments)
            @Expect(action.argumentConstraints.field("executable").getOrThrow().text, "/bin/true")
            @Expect(action.argumentConstraints.field("cwd").getOrThrow().text, contract.targetRoots[0])
            @Expect(action.argumentConstraints.field("readonly_workspace").getOrThrow().asBool())
            @Expect(action.toolIdentities.field("command_probe").isSome())
            @Expect(httpIntentText(metadata.field("primary").getOrThrow(), "sha256"), modelPolicySha256Text(primary))
            @Expect(httpIntentText(model, "interaction"), "required")
            var sourceInput = false
            var saveCommand = false
            for (node in model.field("nodes").getOrThrow().items where httpIntentText(node, "id") == "plan") {
                sourceInput = httpIntentText(node, "source") == "primary" && node.field("text").isNone() }
            for (action in model.field("actions").getOrThrow().items where httpIntentText(action, "id") == "save") {
                saveCommand = httpIntentText(action, "command") == "plan_review" }
            @Expect(sourceInput); @Expect(saveCommand)
            Result.Ok(encodeAgentValue(metadata))
        }))
    lifecycleTestRequire(decodeAgentValue(observed, maxBytes: 4096))
}

@Test
class InstalledPluginViewInteractionTests {
    @TestCase
    func canonicalReviewHashMatchesAllReviewedBytesAndRejectsChangedPins205(): Unit {
        let f = WorkflowRolesFixture()
        try {
            let session = SessionId("review-hash-bytes")
            let contract = workflowPlanTestContract205(f.product)
            let encoded = planContractValue(contract).toJson()
            let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let bodies = ["", " \t\r\n\u{b}\u{c}", " \t# Goal 雪\t \n", "\u{a0}雪\n",
                "\u{0} \t雪", "Goal\n\n<plan-review-checks>\nOLD-CHECK-ONLY\n</plan-review-checks>",
                "(-Math.sign(layer) * 4) % 4; (sign * 4) % 4; rotVec(v,axis,quarterTurns); " +
                    "rotVec(startPos,axis,angle); animateMove; queue.clear();state.reset();state.applyMove(move)"]
            for (index in 0..bodies.size) {
                let document = bodies[index] + PLAN_CONTRACT_OPEN + encoded + PLAN_CONTRACT_CLOSE
                let reviewed = lifecycleTestRequire(f.product.reviewExecutionPlan(document, sessionId: Some(session)))
                let digest = lifecycleTestRequire(f.product.reviewedExecutionPlanHash204(document, session))
                @Expect(digest, modelPolicySha256Text(reviewed))
                @Expect(canonicalAgentValuesEqual(productPlanReviewAdvisoriesValue(bodies[index]),
                    productPlanReviewBoundedAdvisoriesValue204(bodies[index])))
                if (index < 2) { @Assert(reviewed.startsWith("<plan-review-checks>\n[]")) }
                if (index == 2) { @Assert(reviewed.startsWith("# Goal 雪\t \n\n\n<plan-review-checks>")) }
                @Expect(!reviewed.contains("OLD-CHECK-ONLY"))
            }
            let reviewed = lifecycleTestRequire(f.product.reviewExecutionPlan(
                "Goal" + PLAN_CONTRACT_OPEN + encoded + PLAN_CONTRACT_CLOSE, sessionId: Some(session)))
            let pinned = lifecycleTestRequire(planReviewContract(reviewed))
            let action = pinned.steps[0].actions[0]
            let pin = action.toolIdentities.field("command_probe").getOrThrow()
            let changed = PlanAction(action.id, action.toolNames, action.networkModes, action.effectCeiling,
                action.argumentConstraints, action.maxAttempts, exactArguments: action.exactArguments,
                toolIdentities: objectValue([ValueField("command_probe", objectValue([
                    ValueField("version", pin.field("version").getOrThrow()),
                    ValueField("fingerprint", textValue("changed-reviewed-implementation")),
                    ValueField("schema_digest", pin.field("schema_digest").getOrThrow())]))]))
            let changedContract = PlanContract(pinned.targetRoots,
                [PlanExecutionStep(pinned.steps[0].id, [], true, [changed])])
            let rejected = f.product.reviewedExecutionPlanHash204(planReviewDocument("Goal", planContractValue(changedContract)), session)
            @Expect(rejected.error().getOrThrow().code, "plan.tool_identity_changed")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
        } finally { f.close() }
    }

    @TestCase
    func repeatedThreeMiBReviewReturnsBuilderDataButKeepsEachPublishedCopyPaid205(): Unit {
        let f = WorkflowRolesFixture()
        try {
            let session = SessionId("review-copy-sum")
            let sourceOwner = f.product.workflowToolIdentities204(session, None<CapabilitySet>).getOrThrow()
            let anchor = try { sourceOwner.deriveRetainedAllocation204(4096) }
                finally { sourceOwner.closeAfterCaller204() }
            try {
                let prefix = "# Goal\n\n"; let suffix = "\nAcceptance: exact full source 雪"
                let source = prefix + String.fromUtf8(Array<Byte>(3145728 - prefix.size - suffix.size, repeat: b'x')) + suffix
                let document = planReviewDocument(source, planContractValue(workflowPlanTestContract205(f.product)))
                for (index in 0..2) {
                    let before = anchor.retainedCustodyUsage113()
                    let beforeNative = nativeControlMetadataUsage113()
                    let reviewed = lifecycleTestRequire(f.product.reviewExecutionPlan(document, sessionId: Some(session)))
                    let after = anchor.retainedCustodyUsage113()
                    let afterNative = nativeControlMetadataUsage113()
                    @Assert(reviewed.startsWith(source + "\n\n<plan-review-checks>\n[]\n</plan-review-checks>" + PLAN_CONTRACT_OPEN))
                    @Expect(lifecycleTestRequire(planReviewContract(reviewed)).steps[0].actions[0].id, "view-readonly")
                    // Same original Catalog ledger: only the actual independently
                    // published String and its lease remain after the whole helper.
                    // The shared physical high-water is deliberately not refunded.
                    @Expect(after[0] - before[0], reviewed.size + 8192 + 1024)
                    @Expect(after[2] - before[2], 1)
                    // The builder's actual independent physical message slot
                    // has returned in the original Native bank. Only output
                    // and bounded identity metadata can grow its long ledger.
                    @Expect(afterNative[0], beforeNative[0])
                    @Assert(afterNative[1] <= beforeNative[1] + reviewed.size + 2097152)
                }
            } finally { anchor.close() }
        } finally { f.close() }
    }

    @TestCase
    func threeMiBSourceStaysHostOwnedAndSaveRequiresTheActualFrozenConfirmation(): Unit {
        let f = WorkflowRolesFixture(); let name = workflowPlanTestSelect(f)
        let session = f.product.applicationSession(sessionId: Some(SessionId("view-source-user")))
        let namespace = productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))
        let prefix = "# Goal\n\n"; let suffix = "\nAcceptance: exact full source 雪"
        let source = prefix + String.fromUtf8(Array<Byte>(3145728 - prefix.size - suffix.size, repeat: b'x')) + suffix
        let edited = source.replace("# Goal", "# Work")
        try {
            workflowPlanTestEnqueue205(f, name)
            let _ = lifecycleTestRequire(session.handle("/plan fixture plan write"))
            let _ = lifecycleTestRequire(session.updateLatestPlan("", source))
            let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let attempts = f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let messages = f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'")
            let metadata = workflowViewTestOpen(session, namespace, source)
            let id = httpIntentText(metadata, "view_id")
            let staged = lifecycleTestRequire(session.invokeJavaScriptPluginViewAction(id, "1", "save",
                objectValue([ValueField("plan", textValue(edited)), ValueField("feedback", textValue("actual human edit"))]), { _, _ => () }))
            let confirmation = match (staged.action) {
                case ApplicationAction.ConfirmPluginView(value) => lifecycleTestRequire(decodeAgentValue(value, maxBytes: 4096))
                case _ => throw IllegalStateException("actual View action did not request Host business confirmation") }
            @Expect(httpIntentText(confirmation, "action"), "save")
            @Expect(session.workMode(), "plan")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), attempts)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), messages)
            @Expect(session.approval().isNone())
            let forged = session.confirmJavaScriptPluginView(id, "2", "forged-request", true)
            @Expect(forged.error().getOrThrow().code, "view.confirmation_mismatch")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), messages)
            let saved = lifecycleTestRequire(session.confirmJavaScriptPluginView(id, "2",
                httpIntentText(confirmation, "request_digest"), true))
            @Expect(match (saved.action) { case ApplicationAction.OpenPluginView(route) => route == "plugin." + namespace + ".plan_review"; case _ => false })
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), attempts)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), messages + 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
            @Expect(session.workMode(), "plan")
            let _ = workflowViewTestOpen(session, namespace, edited)
            @Expect(session.invokeJavaScriptPluginViewAction(id, "1", "save", objectValue([]), { _, _ => () }).isError())
        } finally { let _ = session.cancel(); f.close() }
    }

    @TestCase
    func replacedDisabledAndMalformedEventsNeverReachBusinessControl(): Unit {
        let f = WorkflowRolesFixture(); let name = workflowPlanTestSelect(f)
        let session = f.product.applicationSession(sessionId: Some(SessionId("view-event-binding")))
        let namespace = productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))
        let source = "# Goal\n\nExact current plan"
        try {
            workflowPlanTestEnqueue205(f, name)
            let _ = lifecycleTestRequire(session.handle("/plan fixture plan write"))
            let _ = lifecycleTestRequire(session.updateLatestPlan("", source))
            let first = workflowViewTestOpen(session, namespace, source)
            let second = workflowViewTestOpen(session, namespace, source)
            let firstId = httpIntentText(first, "view_id"); let id = httpIntentText(second, "view_id")
            @Expect(firstId != id)
            let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let messages = f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'")
            let fields = objectValue([ValueField("plan", textValue(source)), ValueField("feedback", textValue(""))])
            @Expect(session.invokeJavaScriptPluginViewAction(firstId, "1", "approve_keep", fields, { _, _ => () }).isError())
            @Expect(session.invokeJavaScriptPluginViewAction(id, "2", "approve_keep", fields, { _, _ => () }).isError())
            @Expect(session.invokeJavaScriptPluginViewAction(id, "1", "undeclared-action", fields, { _, _ => () }).isError())
            @Expect(session.invokeJavaScriptPluginViewAction(id, "1", "save",
                objectValue([ValueField("plan", textValue(source)), ValueField("forged-field", textValue("permission"))]), { _, _ => () }).isError())
            let staged = lifecycleTestRequire(session.invokeJavaScriptPluginViewAction(id, "1", "save", fields, { _, _ => () }))
            let confirmation = match (staged.action) {
                case ApplicationAction.ConfirmPluginView(value) => lifecycleTestRequire(decodeAgentValue(value, maxBytes: 4096))
                case _ => throw IllegalStateException("actual View action did not stage its confirmation") }
            // A different frontend can disable the shared mounted generation.
            // The actual generation callback, not this Application's wrapper,
            // must revoke its idle presentation and pending user fields.
            let disabled = f.product.setPluginEnabled(namespace, false)
            @Expect(disabled.isOk())
            @Expect(session.invokeJavaScriptPluginViewAction(id, "1", "approve_keep", fields, { _, _ => () }).isError())
            let revoked = session.confirmJavaScriptPluginView(id, "2", httpIntentText(confirmation, "request_digest"), true)
            @Expect(revoked.error().getOrThrow().code, "view.stale_event")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), messages)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
            @Expect(session.workMode(), "plan")
        } finally { let _ = session.cancel(); f.close() }
    }
}
