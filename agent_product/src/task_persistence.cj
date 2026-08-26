package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_store.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.sync.*

let TASK_PERSIST_MAX_RECORD_BYTES: Int64 = 16777216
let TASK_PERSIST_RESULT_RECORD_BYTES: Int64 = 1048576
let TASK_PERSIST_RESULT_PREVIEW_BYTES: Int64 = 65536
// Product task state is one revision-checked snapshot per root Thread in the
// canonical SQLite database. A snapshot commit is atomic with its revision.
class ProductTaskPersistedRoot {
    let rootSessionId: SessionId
    let revision: Int64
    let subagentCounter: Int64
    let jobCounter: Int64
    let messageCounter: Int64
    let subagents: Array<ProductSubagentState>
    let jobs: Array<ProductAsyncJobState>
    let messages: Array<ProductHubMessageState>

    init(
        rootSessionId: SessionId,
        revision: Int64,
        subagentCounter: Int64,
        jobCounter: Int64,
        messageCounter: Int64,
        subagents: Array<ProductSubagentState>,
        jobs: Array<ProductAsyncJobState>,
        messages: Array<ProductHubMessageState>
    ) {
        this.rootSessionId = rootSessionId
        this.revision = revision
        this.subagentCounter = subagentCounter
        this.jobCounter = jobCounter
        this.messageCounter = messageCounter
        this.subagents = subagents
        this.jobs = jobs
        this.messages = messages
    }
}

class ProductTaskRecoveryWarning {
    let rootSessionId: String
    let file: String
    let reason: String

    init(rootSessionId: String, file: String, reason: String) {
        this.rootSessionId = rootSessionId
        this.file = file
        this.reason = reason
    }

    func text(): String {
        "task recovery warning: root=" + rootSessionId + " file=" + file + " reason=" + reason
    }
}

class ProductTaskPersistence {
    private let lock = Mutex()
    private let recoveryWarnings = ArrayList<ProductTaskRecoveryWarning>()
    private let blockedRoots = ArrayList<String>()
    private let database: SqliteDatabase

    init(database: SqliteDatabase) {
        this.database = database
    }

    func loadAll(): Array<ProductTaskPersistedRoot> {
        lock.lock()
        try {
            let restored = ArrayList<ProductTaskPersistedRoot>()
            try {
                for (row in database.query(
                    "SELECT root_thread_id,revision,payload FROM task_snapshots ORDER BY root_thread_id"
                )) {
                    try {
                        let decoded = match (decodeAgentValue(
                            row.required(2), maxBytes: TASK_PERSIST_MAX_RECORD_BYTES
                        )) {
                            case Result.Ok(value) => taskPersistDecodeRoot(value)
                            case Result.Err(error) => throw IllegalArgumentException(error.message)
                        }
                        if (decoded.rootSessionId.value != row.required(0) ||
                            decoded.revision != Int64.parse(row.required(1))) {
                            throw IllegalArgumentException("task snapshot identity or revision mismatch")
                        }
                        restored.add(decoded)
                    } catch (error: Exception) {
                        addRecoveryWarning(row.required(0), "state.db", "cannot load task snapshot: " + error.message)
                        blockedRoots.add(row.required(0))
                    }
                }
            } catch (error: Exception) {
                addRecoveryWarning("unknown", "state.db", "cannot enumerate task snapshots: " + error.message)
            }
            restored.toArray()
        } finally {
            lock.unlock()
        }
    }

    func warnings(): Array<ProductTaskRecoveryWarning> {
        lock.lock()
        try {
            recoveryWarnings.toArray()
        } finally {
            lock.unlock()
        }
    }

    func appendRoot(
        rootSessionId: SessionId,
        revision: Int64,
        subagentCounter: Int64,
        jobCounter: Int64,
        messageCounter: Int64,
        subagents: Array<ProductSubagentState>,
        jobs: Array<ProductAsyncJobState>,
        messages: Array<ProductHubMessageState>
    ): Result<Unit> {
        let encoded = encodeAgentValue(
            taskPersistRootValue(
                rootSessionId,
                revision,
                subagentCounter,
                jobCounter,
                messageCounter,
                subagents,
                jobs,
                messages
            )
        )
        let encodedBytes = encoded.toArray().size
        if (encodedBytes > TASK_PERSIST_MAX_RECORD_BYTES) {
            return taskPersistWriteError(
                "task persistence record exceeds 16 MiB",
                rootSessionId.value
            )
        }
        lock.lock()
        try {
            if (taskPersistContains(blockedRoots, rootSessionId.value)) {
                return taskPersistWriteError(
                    "task persistence root is blocked after recovery failure",
                    rootSessionId.value
                )
            }
            try {
                database.transaction<Result<Unit>>({ transaction =>
                    let rows = transaction.query(
                        "SELECT revision FROM task_snapshots WHERE root_thread_id=" +
                            sqliteText(rootSessionId.value)
                    )
                    let current = if (rows.isEmpty()) { 0 } else { Int64.parse(rows[0].required(0)) }
                    if (revision != current + 1) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "task.persistence_revision_conflict",
                            "task snapshot revision is stale"
                        ))
                    }
                    transaction.execute(
                        "INSERT INTO task_snapshots(root_thread_id,revision,payload,updated_at_millis) VALUES(" +
                            sqliteText(rootSessionId.value) + "," + revision.toString() + "," +
                            sqliteText(encoded) + "," + nowMillis().toString() + ") " +
                            "ON CONFLICT(root_thread_id) DO UPDATE SET revision=excluded.revision," +
                            "payload=excluded.payload,updated_at_millis=excluded.updated_at_millis"
                    )
                    Result.Ok(())
                })
            } catch (error: Exception) {
                taskPersistWriteError(
                    "cannot commit task snapshot: " + error.message,
                    rootSessionId.value
                )
            }
        } finally {
            lock.unlock()
        }
    }

    private func addRecoveryWarning(rootSessionId: String, file: String, reason: String): Unit {
        for (warning in recoveryWarnings where warning.rootSessionId == rootSessionId && warning.file == file &&
            warning.reason == reason) {
            return
        }
        recoveryWarnings.add(ProductTaskRecoveryWarning(rootSessionId, file, reason))
    }
}

func taskSettlementReceipt(sessionId: String, jobId: String, instanceId: Int64): String {
    "async-result:" + sessionId + ":" + jobId + ":" + instanceId.toString()
}

func taskPersistRootValue(
    rootSessionId: SessionId,
    revision: Int64,
    subagentCounter: Int64,
    jobCounter: Int64,
    messageCounter: Int64,
    subagents: Array<ProductSubagentState>,
    jobs: Array<ProductAsyncJobState>,
    messages: Array<ProductHubMessageState>
): AgentValue {
    let encodedSubagents = ArrayList<AgentValue>()
    for (state in subagents) { encodedSubagents.add(taskPersistSubagentValue(state)) }
    let encodedJobs = ArrayList<AgentValue>()
    for (state in jobs) { encodedJobs.add(taskPersistJobValue(state)) }
    let encodedMessages = ArrayList<AgentValue>()
    for (state in messages) { encodedMessages.add(taskPersistMessageValue(state)) }
    objectValue([
        ValueField("version", integerValue(2)),
        ValueField("rootSessionId", textValue(rootSessionId.value)),
        ValueField("revision", integerValue(revision)),
        ValueField("subagentCounter", integerValue(subagentCounter)),
        ValueField("jobCounter", integerValue(jobCounter)),
        ValueField("messageCounter", integerValue(messageCounter)),
        ValueField("subagents", listValue(encodedSubagents.toArray())),
        ValueField("jobs", listValue(encodedJobs.toArray())),
        ValueField("messages", listValue(encodedMessages.toArray()))
    ])
}

func taskPersistSubagentValue(state: ProductSubagentState): AgentValue {
    objectValue([
        ValueField("id", textValue(state.id)),
        ValueField("index", integerValue(state.index)),
        ValueField("agent", textValue(state.agent)),
        ValueField("description", textValue(state.description)),
        ValueField("task", textValue(state.task)),
        ValueField("assignment", textValue(state.assignment)),
        ValueField("sessionId", textValue(state.sessionId.value)),
        ValueField("sessionRef", textValue(state.sessionRef)),
        ValueField("runId", textValue(state.runId.value)),
        ValueField("parentRunId", textValue(state.parentRunId.value)),
        ValueField("parentToolCallId", textValue(state.parentToolCallId)),
        ValueField("depth", integerValue(state.depth)),
        ValueField("startedAt", integerValue(state.startedAt)),
        ValueField("status", textValue(state.status)),
        ValueField("lastUpdate", integerValue(state.lastUpdate)),
        ValueField("requests", integerValue(state.requests)),
        ValueField("tokens", integerValue(state.tokens)),
        ValueField("toolCount", integerValue(state.toolCount)),
        ValueField("currentTool", textValue(state.currentTool)),
        ValueField("error", textValue(state.error))
    ])
}

func taskPersistJobValue(state: ProductAsyncJobState): AgentValue {
    objectValue([
        ValueField("id", textValue(state.id)),
        ValueField("agentId", textValue(state.agentId)),
        ValueField("jobType", textValue(state.jobType)),
        ValueField("label", textValue(state.label)),
        ValueField("sessionId", textValue(state.sessionId.value)),
        ValueField("ownerRunId", textValue(state.ownerRunId.value)),
        ValueField("instanceId", integerValue(state.instanceId)),
        ValueField("parentToolCallId", textValue(state.parentToolCallId)),
        ValueField("operationId", textValue(state.operationId)),
        ValueField("startedAt", integerValue(state.startedAt)),
        ValueField("status", textValue(state.status)),
        ValueField("updatedAt", integerValue(state.updatedAt)),
        ValueField(
            "result",
            match (state.result) {
                case Some(value) => taskPersistBoundJobResult(value)
                case None => nullValue()
            }
        ),
        ValueField("error", textValue(state.error)),
        ValueField("executing", boolValue(state.executing)),
        ValueField("settlementReceiptId", textValue(state.settlementReceiptId)),
        ValueField("settlementInjected", boolValue(state.settlementInjected))
    ])
}

// A live job keeps its full result in memory and the transcript settlement can
// still point at artifact blobs. The recovery journal only needs a bounded
// representation: persisting multi-megabyte stdout/stderr previews makes an
// otherwise valid root exceed the 16 MiB record limit and turns every later
// task mutation into a silent write failure.
func taskPersistBoundJobResult(value: AgentValue): AgentValue {
    let encoded = encodeAgentValue(value)
    let bytes = encoded.toArray()
    if (bytes.size <= TASK_PERSIST_RESULT_RECORD_BYTES) { return value }

    let artifactRefs = ArrayList<AgentValue>()
    taskPersistCollectArtifactRefs(value, artifactRefs, 0)
    objectValue([
        ValueField("persistence_summary", boolValue(true)),
        ValueField("encoded_bytes", integerValue(bytes.size)),
        ValueField(
            "preview",
            textValue(artifactPreview(bytes, TASK_PERSIST_RESULT_PREVIEW_BYTES))
        ),
        ValueField("artifact_refs", listValue(artifactRefs.toArray())),
        ValueField("truncated", boolValue(true))
    ])
}

func taskPersistCollectArtifactRefs(
    value: AgentValue,
    values: ArrayList<AgentValue>,
    depth: Int64
): Unit {
    if (depth > 12 || values.size >= 64) { return }
    match (value.unifiedKind) {
        case ValueKind.Object =>
            for (field in value.fields) {
                if ((field.name == "artifact_ref" || field.name == "ref") && field.value.unifiedKind == ValueKind.Text &&
                    field.value.text.startsWith("blob:sha256:")) {
                    var duplicate = false
                    for (existing in values where existing.text == field.value.text) { duplicate = true }
                    if (!duplicate) { values.add(textValue(field.value.text)) }
                } else {
                    taskPersistCollectArtifactRefs(field.value, values, depth + 1)
                }
                if (values.size >= 64) { return }
            }
        case ValueKind.List =>
            for (item in value.items) {
                taskPersistCollectArtifactRefs(item, values, depth + 1)
                if (values.size >= 64) { return }
            }
        case _ => ()
    }
}

func taskPersistWriteError<T>(reason: String, rootSessionId: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.RecoveryRequired,
            "task.persistence_failed",
            reason,
            fields: [ErrorField("rootSessionId", rootSessionId)]
        )
    )
}

func taskPersistMessageValue(state: ProductHubMessageState): AgentValue {
    objectValue([
        ValueField("id", textValue(state.snapshot.id)),
        ValueField("from", textValue(state.snapshot.from)),
        ValueField("to", textValue(state.snapshot.to)),
        ValueField("message", textValue(state.snapshot.message)),
        ValueField("replyTo", textValue(state.snapshot.replyTo)),
        ValueField("createdAt", integerValue(state.snapshot.createdAt)),
        ValueField("targetSessionId", textValue(state.targetSessionId.value)),
        ValueField("waitCallId", textValue(state.waitCallId)),
        ValueField("reviveTarget", boolValue(state.reviveTarget)),
        ValueField("consumed", boolValue(state.consumed))
    ])
}

func taskPersistDecodeRoot(value: AgentValue): ProductTaskPersistedRoot {
    taskPersistRequireObject(value, "task root")
    let version = taskPersistInteger(value, "version")
    if (version != 2) {
        throw IllegalArgumentException("unsupported task persistence version: " + version.toString())
    }
    let rootSessionId = taskPersistNonEmptyText(value, "rootSessionId")
    let revision = taskPersistNonNegative(value, "revision")
    if (revision == 0) { throw IllegalArgumentException("task revision must be positive") }
    let subagentCounter = taskPersistNonNegative(value, "subagentCounter")
    let storedJobCounter = taskPersistNonNegative(value, "jobCounter")
    let messageCounter = taskPersistNonNegative(value, "messageCounter")
    let subagents = ArrayList<ProductSubagentState>()
    let subagentIds = ArrayList<String>()
    for (item in taskPersistList(value, "subagents")) {
        let decoded = taskPersistDecodeSubagent(item, rootSessionId)
        if (taskPersistContains(subagentIds, decoded.id)) {
            throw IllegalArgumentException("duplicate subagent id")
        }
        subagentIds.add(decoded.id)
        subagents.add(decoded)
    }
    let jobs = ArrayList<ProductAsyncJobState>()
    let jobIds = ArrayList<String>()
    let storedJobs = taskPersistList(value, "jobs")
    var currentJobCounter = storedJobCounter
    for (item in storedJobs) {
        let decoded = taskPersistDecodeJob(item, rootSessionId)
        currentJobCounter = max(currentJobCounter, decoded.instanceId)
        if (taskPersistContains(jobIds, decoded.id)) {
            throw IllegalArgumentException("duplicate async job id")
        }
        jobIds.add(decoded.id)
        jobs.add(decoded)
    }
    let messages = ArrayList<ProductHubMessageState>()
    let messageIds = ArrayList<String>()
    for (item in taskPersistList(value, "messages")) {
        let decoded = taskPersistDecodeMessage(item, rootSessionId)
        if (taskPersistContains(messageIds, decoded.snapshot.id)) {
            throw IllegalArgumentException("duplicate hub message id")
        }
        messageIds.add(decoded.snapshot.id)
        messages.add(decoded)
    }
    ProductTaskPersistedRoot(
        SessionId(rootSessionId),
        revision,
        subagentCounter,
        currentJobCounter,
        messageCounter,
        subagents.toArray(),
        jobs.toArray(),
        messages.toArray()
    )
}

func taskPersistDecodeSubagent(value: AgentValue, rootSessionId: String): ProductSubagentState {
    taskPersistRequireObject(value, "subagent")
    let id = taskPersistNonEmptyText(value, "id")
    let index = taskPersistNonNegative(value, "index")
    let status = taskPersistKnownStatus(
        taskPersistNonEmptyText(value, "status"),
        ["running", "blocked", "completed", "failed", "cancelled", "recovery_required"],
        "subagent"
    )
    let storedError = taskPersistText(value, "error")
    let interrupted = status == "running" || status == "blocked"
    let restoredStatus = if (interrupted) { "recovery_required" } else { status }
    let restoredError = if (interrupted) {
        "recovery_required: process restarted before subagent settled" +
            if (storedError == "") { "" } else { "; previous error: " + storedError }
    } else {
        storedError
    }
    let startedAt = taskPersistPositive(value, "startedAt")
    let lastUpdate = taskPersistPositive(value, "lastUpdate")
    if (lastUpdate < startedAt) {
        throw IllegalArgumentException("subagent lastUpdate precedes startedAt")
    }
    let state = ProductSubagentState(
        id,
        index,
        taskPersistText(value, "agent"),
        taskPersistText(value, "description"),
        taskPersistText(value, "task"),
        taskPersistText(value, "assignment"),
        SessionId(taskPersistNonEmptyText(value, "sessionId")),
        taskPersistText(value, "sessionRef"),
        RunId(taskPersistNonEmptyText(value, "runId")),
        RunId(taskPersistNonEmptyText(value, "parentRunId")),
        SessionId(rootSessionId),
        taskPersistText(value, "parentToolCallId"),
        taskPersistNonNegative(value, "depth"),
        capabilities: CapabilitySet(),
        startedAt: startedAt,
        status: restoredStatus,
        lastUpdate: lastUpdate
    )
    state.requests = taskPersistNonNegative(value, "requests")
    state.tokens = taskPersistNonNegative(value, "tokens")
    state.toolCount = taskPersistNonNegative(value, "toolCount")
    state.currentTool = if (interrupted) { "" } else { taskPersistText(value, "currentTool") }
    state.error = restoredError
    // pendingRequest, approval state, denial history, and capabilities are
    // intentionally never decoded from disk.
    state
}

func taskPersistDecodeJob(
    value: AgentValue,
    rootSessionId: String
): ProductAsyncJobState {
    taskPersistRequireObject(value, "async job")
    let id = taskPersistNonEmptyText(value, "id")
    let sessionId = taskPersistNonEmptyText(value, "sessionId")
    let jobType = taskPersistKnownStatus(taskPersistNonEmptyText(value, "jobType"), ["task", "bash"], "job type")
    let agentId = taskPersistText(value, "agentId")
    if ((jobType == "task" && (agentId == "" || agentId != id)) || (jobType == "bash" && agentId != "")) {
        throw IllegalArgumentException("async job identity does not match its type")
    }
    let status = taskPersistKnownStatus(
        taskPersistNonEmptyText(value, "status"),
        ["running", "blocked", "completed", "failed", "cancelled", "recovery_required"],
        "async job"
    )
    let executing = taskPersistBoolean(value, "executing")
    let instanceId = taskPersistPositive(value, "instanceId")
    let interrupted = status == "running" || status == "blocked" || executing
    let restoredStatus = if (interrupted) { "recovery_required" } else { status }
    let storedError = taskPersistText(value, "error")
    let restoredError = if (interrupted) {
        "recovery_required: process restarted before async job settled" +
            if (storedError == "") { "" } else { "; previous error: " + storedError }
    } else {
        storedError
    }
    let resultField = taskPersistField(value, "result")
    var receipt = taskPersistText(value, "settlementReceiptId")
    var injected = taskPersistBoolean(value, "settlementInjected")
    if (status == "running" && (receipt != "" || injected)) {
        throw IllegalArgumentException("running async job contains settlement metadata")
    }
    if (interrupted && receipt == "") {
        receipt = taskSettlementReceipt(sessionId, id, instanceId)
        injected = false
    }
    if (!interrupted && status != "running" && receipt == "") {
        throw IllegalArgumentException("settled async job is missing settlement receipt")
    }
    let currentReceipt = taskSettlementReceipt(sessionId, id, instanceId)
    if (receipt != "" && receipt != currentReceipt) {
        throw IllegalArgumentException("async job settlement receipt does not match its key")
    }
    if (injected && receipt == "") {
        throw IllegalArgumentException("injected async job is missing settlement receipt")
    }
    let startedAt = taskPersistPositive(value, "startedAt")
    let updatedAt = taskPersistPositive(value, "updatedAt")
    if (updatedAt < startedAt) {
        throw IllegalArgumentException("async job updatedAt precedes startedAt")
    }
    ProductAsyncJobState(
        id,
        agentId,
        jobType,
        taskPersistText(value, "label"),
        SessionId(sessionId),
        SessionId(rootSessionId),
        RunId(taskPersistNonEmptyText(value, "ownerRunId")),
        instanceId,
        parentToolCallId: taskPersistText(value, "parentToolCallId"),
        operationId: taskPersistText(value, "operationId"),
        startedAt: startedAt,
        status: restoredStatus,
        updatedAt: updatedAt,
        result: if (resultField.unifiedKind == ValueKind.Null) { None } else { Some(resultField) },
        error: restoredError,
        executing: false,
        settlementReceiptId: receipt,
        settlementInjected: injected
    )
}

func taskPersistDecodeMessage(value: AgentValue, rootSessionId: String): ProductHubMessageState {
    taskPersistRequireObject(value, "hub message")
    ProductHubMessageState(
        ProductHubMessageSnapshot(
            taskPersistNonEmptyText(value, "id"),
            taskPersistNonEmptyText(value, "from"),
            taskPersistNonEmptyText(value, "to"),
            taskPersistText(value, "message"),
            taskPersistText(value, "replyTo"),
            taskPersistPositive(value, "createdAt")
        ),
        SessionId(taskPersistNonEmptyText(value, "targetSessionId")),
        SessionId(rootSessionId),
        waitCallId: taskPersistText(value, "waitCallId"),
        // Delivery/revival workers are process-local and are never restarted.
        reviveTarget: false,
        consumed: taskPersistBoolean(value, "consumed")
    )
}

func taskPersistRequireObject(value: AgentValue, label: String): Unit {
    if (value.unifiedKind != ValueKind.Object) {
        throw IllegalArgumentException(label + " must be an object")
    }
}

func taskPersistField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalArgumentException("missing task persistence field: " + name)
    }
}

func taskPersistText(value: AgentValue, name: String): String {
    let item = taskPersistField(value, name)
    if (item.unifiedKind != ValueKind.Text) {
        throw IllegalArgumentException("task persistence field is not text: " + name)
    }
    item.text
}

func taskPersistNonEmptyText(value: AgentValue, name: String): String {
    let item = taskPersistText(value, name)
    if (item.trimAscii() == "") {
        throw IllegalArgumentException("task persistence field is empty: " + name)
    }
    item
}

func taskPersistInteger(value: AgentValue, name: String): Int64 {
    let item = taskPersistField(value, name)
    if (item.unifiedKind != ValueKind.Number) {
        throw IllegalArgumentException("task persistence field is not an integer: " + name)
    }
    try {
        Int64.parse(item.number)
    } catch (_: Exception) {
        throw IllegalArgumentException("task persistence field is not an integer: " + name)
    }
}

func taskPersistNonNegative(value: AgentValue, name: String): Int64 {
    let item = taskPersistInteger(value, name)
    if (item < 0) {
        throw IllegalArgumentException("task persistence field is negative: " + name)
    }
    item
}

func taskPersistPositive(value: AgentValue, name: String): Int64 {
    let item = taskPersistInteger(value, name)
    if (item <= 0) {
        throw IllegalArgumentException("task persistence field is not positive: " + name)
    }
    item
}

func taskPersistBoolean(value: AgentValue, name: String): Bool {
    let item = taskPersistField(value, name)
    if (item.unifiedKind != ValueKind.Boolean) {
        throw IllegalArgumentException("task persistence field is not boolean: " + name)
    }
    item.boolean
}

func taskPersistList(value: AgentValue, name: String): Array<AgentValue> {
    let item = taskPersistField(value, name)
    if (item.unifiedKind != ValueKind.List) {
        throw IllegalArgumentException("task persistence field is not a list: " + name)
    }
    item.items
}

func taskPersistKnownStatus(value: String, allowed: Array<String>, label: String): String {
    for (candidate in allowed where candidate == value) { return value }
    throw IllegalArgumentException("unknown " + label + " value: " + value)
}

func taskPersistContains(values: ArrayList<String>, target: String): Bool {
    for (value in values where value == target) { return true }
    false
}
