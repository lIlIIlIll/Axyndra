package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import process4cj as view_process
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func readViewTestRoot(label: String): String {
    let root = pluginContractTemp("read-view-" + label)
    Directory.create(root + "/workspace", recursive: true)
    File.writeTo(root + "/workspace/public.txt", "approved public\n".toArray())
    File.writeTo(root + "/workspace/.env", "SENSITIVE-ONLY-AFTER-APPROVAL\n".toArray())
    File.writeTo(root + "/outside.txt", "OUTSIDE-ONLY-AFTER-APPROVAL\n".toArray())
    root
}
func readViewChildren(database: SqliteDatabase, thread: String): Int64 {
    database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id " +
        "JOIN runs r ON r.id=o.run_id WHERE r.thread_id=" + sqliteText(thread))
}
func readViewPending(product: ProductRuntime, record: ProductPluginRecord, thread: String, path: String): ApplicationSession {
    let session = product.applicationSession(sessionId: Some(SessionId(thread)))
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".read",
        objectValue([ValueField("path", textValue(path))]))
    let step = session.submit("Read only the exact requested resource.").value().getOrThrow()
    if (step.approval.isNone() || session.approval().isNone()) { throw IllegalStateException("expected actual pending resource approval") }
    session
}
func readViewTestFailure(result: Result<ToolInvocationResult>): Bool {
    match (result) {
        case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
        case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError
        case _ => false
    }
}
func readViewFixtureInstall(product: ProductRuntime, root: String): ProductPluginRecord {
    let source = root + "/fixture"
    Directory.create(source)
    File.writeTo(source + "/plugin.py", File.readFrom(getVariable("AXYNDRA_READ_VIEW_PLUGIN_FIXTURE").getOrThrow()))
    let mode = view_process.runProcess(view_process.ProcessCommand("/usr/bin/chmod", arguments: ["700", source + "/plugin.py"], maxOutputBytes: 4096))
    if (mode.status.code != 0) { throw IllegalStateException("read-view fixture executable mode was not set") }
    File.writeTo(source + "/axyndra.plugin.json", stringifyUnifiedJson(objectValue([
        ValueField("id", textValue("read-view-fixture")), ValueField("version", textValue("1.0.0")),
        ValueField("entry_kind", textValue("native-executable")), ValueField("entrypoint", textValue("plugin.py")),
        ValueField("sdk_range", textValue("[2.0.0,3.0.0)")), ValueField("protocol_range", textValue("axyndra-js-host-v2")),
        ValueField("capabilities", listValue([textValue("process.readview")])), ValueField("contributions", listValue([
            objectValue([ValueField("kind", textValue("tool")), ValueField("name", textValue("read"))])]))])).toArray())
    let record = match (product.importLocalPlugin(source, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(value) => value; case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    workspaceReadViewConfigure(root, record, ["read"])
    match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    record
}

@Test
class PluginReadViewTests {
    @TestCase
    func exactOrdinaryGrantSupportsActualDirectAndCommittedAlwaysAskReads(): Unit {
        let root = readViewTestRoot("actual-grant")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            let direct = workspacePluginCall(product, record, "view-direct", "read", objectValue([ValueField("path", textValue("public.txt:raw"))]),
                ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(!direct.isError); @Expect(direct.output.field("content").getOrThrow().text, "approved public\n")
            let session = product.applicationSession(sessionId: Some(SessionId("view-committed")))
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("view-committed", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".grep",
                objectValue([ValueField("pattern", textValue("approved"))]))
            @Expect(session.submit("Search the authorized resource view.").isOk()); @Expect(session.approval().isNone())
            @Expect(readViewChildren(database, "view-direct"), 1); @Expect(readViewChildren(database, "view-committed"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 2)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 4)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM decision_operations d JOIN operations o ON o.id=d.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='view-direct'"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM decision_operations d JOIN operations o ON o.id=d.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='view-committed'") > 0)
            let rows = database.query("SELECT e.operation_id,o.run_id,e.normalized_plan,o.normalized_plan FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id WHERE e.tool_id='host.process.readview'")
            @Expect(rows.size, 2)
            let operations = DurableOperationStore(database)
            for (row in rows) {
                @Expect(row.required(2), row.required(3))
                let plan = lifecycleTestRequire(operations.loadPlan(OperationId(row.required(0)), RunId(row.required(1))))
                @Expect(isReadViewServiceChildPlan(plan))
                @Expect(plan.networkPolicy.mode, NetworkPolicyMode.Denied)
                @Expect(plan.retryDisposition, OperationRetryDisposition.Never)
            }
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func sensitiveAndOutsideResourcesRequireActualApprovalBeforeAnyChild(): Unit {
        let root = readViewTestRoot("special-resources")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            let rejected = readViewPending(product, record, "view-secret-reject", ".env:raw")
            @Expect(rejected.approval().getOrThrow().metadata.capabilityLabel, "sensitive-path.read")
            @Expect(readViewChildren(database, "view-secret-reject"), 0)
            @Expect(rejected.decide(rejected.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk())
            @Expect(readViewChildren(database, "view-secret-reject"), 0)
            let outside = readViewPending(product, record, "view-outside", "../outside.txt:raw")
            @Expect(outside.approval().getOrThrow().metadata.capabilityLabel != "workspace.read")
            @Expect(readViewChildren(database, "view-outside"), 0)
            @Expect(outside.decide(outside.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isOk())
            @Expect(readViewChildren(database, "view-outside"), 1)
            let secret = readViewPending(product, record, "view-secret-approve", ".env:raw")
            @Expect(secret.decide(secret.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isOk())
            @Expect(readViewChildren(database, "view-secret-approve"), 1)
            let outputs = database.query("SELECT detail FROM operation_receipts r JOIN operations o ON o.id=r.operation_id JOIN runs run ON run.id=o.run_id WHERE run.thread_id='view-secret-approve'")
            var found = false
            for (row in outputs where row.required(0).contains("SENSITIVE-ONLY-AFTER-APPROVAL")) { found = true }
            @Expect(found)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func wrongContributionAndChangedGrantCannotReusePendingAuthority(): Unit {
        let root = readViewTestRoot("grant-revocation")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            workspaceReadViewConfigure(root, record, ["glob"])
            let pending = readViewPending(product, record, "view-wrong-name", "public.txt")
            @Expect(readViewChildren(database, "view-wrong-name"), 0)
            let original = pending.approval().getOrThrow().operationId.value
            workspaceReadViewConfigure(root, record, ["read"])
            let result = pending.decide(original, ApprovalDecision.Approve)
            @Expect(result.isError()); @Expect(readViewChildren(database, "view-wrong-name"), 0)
            let fresh = workspacePluginCall(product, record, "view-fresh-grant", "read", objectValue([ValueField("path", textValue("public.txt"))]),
                ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(!fresh.isError)
            let _ = product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false, PluginInstallScope.Workspace)
            @Expect(product.invokeLocalTool(SessionId("view-disabled"), "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".read",
                objectValue([ValueField("path", textValue("public.txt"))])).isError())
            @Expect(readViewChildren(database, "view-disabled"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func resourceReplacementAfterApprovalPreparationIsRejectedBeforeWorkerRead(): Unit {
        let root = readViewTestRoot("identity-change")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            workspaceReadViewConfigure(root, record, [])
            let pending = readViewPending(product, record, "view-replaced", "public.txt")
            remove(root + "/workspace/public.txt")
            SymbolicLink.create(root + "/workspace/public.txt", to: root + "/outside.txt")
            @Expect(pending.decide(pending.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isError())
            let rows = database.query("SELECT detail FROM operation_receipts")
            for (row in rows) { @Expect(!row.required(0).contains("OUTSIDE-ONLY-AFTER-APPROVAL")) }
            @Expect(String.fromUtf8(File.readFrom(root + "/outside.txt")), "OUTSIDE-ONLY-AFTER-APPROVAL\n")
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func snapshotCannotExposeSensitiveOutsideEnvironmentOrProcAliases(): Unit {
        let previous = getVariable("READ_VIEW_AMBIENT_SECRET")
        setVariable("READ_VIEW_AMBIENT_SECRET", "ambient-must-not-reach-read-view")
        let root = readViewTestRoot("os-isolation")
        SymbolicLink.create(root + "/workspace/escape.txt", to: root + "/outside.txt")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = readViewFixtureInstall(product, root)
            let output = workspacePluginCall(product, record, "view-probe", "read", objectValue([
                ValueField("secret", textValue(root + "/workspace/.env")), ValueField("outside", textValue(root + "/outside.txt"))]),
                ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(!output.isError); @Expect(output.output.field("visible").getOrThrow().text, "approved public\n")
            for (field in ["relative_secret", "absolute_secret", "outside", "proc_root_outside", "environment_secret", "symlink"]) {
                @Expect(output.output.field(field).getOrThrow().unifiedKind, ValueKind.Null)
            }
            @Expect(readViewChildren(database, "view-probe"), 1)
            let rows = database.query("SELECT e.operation_id,o.run_id,e.normalized_plan,o.normalized_plan FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id WHERE e.tool_id='host.process.readview'")
            @Expect(rows.size, 1)
            @Expect(rows[0].required(2), rows[0].required(3))
            let plan = lifecycleTestRequire(DurableOperationStore(database).loadPlan(OperationId(rows[0].required(0)), RunId(rows[0].required(1))))
            for (resource in plan.canonicalArguments.field("intent").getOrThrow().field("resources").getOrThrow().items) {
                @Expect(!httpIntentText(resource, "source").endsWith("/.env"))
                @Expect(!httpIntentText(resource, "source").endsWith("/escape.txt"))
            }
        } finally {
            database.close(); product.close(); remove(root, recursive: true)
            match (previous) { case Some(value) => setVariable("READ_VIEW_AMBIENT_SECRET", value); case None => removeVariable("READ_VIEW_AMBIENT_SECRET") }
        }
    }

    @TestCase
    func readGrantCannotEscapeToWholeWorkspaceProcessOrPlanProposal(): Unit {
        let root = readViewTestRoot("service-escape")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = readViewFixtureInstall(product, root)
            for (service in ["process.readonly", "file.plan.propose", "exec", "network.http"]) {
                let thread = "view-denied-" + service
                let output = workspacePluginCall(product, record, thread, "read", objectValue([
                    ValueField("service", textValue(service)), ValueField("secret", textValue(root + "/workspace/.env")),
                    ValueField("outside", textValue(root + "/outside.txt"))]), ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
                @Expect(output.isError); @Expect(output.output.field("code").getOrThrow().text, "read_view.service_denied")
                @Expect(readViewChildren(database, thread), 0)
            }
            @Expect(!exists(Path(root + "/workspace/forbidden.txt")))
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func exactReadCapabilitiesCannotBeUpgradedIntoProposalAuthority(): Unit {
        let root = readViewTestRoot("capability-ceiling")
        let product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
                Capability(CapabilityKind.WorkspaceRead, resource: root + "/workspace/public.txt")])
            let read = product.vnext.executeCanonicalTool(SessionId("view-exact-read"), caps,
                ToolCall("exact-read", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".read", objectValue([ValueField("path", textValue("public.txt:raw"))])),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(!readViewTestFailure(read))
            for (name in ["edit", "write"]) {
                let input = if (name == "edit") { objectValue([ValueField("input", textValue("[public.txt#0000]\nSWAP 1:\n+changed"))]) }
                    else { objectValue([ValueField("path", textValue("public.txt")), ValueField("content", textValue("changed"))]) }
                let denied = product.vnext.executeCanonicalTool(SessionId("view-exact-" + name), caps,
                    ToolCall("exact-" + name, "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "." + name, input))
                @Expect(readViewTestFailure(denied)); @Expect(readViewChildren(database, "view-exact-" + name), 0)
            }
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/public.txt")), "approved public\n")
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func serviceGrantAndWrongKindCannotAuthorizeAnOrdinaryTool(): Unit {
        let root = readViewTestRoot("kind-isolation")
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            workspaceReadViewConfigure(root, record, [])
            let path = root + "/settings/plugins/services.json"
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            document.field("plugins").getOrThrow().items[0].put("read_only_tools", listValue([textValue("read")]))
            File.writeTo(path, stringifyUnifiedJson(document).toArray())
            let pending = readViewPending(product, record, "view-service-not-tool", "public.txt")
            @Expect(readViewChildren(database, "view-service-not-tool"), 0)
            @Expect(pending.decide(pending.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk())
            workspaceReadViewConfigure(root, record, ["read"])
            let wrong = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            wrong.field("plugins").getOrThrow().items[0].field("tool_read_grants").getOrThrow().items[0].put("kind", textValue("service"))
            File.writeTo(path, stringifyUnifiedJson(wrong).toArray())
            let result = workspacePluginCall(product, record, "view-invalid-kind", "read", objectValue([ValueField("path", textValue("public.txt"))]),
                ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(result.isError); @Expect(result.output.field("code").getOrThrow().text, "plugin.http_configuration_invalid")
            @Expect(readViewChildren(database, "view-invalid-kind"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func writeModeKeepsItsExistingExtensionCapabilityPrompt(): Unit {
        let root = readViewTestRoot("write-policy")
        let product = workspacePluginOpen(root, ApprovalMode.Write)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            // This explicitly records a remaining parity gap: Write mode
            // prompts on ExtensionInvoke, even for a host-granted ReadOnly plan.
            let ordinary = readViewPending(product, record, "view-write-ordinary", "public.txt")
            @Expect(readViewChildren(database, "view-write-ordinary"), 0)
            @Expect(ordinary.decide(ordinary.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isOk())
            @Expect(readViewChildren(database, "view-write-ordinary"), 1)
            let special = readViewPending(product, record, "view-write-special", ".env")
            @Expect(special.approval().getOrThrow().metadata.capabilityLabel, "sensitive-path.read")
            @Expect(special.decide(special.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk())
            @Expect(readViewChildren(database, "view-write-special"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }
}
