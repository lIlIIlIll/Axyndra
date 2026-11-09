package agent_product

import agent_domain.*
import agent_plugin_registry.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Install through the existing real operator APIs, close that eager runtime,
// then reopen exactly the persisted installation as the actual lazy Owner.
private func coldTodoOpen227(root: String, approval: ApprovalMode): ProductRuntime {
    Directory.create(root + "/workspace", recursive: true)
    let setup = workspacePluginOpen(root, ApprovalMode.Yolo)
    try { let record = todoTestInstallNative(setup); record.close() }
    finally { let _ = setup.close() }
    lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
        settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
        approvalMode: approval, asyncEnabled: false, startupMode: ProductStartupMode.Owner)))
}

@Test
class ColdTodoFrontend227Tests {
    @TestCase
    func ConfiguredHintAndHelpDoNotActivateOrAuthorizeTheColdContribution(): Unit {
        let root = pluginContractTemp("todo-cold-hints227")
        let product = coldTodoOpen227(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let session = product.applicationSession()
            @Expect(product.vnext.javascriptPlugins.instanceGeneration("axyndra:workflow"), 0u64)
            @Expect(session.frontendSlashDefinitions().map { item => item.name }.contains("todo"))
            @Expect(session.handle("/help").value().getOrThrow().text.contains("/todo"))
            @Expect(product.vnext.javascriptPlugins.instanceGeneration("axyndra:workflow"), 0u64)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { database.close(); let _ = product.close(); remove(root, recursive: true) }
    }
    @TestCase
    func FirstColdNativeTodoCommandPreparesTheOriginalCatalogBeforeSelection(): Unit {
        let root = pluginContractTemp("todo-cold-command227")
        let product = coldTodoOpen227(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let session = product.applicationSession()
            @Expect(product.vnext.javascriptPlugins.instanceGeneration("axyndra:workflow"), 0u64)
            let response = session.handle("/todo append Work cold")
            @Assert(response.isOk())
            let phases = session.todoPhases().value().getOrThrow()
            @Expect(phases.size, 1); @Expect(phases[0].name, "Work")
            @Expect(phases[0].tasks[0].content, "Cold")
            @Expect(product.vnext.javascriptPlugins.instanceGeneration("axyndra:workflow") > 0u64)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents WHERE document_key='todo' AND revision=1"), 1)
        } finally { database.close(); let _ = product.close(); remove(root, recursive: true) }
    }
    @TestCase
    func CancelledOwnerWithoutInstalledPackagesStopsBeforeAnyPreparation227(): Unit {
        let root = pluginContractTemp("todo-cold-early-cancel227")
        Directory.create(root + "/workspace", recursive: true)
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false, startupMode: ProductStartupMode.Owner)))
        let database = SqliteDatabase(root + "/state/state.db")
        let cancellation = CancellationSource(); cancellation.cancel()
        try {
            let session = ApplicationSession(product, frontendCancellation180: Some(cancellation.token))
            let result = session.loadTodoEditor()
            @Assert(result.isError()); @Expect(result.error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(product.vnext.javascriptPlugins.instanceGeneration("axyndra:workflow"), 0u64)
            let records = product.pluginSnapshots()
            try { @Expect(records.size, 0) } finally { records.close() }
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { cancellation.close(); database.close(); let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func CancelledColdEditorCannotStartTheCatalogOrRecordAnOperation(): Unit {
        let root = pluginContractTemp("todo-cold-cancel227")
        let product = coldTodoOpen227(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        let cancellation = CancellationSource(); cancellation.cancel()
        try {
            let session = ApplicationSession(product, frontendCancellation180: Some(cancellation.token))
            let result = session.loadTodoEditor()
            @Assert(result.isError()); @Expect(result.error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(product.vnext.javascriptPlugins.instanceGeneration("axyndra:workflow"), 0u64)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { cancellation.close(); database.close(); let _ = product.close(); remove(root, recursive: true) }
    }
}
