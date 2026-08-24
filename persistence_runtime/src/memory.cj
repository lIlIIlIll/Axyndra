package persistence_runtime

import agent_domain.*
import model_adapters.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*

public class MemoryDraft {
    public let content: String
    public let context: String
    public let source: String
    public let importancePermille: Int64

    public init(
        content: String,
        context!: String = "",
        source!: String = "",
        importancePermille!: Int64 = 750
    ) {
        this.content = content
        this.context = context
        this.source = source
        this.importancePermille = importancePermille
    }
}

public class MemoryRecord {
    public let id: String
    public let content: String
    public let context: String
    public let source: String
    public let importancePermille: Int64
    public let status: String
    public let replacementId: String
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: String,
        content: String,
        context: String,
        source: String,
        importancePermille: Int64,
        status: String,
        replacementId: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        this.id = id
        this.content = content
        this.context = context
        this.source = source
        this.importancePermille = importancePermille
        this.status = status
        this.replacementId = replacementId
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }
}

public class MemorySearchHit {
    public let memory: MemoryRecord
    public let scorePermille: Int64

    public init(memory: MemoryRecord, scorePermille: Int64) {
        this.memory = memory
        this.scorePermille = scorePermille
    }
}

public class MemoryEditOutcome {
    public let status: String
    public let memory: ?MemoryRecord

    public init(status: String, memory!: ?MemoryRecord = None) {
        this.status = status
        this.memory = memory
    }
}

// A small durable local memory bank. Mutations rewrite one complete JSONL
// snapshot so a failed update cannot leave a partially edited bank.
public class DiskMemoryRepository {
    private let root: String
    private let path: String
    private let lock = Mutex()
    private var counter: Int64 = 0

    public init(stateRoot: String) {
        this.root = stateRoot + "/memory"
        this.path = this.root + "/bank.jsonl"
        ensureDirectory(this.root)
    }

    public func retain(
        drafts: Array<MemoryDraft>
    ): Result<Array<MemoryRecord>> {
        withLock({ =>
            let records = match (load()) {
                case Result.Ok(value) => ArrayList<MemoryRecord>(value)
                case Result.Err(error) =>
                    return Result<Array<MemoryRecord>>.Err(error)
            }
            let created = ArrayList<MemoryRecord>()
            for (draft in drafts) {
                let content = draft.content.trimAscii()
                if (content == "") {
                    return memoryPersistenceError<Array<MemoryRecord>>(
                        "memory.content_empty",
                        "memory content must not be empty"
                    )
                }
                let now = memoryNowMillis()
                let record = MemoryRecord(
                    nextId(records, now),
                    content,
                    draft.context.trimAscii(),
                    draft.source.trimAscii(),
                    clampPermille(draft.importancePermille),
                    "active",
                    "",
                    now,
                    now
                )
                records.add(record)
                created.add(record)
            }
            match (persist(records.toArray())) {
                case Result.Ok(_) => Result.Ok(created.toArray())
                case Result.Err(error) =>
                    Result<Array<MemoryRecord>>.Err(error)
            }
        })
    }

    public func search(
        query: String,
        limit!: Int64 = 10
    ): Result<Array<MemorySearchHit>> {
        withLock({ =>
            let normalized = query.trimAscii().toAsciiLower()
            if (normalized == "") {
                return memoryPersistenceError<Array<MemorySearchHit>>(
                    "memory.query_empty",
                    "memory search query must not be empty"
                )
            }
            let records = match (load()) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    return Result<Array<MemorySearchHit>>.Err(error)
            }
            let hits = ArrayList<MemorySearchHit>()
            for (record in records where record.status == "active") {
                let score = memorySearchScore(record, normalized)
                if (score > 0) {
                    insertMemoryHit(hits, MemorySearchHit(
                        record,
                        if (score > 1000) { 1000 } else { score }
                    ))
                }
            }
            let bounded = if (limit < 1) {
                1
            } else if (limit > 100) {
                100
            } else {
                limit
            }
            let result = ArrayList<MemorySearchHit>()
            var index: Int64 = 0
            while (index < hits.size && index < bounded) {
                result.add(hits[index])
                index += 1
            }
            Result.Ok(result.toArray())
        })
    }

    public func get(id: String): Result<?MemoryRecord> {
        withLock({ =>
            match (load()) {
                case Result.Ok(records) =>
                    for (record in records where record.id == id) {
                        return Result.Ok(Some(record))
                    }
                    Result.Ok(None)
                case Result.Err(error) =>
                    Result<?MemoryRecord>.Err(error)
            }
        })
    }

    public func edit(
        op: String,
        id: String,
        content: ?String,
        importancePermille: ?Int64,
        replacementId: String
    ): Result<MemoryEditOutcome> {
        withLock({ =>
            let loaded = match (load()) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    return Result<MemoryEditOutcome>.Err(error)
            }
            let records = ArrayList<MemoryRecord>(loaded)
            var target: Int64 = -1
            for (index in 0..records.size where records[index].id == id) {
                target = index
                break
            }
            if (target < 0) {
                return Result.Ok(MemoryEditOutcome("not_found"))
            }
            let current = records[target]
            if (current.status != "active") {
                return Result.Ok(MemoryEditOutcome("not_found"))
            }
            if (op == "forget") {
                records.remove(at: target)
                return match (persist(records.toArray())) {
                    case Result.Ok(_) =>
                        Result.Ok(MemoryEditOutcome("deleted"))
                    case Result.Err(error) =>
                        Result<MemoryEditOutcome>.Err(error)
                }
            }
            let now = memoryNowMillis()
            let updated = if (op == "update") {
                MemoryRecord(
                    current.id,
                    match (content) {
                        case Some(value) => value.trimAscii()
                        case None => current.content
                    },
                    current.context,
                    current.source,
                    match (importancePermille) {
                        case Some(value) => clampPermille(value)
                        case None => current.importancePermille
                    },
                    current.status,
                    current.replacementId,
                    current.createdAt,
                    now
                )
            } else {
                MemoryRecord(
                    current.id,
                    current.content,
                    current.context,
                    current.source,
                    current.importancePermille,
                    "invalidated",
                    replacementId.trimAscii(),
                    current.createdAt,
                    now
                )
            }
            if (updated.content == "") {
                return memoryPersistenceError<MemoryEditOutcome>(
                    "memory.content_empty",
                    "replacement memory content must not be empty"
                )
            }
            records[target] = updated
            match (persist(records.toArray())) {
                case Result.Ok(_) =>
                    Result.Ok(MemoryEditOutcome(
                        if (op == "update") {
                            "updated"
                        } else {
                            "invalidated"
                        },
                        memory: Some(updated)
                    ))
                case Result.Err(error) =>
                    Result<MemoryEditOutcome>.Err(error)
            }
        })
    }

    public func list(): Result<Array<MemoryRecord>> {
        withLock({ => load() })
    }

    private func load(): Result<Array<MemoryRecord>> {
        if (!exists(Path(path))) { return Result.Ok([]) }
        let records = ArrayList<MemoryRecord>()
        for (line in readText(path).split("\n")
             where line.trimAscii() != "") {
            let value = match (decodeAgentValue(
                line,
                maxBytes: 67108864
            )) {
                case Result.Ok(item) => item
                case Result.Err(error) =>
                    return Result<Array<MemoryRecord>>.Err(error)
            }
            let record = match (decodeMemoryRecord(value)) {
                case Result.Ok(item) => item
                case Result.Err(error) =>
                    return Result<Array<MemoryRecord>>.Err(error)
            }
            records.add(record)
        }
        Result.Ok(records.toArray())
    }

    private func persist(records: Array<MemoryRecord>): Result<Unit> {
        var body = ""
        for (record in records) {
            body += encodeAgentValue(encodeMemoryRecord(record)) + "\n"
        }
        atomicWrite(path, body)
    }

    private func nextId(
        records: ArrayList<MemoryRecord>,
        now: Int64
    ): String {
        while (true) {
            counter += 1
            let candidate = "mem-" + now.toString() +
                "-" + counter.toString()
            var exists = false
            for (record in records where record.id == candidate) {
                exists = true
                break
            }
            if (!exists) { return candidate }
        }
        ""
    }

    private func withLock<T>(action: () -> Result<T>): Result<T> {
        lock.lock()
        try { action() } finally { lock.unlock() }
    }
}

public class DiskManagedSkillRepository {
    private let root: String
    private let lock = Mutex()

    public init(settingsRoot: String) {
        this.root = settingsRoot + "/managed-skills"
        ensureDirectory(root)
    }

    public func write(
        action: String,
        name: String,
        description: String,
        body: String
    ): Result<String> {
        lock.lock()
        try {
            let directory = root + "/" + safeId(name)
            let file = directory + "/SKILL.md"
            let existsAlready = exists(Path(file))
            if (action == "create" && existsAlready) {
                return memoryPersistenceError<String>(
                    "skill.already_exists",
                    "Managed skill \"" + name +
                        "\" already exists. Use action \"update\" to change it."
                )
            }
            if (action == "update" && !existsAlready) {
                return memoryPersistenceError<String>(
                    "skill.not_found",
                    "Managed skill \"" + name +
                        "\" does not exist. Use action \"create\" to add it."
                )
            }
            if (!exists(Path(directory))) {
                Directory.create(directory, recursive: true)
            }
            let canonicalRoot = canonicalize(Path(root)).toString()
            let canonicalDirectory = canonicalize(Path(directory)).toString()
            if (!pathInside(canonicalRoot, canonicalDirectory)) {
                return memoryPersistenceError<String>(
                    "skill.path_escape",
                    "managed skill resolves outside the managed directory"
                )
            }
            if (existsAlready && !FileInfo(Path(file)).isRegular()) {
                return memoryPersistenceError<String>(
                    "skill.not_regular",
                    "managed SKILL.md is not a regular file"
                )
            }
            let content = "---\nname: " + name +
                "\ndescription: " + quoteYaml(description) +
                "\n---\n\n" + body.trimAscii() + "\n"
            let contentBytes = unsafe { content.rawData() }
            if (contentBytes.size > 64000) {
                return memoryPersistenceError<String>(
                    "skill.too_large",
                    "Managed skill exceeds the 64000 byte limit."
                )
            }
            match (atomicWrite(file, content)) {
                case Result.Ok(_) =>
                    Result.Ok("managed-skills/" + name + "/SKILL.md")
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    public func delete(name: String): Result<Unit> {
        lock.lock()
        try {
            let directory = root + "/" + safeId(name)
            if (!exists(Path(directory))) {
                return memoryPersistenceError<Unit>(
                    "skill.not_found",
                    "Managed skill \"" + name + "\" does not exist."
                )
            }
            let canonicalRoot = canonicalize(Path(root)).toString()
            let canonicalDirectory = canonicalize(Path(directory)).toString()
            if (!pathInside(canonicalRoot, canonicalDirectory)) {
                return memoryPersistenceError<Unit>(
                    "skill.path_escape",
                    "managed skill resolves outside the managed directory"
                )
            }
            try {
                if (!removeIfExists(directory, recursive: true)) {
                    return memoryPersistenceError<Unit>(
                        "skill.delete_failed",
                        "managed skill could not be deleted"
                    )
                }
                Result.Ok(())
            } catch (error: Exception) {
                memoryPersistenceError<Unit>(
                    "skill.delete_failed",
                    error.message
                )
            }
        } finally {
            lock.unlock()
        }
    }
}

func encodeMemoryRecord(record: MemoryRecord): AgentValue {
    objectValue([
        ValueField("id", textValue(record.id)),
        ValueField("content", textValue(record.content)),
        ValueField("context", textValue(record.context)),
        ValueField("source", textValue(record.source)),
        ValueField(
            "importancePermille",
            integerValue(record.importancePermille)
        ),
        ValueField("status", textValue(record.status)),
        ValueField("replacementId", textValue(record.replacementId)),
        ValueField("createdAt", integerValue(record.createdAt)),
        ValueField("updatedAt", integerValue(record.updatedAt))
    ])
}

func decodeMemoryRecord(value: AgentValue): Result<MemoryRecord> {
    let id = textOr(value, "id")
    let content = textOr(value, "content")
    let status = textOr(value, "status")
    if (id == "" || content == "" ||
        (status != "active" && status != "invalidated")) {
        return memoryPersistenceError<MemoryRecord>(
            "memory.record_invalid",
            "persisted memory record is incomplete"
        )
    }
    Result.Ok(MemoryRecord(
        id,
        content,
        textOr(value, "context"),
        textOr(value, "source"),
        clampPermille(integerOr(value, "importancePermille")),
        status,
        textOr(value, "replacementId"),
        integerOr(value, "createdAt"),
        integerOr(value, "updatedAt")
    ))
}

func memorySearchScore(
    record: MemoryRecord,
    query: String
): Int64 {
    let content = record.content.toAsciiLower()
    let context = record.context.toAsciiLower()
    var score: Int64 = 0
    if (content.contains(query)) { score += 700 }
    for (raw in query.split(" ")) {
        let token = raw.trimAscii()
        if (token == "") { continue }
        if (content.contains(token)) {
            score += 120
        } else if (context.contains(token)) {
            score += 40
        }
    }
    if (score == 0) { return 0 }
    score + record.importancePermille / 10
}

func insertMemoryHit(
    values: ArrayList<MemorySearchHit>,
    value: MemorySearchHit
): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 &&
        memoryHitBefore(values[index], values[index - 1])) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index -= 1
    }
}

func memoryHitBefore(left: MemorySearchHit, right: MemorySearchHit): Bool {
    if (left.scorePermille != right.scorePermille) {
        return left.scorePermille > right.scorePermille
    }
    if (left.memory.updatedAt != right.memory.updatedAt) {
        return left.memory.updatedAt > right.memory.updatedAt
    }
    left.memory.id < right.memory.id
}

func clampPermille(value: Int64): Int64 {
    if (value < 0) { 0 } else if (value > 1000) { 1000 } else { value }
}

func memoryNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func pathInside(root: String, candidate: String): Bool {
    candidate == root || candidate.startsWith(root + "/")
}

func quoteYaml(value: String): String {
    "\"" + value.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", " ")
        .replace("\r", " ") + "\""
}

func memoryPersistenceError<T>(
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        code,
        message
    ))
}
