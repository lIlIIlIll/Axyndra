package product_contract

import agent_domain.*
import agent_product.*
import agent_store.*
import tool_runtime.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

// Real installed Skills provider, actual canonical ContextRead approval and
// model projection. Configuration changes must still revoke the pending read.
func runInitialContextInputContract159(root: String): Unit {
    for (change in [false, true]) {
        let base = root + if (change) { "/initial-change" } else { "/initial-approve" }
        Directory.create(base + "/workspace", recursive: true)
        let product = contractValue(openProduct(config: ProductConfig(workspaceRoot: base + "/workspace",
            settingsRoot: base + "/settings", stateRoot: base + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.AlwaysAsk)), "initial input Product")
        let database = SqliteDatabase(product.stateRoot + "/state.db")
        try {
            // A real ordinary Native tool binds the actual paid Catalog. A
            // provider-only fixture would take the historical unowned model
            // observation path and would not exercise this lifetime boundary.
            let workspaceRecord = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKSPACE_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
                case PluginRegistryResult.Err(error) => throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))
            }
            let workspaceNamespace = supportRegistryDescriptor96(workspaceRecord, "namespace")
            expect(workspaceNamespace == "axyndra:workspace", "actual ordinary Native Catalog required")
            match (product.setPluginEnabled(workspaceNamespace, true)) {
                case PluginRegistryResult.Ok(record) => record.close()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))
            }
            workspaceRecord.close()
            let installed = match (product.importLocalPlugin(getVariable("AXYNDRA_SKILLS_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
                case PluginRegistryResult.Err(error) => throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))
            }
            let namespace = supportRegistryDescriptor96(installed, "namespace")
            let digest = supportRegistryDescriptor96(installed, "content_digest")
            expect(namespace == "axyndra:skills", "actual installed Skills provider required")
            match (product.setPluginEnabled(namespace, true)) {
                case PluginRegistryResult.Ok(record) => record.close()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))
            }
            installed.close()
            let source = product.settingsRoot + "/skills/review/SKILL.md"
            Directory.create(product.settingsRoot + "/skills/review", recursive: true)
            File.writeTo(source, "---\nname: review\ndescription: Review the selected change\n---\nInitial input keeps exact 雪 instructions.\n".toArray())
            let plugins = product.settingsRoot + "/plugins"
            File.writeTo(plugins + "/read-scopes.json", stringifyUnifiedJson(objectValue([
                ValueField("version", integerValue(1)), ValueField("roots", listValue([textValue("$" + "{settings_root}/skills")]))])).toArray())
            let config = stringifyUnifiedJson(objectValue([
                ValueField("version", integerValue(2)), ValueField("namespace", textValue(namespace)),
                ValueField("package_digest", textValue(digest)), ValueField("provider", textValue("skills")),
                ValueField("resources", listValue([objectValue([ValueField("source", textValue(product.settingsRoot + "/skills")),
                    ValueField("path", textValue("selected")), ValueField("mode", textValue("optional_header_directory")),
                    ValueField("max_bytes", integerValue(4096)), ValueField("max_file_bytes", integerValue(65536)),
                    ValueField("start_marker", textValue("---")), ValueField("end_marker", textValue("---")),
                    ValueField("trim_ascii", boolValue(true)), ValueField("basename", textValue("SKILL.md")),
                    ValueField("depth", integerValue(1)), ValueField("max_files", integerValue(128))])])),
                ValueField("query", objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")),
                    ValueField("action", textValue("prepare")), ValueField("resource_roots", listValue([textValue("selected")])),
                    ValueField("include_catalog", boolValue(true))])), ValueField("prompt_field", textValue("prompt"))]))
            File.writeTo(plugins + "/context.json", config.toArray())
            let app = product.applicationSession(sessionId: Some(SessionId("initial-input-contract")))
            let pending = contractValue(app.submit("$review"), "prepare actual initial read")
            let approval = pending.approval.getOrThrow()
            expect(approval.toolName == HOST_CONTEXT_READ_TOOL &&
                database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 0,
                "initial preparation cannot invoke a model or complete the read before canonical approval")
            if (change) { File.writeTo(plugins + "/context.json", (config + "\n").toArray()) }
            var outcome = app.decide(approval.operationId.value, ApprovalDecision.Approve)
            if (change) {
                expect(outcome.isError() && outcome.error().getOrThrow().code == "context.initial_configuration_changed" &&
                    database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 0,
                    "narrow input cannot bypass changed configuration or create an effect on failed revalidation")
            } else {
                let selected = contractValue(outcome, "approve initial metadata read")
                let bodyApproval = selected.approval.getOrThrow()
                expect(bodyApproval.operationId.value != approval.operationId.value &&
                    database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 1,
                    "selected body requires its own canonical approval after the real metadata Receipt")
                outcome = app.decide(bodyApproval.operationId.value, ApprovalDecision.Approve)
                let completed = contractValue(outcome, "approve actual initial body")
                let hasBody = product.fixtureProbe.getOrThrow().withLastRequest159({ view =>
                    view.systemContains159("Initial input keeps exact 雪 instructions.") })
                let hasCatalog = product.fixtureProbe.getOrThrow().withLastRequest159({ view =>
                    view.systemContains159("Available Skills") })
                expect(completed.snapshot.getOrThrow().status == RunState.Completed && hasBody && hasCatalog,
                    "actual approved read enters the first model request with exact immutable context; completed=" +
                        (completed.snapshot.getOrThrow().status == RunState.Completed).toString() +
                        "; body=" + hasBody.toString() + "; catalog=" + hasCatalog.toString() +
                        "; observed_request=" + product.fixtureProbe.getOrThrow().withLastRequest159({ _ => true }).toString() +
                        "; attempts=" + database.scalarInt("SELECT COUNT(*) FROM model_attempts").toString() +
                        "; durable_body=" + database.scalarInt("SELECT COUNT(*) FROM runs WHERE skill_snapshot LIKE '%Initial input keeps exact%'").toString())
                expect(database.scalarInt("SELECT COUNT(*) FROM runs") == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 2 &&
                    database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 1,
                    "initial input preserves one actual Run, two exact read Receipts, safe cut and model attempt")
            }
        } finally {
            database.close()
            contractValue(product.close(), "initial input Product cleanup")
        }
    }
}
