package task_persistence_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_store.*
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

func launchNamedFixtureTask(application: ApplicationSession, name: String): ProductAsyncJobSnapshot {
    let launched = application.invokeLocalTool(
        "task",
        objectValue([
            ValueField("context", textValue("SQLite persistence contract")),
            ValueField("tasks", listValue([objectValue([
                ValueField("name", textValue(name)),
                ValueField("agent", textValue("reviewer")),
                ValueField("task", textValue("fast real task generation"))
            ])]))
        ])
    ).value().getOrThrow()
    let id = launched.output.field("async").getOrThrow()
        .field("jobIds").getOrThrow().items[0].text
    let settled = application.waitForAsyncJobs([id], timeoutMillis: 5000)
    expect(settled.size == 1, "named child Run remains addressable through settlement")
    settled[0]
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
