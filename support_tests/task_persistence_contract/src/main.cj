package task_persistence_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_store.*
import std.env.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        let state = root + "/state"
        let firstId = SessionId("task-sqlite-first")
        let secondId = SessionId("task-sqlite-second")
        let first = openFixtureProduct(state, root)
        installTaskProvider(first)
        let firstApp = first.applicationSession(sessionId: Some(firstId))
        let secondApp = first.applicationSession(sessionId: Some(secondId))
        let firstJob = launchNamedFixtureTask(firstApp, "first-job")
        let secondJob = launchNamedFixtureTask(secondApp, "second-job")
        expect(firstJob.status == "completed" && secondJob.status == "completed",
            "completed child Runs settle before the owning runtime closes")
        first.close().value().getOrThrow()

        let database = SqliteDatabase(state + "/state.db")
        expect(database.scalarInt("SELECT COUNT(*) FROM task_snapshots") == 2,
            "each root Thread has one canonical task snapshot")
        expect(database.scalarInt("SELECT MIN(revision) FROM task_snapshots") > 0,
            "task snapshots carry monotonic positive revisions")
        expect(!exists(Path(state + "/task-runtime")),
            "production task durability does not create legacy JSONL journals")
        database.close()

        let reopened = openFixtureProduct(state, root)
        expect(reopened.asyncJobs(firstId).size == 1 && reopened.asyncJobs(firstId)[0].id == "first-job" &&
            reopened.asyncJobs(secondId).size == 1 && reopened.asyncJobs(secondId)[0].id == "second-job",
            "SQLite snapshots restore independently for multiple roots")
        reopened.close().value().getOrThrow()

        let corrupt = SqliteDatabase(state + "/state.db")
        corrupt.execute(
            "UPDATE task_snapshots SET payload='{broken' WHERE root_thread_id=" + sqliteText(firstId.value)
        )
        corrupt.close()
        let recovered = openFixtureProduct(state, root)
        let warnings = recovered.taskRecoveryWarnings(firstId)
        expect(!warnings.isEmpty() && warnings[0].contains("state.db") &&
            recovered.asyncJobs(firstId).isEmpty(),
            "a corrupt canonical snapshot is blocked and surfaced instead of guessed")
        recovered.close().value().getOrThrow()

        println("task persistence contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func openFixtureProduct(stateRoot: String, workspaceRoot: String): ProductRuntime {
    openProduct(config: ProductConfig(
        settingsRoot: workspaceRoot + "/settings",
        stateRoot: stateRoot,
        workspaceRoot: workspaceRoot,
        fixture: true,
        unsafeDirectLaunchForTests: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: true
    )).value().getOrThrow()
}

private func installTaskProvider(product: ProductRuntime): Unit {
    let namespace = "axyndra:workflow"
    let record = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow())) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            let code = error.code; error.close(); throw IllegalStateException("workflow import: " + code)
    }
    try {
        expect(record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace), "expected the Workflow package")
        let digest = match (record.descriptor.copyText(PluginDescriptorText.ContentDigest)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                let code = error.code; error.close(); throw IllegalStateException("workflow digest: " + code)
        }
        try {
            expect(digest.byteCount == 71, "expected a sha256 package digest")
            let paid = digest.deriveCopiedDataPayment(65536 + digest.byteCount * 256)
            try { writeTaskSelections(product.settingsRoot, namespace, digest) } finally { paid.close() }
        } finally { digest.close() }
    } finally { record.close() }
    match (product.setPluginEnabled(namespace, true)) {
        case PluginRegistryResult.Ok(enabled) => enabled.close()
        case PluginRegistryResult.Err(error) =>
            let code = error.code; error.close(); throw IllegalStateException("workflow enable: " + code)
    }
}

private func writeTaskSelections(settings: String, namespace: String, source: OwnedRegistryUtf8): Unit {
    let digest = String.fromUtf8(Array<UInt8>(source.byteCount, { i => source.byteAt(i) }))
    let policy = objectValue([ValueField("version", integerValue(1)), ValueField("bindings", objectValue([
        ValueField("workflow", objectValue([ValueField("namespace", textValue(namespace)),
            ValueField("provider", textValue("propose")), ValueField("package_digest", textValue(digest))]))]))])
    let primitive = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
        objectValue([ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
            ValueField("tools", listValue([objectValue([ValueField("name", textValue("task")),
                ValueField("profile", textValue("frozen-primitives-v1")),
                ValueField("services", listValue([textValue("child.start")])),
                ValueField("invocation_capability", textValue("delegate")),
                ValueField("preparation_provider", textValue("prepare_child"))])]))])]))])
    for ((file, value) in [("policies.json", policy), ("primitives.json", primitive)]) {
        let path = Path(settings).join("plugins").join(file)
        expect(!exists(path), "fixture must not replace an existing Workflow selection")
        File.writeTo(path, stringifyUnifiedJson(value).toArray())
    }
}

func launchNamedFixtureTask(application: ApplicationSession, name: String): ProductAsyncJobSnapshot {
    let launched = match (application.invokeLocalTool(
        "plugin.axyndra:workflow.task",
        objectValue([
            ValueField("context", textValue("SQLite persistence contract")),
            ValueField("tasks", listValue([objectValue([
                ValueField("name", textValue(name)),
                ValueField("agent", textValue("reviewer")),
                ValueField("task", textValue("fast real task generation"))
            ])]))
        ])
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => throw IllegalStateException("task launch failed: " + error.describe())
    }
    try {
        let ids = launched.output.field("async").getOrThrow().field("jobIds").getOrThrow().items
        expect(ids.size == 1 && ids[0].text == name, "the installed Task admitted exactly the named job")
    } finally { launched.releasePayload() }
    let settled = application.waitForAsyncJobs([name], timeoutMillis: 5000)
    expect(settled.size == 1, "named child Run remains addressable through settlement")
    settled[0]
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
