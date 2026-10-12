package agent_product

import agent_plugin_registry

import agent_core.*
import agent_domain.*
import agent_ports.*
import tool_runtime.*
import agent_store.*
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class WorkflowRolesFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: ProductPluginRecord
    let session = SessionId("installed-workflow-data")
    init() {
        let root = pluginContractTemp("workflow-roles")
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            approvalMode: ApprovalMode.Yolo, asyncEnabled: false)))
        let record = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow())) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
        if (!exists(Path(root + "/settings/plugins"))) { Directory.create(root + "/settings/plugins", recursive: true) }
        File.writeTo(root + "/settings/plugins/primitives.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("tools", listValue([objectValue([ValueField("name", textValue("task")),
                    ValueField("profile", textValue("frozen-primitives-v1")),
                    ValueField("services", listValue([textValue("child.start"), textValue("child.wait")])),
                    ValueField("preparation_provider", textValue("prepare_child"))]),
                    objectValue([ValueField("name", textValue("yield")),
                    ValueField("profile", textValue("frozen-primitives-v1")),
                    ValueField("services", listValue([textValue("child.result.write")])),
                    ValueField("preparation_provider", textValue("prepare_child")),
                    ValueField("invocation_capability", textValue("workspace.read"))])]))])]))])).toArray())
        @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
        this.root = root; this.product = product; this.record = record
        this.database = SqliteDatabase(root + "/state/state.db")
        select(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))
    }
    func select(digest: String): Unit {
        if (!exists(Path(root + "/settings/plugins"))) { Directory.create(root + "/settings/plugins", recursive: true) }
        File.writeTo(root + "/settings/plugins/policies.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)), ValueField("bindings", objectValue([ValueField("workflow", objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))), ValueField("provider", textValue("propose")),
                ValueField("package_digest", textValue(digest))]))]))])).toArray())
    }
    func role(name: String, token: CancellationToken): ProductWorkflowRole {
        lifecycleTestRequire(queryProductWorkflowRole(product, name, session, token, "workflow-role-" + name))
    }
    func close(): Unit { let _ = product.close(); database.close(); remove(root, recursive: true) }
}

@Test
class InstalledWorkflowRoleTests {
    @TestCase
    func actualInstalledCatalogIsDataAndCreatesNoCanonicalOwner(): Unit {
        let f = WorkflowRolesFixture()
        try {
            let roles = lifecycleTestRequire(queryProductWorkflowAgents(f.product, f.session))
            @Expect(roles.size, 6)
            @Expect(roles[0].name, "designer"); @Expect(roles[5].name, "task")
            @Expect(roles[5].model, "@task"); @Expect(roles[4].model, "@smol")
            @Expect(roles[2].prompt.contains("Correctness and regression review"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
        } finally { f.close() }
    }

    @TestCase
    func roleCannotExpandParentCapabilitiesAndRetainsActualRequestSnapshots(): Unit {
        let f = WorkflowRolesFixture(); let owner = CancellationSource()
        try {
            let role = f.role("task", owner.token)
            let seed = f.product.request("child facts")
            let actual = AgentRunRequest(seed.runId, seed.sessionId, seed.model, seed.prompt,
                modelCapabilitiesSnapshot: Some(seed.modelCapabilitiesSnapshot),
                budget: ResourceBudget(maxOutputTokens: 9000, minVisibleResponseTokens: 77,
                    maxModelRequests: 3, maxTurns: 2, maxToolCalls: 4, maxChildren: 0, maxDepth: 0,
                    maxDrainModelRequests: 1, maxDrainTurns: 1, maxWallMillis: 1000),
                contextWindow: 12345, providerSafetyMargin: 123, executionLaneId: LaneId("other-data-lane"))
            let ceiling = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: "one-file")])
            let child = productSubagentRequest(actual, role, ceiling, ExecutionBudget(maxTotalInputTokens: 100,
                maxTotalOutputTokens: 200, maxCostMicros: 300), sharedContext: "external inherited text")
            @Expect(child.capabilities.values.size, 1)
            @Expect(child.capabilities.values[0].resource, "one-file")
            @Expect(!child.capabilities.allows(CapabilityKind.Delegate))
            @Expect(!child.capabilities.allows(CapabilityKind.ProcessSpawn))
            @Expect(child.budget.maxOutputTokens, 8000); @Expect(child.budget.maxChildren, 0)
            @Expect(child.budget.maxDepth, 0); @Expect(child.budget.maxTurns, 2)
            @Expect(child.budget.maxModelRequests, 3); @Expect(child.budget.maxToolCalls, 4)
            @Expect(child.budget.maxWallMillis, 1000); @Expect(child.budget.maxTotalInputTokens, 100)
            @Expect(child.budget.maxTotalOutputTokens, 200); @Expect(child.budget.maxCostMicros, 300)
            @Expect(child.budget.requestOutputBudget.minVisibleResponseTokens, 77)
            @Expect(child.budget.maxDrainModelRequests, 1); @Expect(child.budget.maxDrainTurns, 1)
            @Expect(refEq(child.modelCapabilitiesSnapshot, actual.modelCapabilitiesSnapshot))
            @Expect(child.contextWindow, 12345); @Expect(child.providerSafetyMargin, 123)
            @Expect(child.executionLaneId.value, "other-data-lane")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
        } finally { owner.close(); f.close() }
    }

    @TestCase
    func inheritedContextDoesNotChangeTheStableRolePrefix(): Unit {
        let f = WorkflowRolesFixture(); let owner = CancellationSource()
        try {
            let role = f.role("reviewer", owner.token)
            let first = productSubagentPrompt(role, "external first")
            let second = productSubagentPrompt(role, "external second")
            @Expect(first.stablePrefixHash, second.stablePrefixHash)
            @Expect(first.text != second.text)
            @Expect(!role.prompt.contains("external first"))
            @Expect(first.text.contains("external first"))
        } finally { owner.close(); f.close() }
    }

    @TestCase
    func remountAndConfigurationChangesInvalidatePreviouslyQueriedRoles(): Unit {
        let f = WorkflowRolesFixture(); let owner = CancellationSource()
        try {
            let original = f.role("reviewer", owner.token)
            @Expect(original.pin.validateCurrent().isOk())
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            @Expect(original.pin.validateCurrent().isError())
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            @Expect(original.pin.validateCurrent().isError())
            let current = f.role("reviewer", owner.token)
            @Expect(current.pin.validateCurrent().isOk())
            f.select("sha256:" + String.fromUtf8(Array<UInt8>(64, repeat: b'0')))
            @Expect(current.pin.validateCurrent().isError())
            @Expect(queryProductWorkflowAgents(f.product, f.session).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
        } finally { owner.close(); f.close() }
    }

    @TestCase
    func cancellationAndMissingSelectionDoNotUseNamedHostFallback(): Unit {
        let f = WorkflowRolesFixture(); let owner = CancellationSource()
        try {
            let _ = owner.cancel()
            @Expect(queryProductWorkflowRole(f.product, "task", f.session, owner.token, "cancelled").isError())
            File.writeTo(f.root + "/settings/plugins/policies.json", "{\"version\":1,\"bindings\":{}}".toArray())
            @Expect(queryProductWorkflowAgents(f.product, f.session).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
        } finally { owner.close(); f.close() }
    }

    @TestCase
    func actualTaskUsesNativePolicyAndCanonicalChildRunAndYield(): Unit {
        let f = WorkflowRolesFixture()
        try {
            let application = f.product.applicationSession()
            let turn = lifecycleTestRequire(application.handle("fixture task"))
            @Expect(turn.agentInvoked)
            let records = application.allSubagents()
            @Expect(records.size, 1); @Expect(records[0].id, "fixture-child")
            @Expect(records[0].status, "completed")
            @Expect(records[0].agentSource.startsWith("plugin:" + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ":"))
            @Expect(records[0].agentSource.contains(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            let restored = ProductTaskPersistence(f.database).loadAll()
            @Expect(restored.size, 1); @Expect(restored[0].subagents.size, 1)
            @Expect(restored[0].subagents[0].agentSource, records[0].agentSource)
            @Expect(restored[0].subagents[0].workflowPin.isNone())
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            let missingProviderHistory = ProductTaskPersistence(f.database).loadAll()
            @Expect(missingProviderHistory[0].subagents[0].agentSource, records[0].agentSource)
            @Expect(missingProviderHistory[0].subagents[0].workflowPin.isNone())
            let transcript = lifecycleTestRequire(application.subagentTranscript(subagentId: "fixture-child"))
            @Expect(transcript.messages.size >= 4)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'") >= 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts") >= 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func parentWithoutDelegateCannotUseRoleDeclarationToCreateChildRun(): Unit {
        let f = WorkflowRolesFixture()
        try {
            let result = f.product.vnext.executeCanonicalTool(SessionId("no-delegate-workflow"),
                CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), ToolCall("forbidden-child", "plugin.axyndra:workflow.task",
                    objectValue([ValueField("agent", textValue("task")), ValueField("task", textValue("child fixture yield"))])))
            match (result) {
                case Result.Err(_) => ()
                case Result.Ok(ToolInvocationResult.Completed(value)) => @Expect(value.isError)
                case Result.Ok(ToolInvocationResult.Denied(_)) => ()
                case _ => @Expect(false) }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
}
