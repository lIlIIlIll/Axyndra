package agent_product

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func workflowViewTestOpen(session: ApplicationSession, namespace: String, source: String): AgentValue {
    let observed = lifecycleTestRequire(session.withJavaScriptPluginViewDocument<String>(
        "plugin." + namespace + ".plan_review", "{}", "views-v1", { metadata, model, primary =>
            @Expect(primary, source)
            @Expect(httpIntentText(metadata.field("primary").getOrThrow(), "sha256"), modelPolicySha256Text(source))
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
    func threeMiBSourceStaysHostOwnedAndSaveRequiresTheActualFrozenConfirmation(): Unit {
        let f = WorkflowRolesFixture(); let _ = workflowPlanTestSelect(f)
        let session = f.product.applicationSession(sessionId: Some(SessionId("view-source-user")))
        let namespace = productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))
        let prefix = "# Goal\n\n"; let suffix = "\nAcceptance: exact full source 雪"
        let source = prefix + String.fromUtf8(Array<Byte>(3145728 - prefix.size - suffix.size, repeat: b'x')) + suffix
        let edited = source.replace("# Goal", "# Work")
        try {
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
        let f = WorkflowRolesFixture(); let _ = workflowPlanTestSelect(f)
        let session = f.product.applicationSession(sessionId: Some(SessionId("view-event-binding")))
        let namespace = productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))
        let source = "# Goal\n\nExact current plan"
        try {
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
