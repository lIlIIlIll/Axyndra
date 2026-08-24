package persistence_runtime

import agent_domain.*
import agent_store.*
import model_adapters.*
import std.collection.*
import std.deriving.*
import std.fs.*
import std.sync.*
import std.time.*

@Derive[Equatable]
public enum MemoryKind {
    Preference
    | ProjectFact
    | Decision
    | Constraint
    | Observation
}

@Derive[Equatable]
public enum MemoryScopeKind {
    Global
    | User
    | Workspace
    | Session
}

@Derive[Equatable]
public enum MemoryStatus {
    Active
    | Corrected
    | Deleted
    | Conflicted
    | Expired
}

@Derive[Equatable]
public enum MemorySearchStrategy {
    Lexical
    | Hybrid
    | LexicalFallback
}

public class MemoryScope {
    public let kind: MemoryScopeKind
    public let key: String

    public init(kind: MemoryScopeKind, key!: String = "") {
        let normalized = key.trimAscii()
        if (kind != MemoryScopeKind.Global && normalized == "") {
            throw IllegalArgumentException("non-global memory scope requires a key")
        }
        if (kind == MemoryScopeKind.Global && normalized != "") {
            throw IllegalArgumentException("global memory scope must not have a key")
        }
        this.kind = kind
        this.key = normalized
    }
}

public class MemoryV3Draft {
    public let kind: MemoryKind
    public let scope: MemoryScope
    public let content: String
    public let context: String
    public let source: String
    public let importancePermille: Int64
    // Zero means no expiry; otherwise UTC Unix milliseconds.
    public let expiresAt: Int64

    public init(
        kind: MemoryKind,
        scope: MemoryScope,
        content: String,
        context!: String = "",
        source!: String = "",
        importancePermille!: Int64 = 750,
        expiresAt!: Int64 = 0
    ) {
        if (content.trimAscii() == "") {
            throw IllegalArgumentException("memory content must not be empty")
        }
        if (expiresAt < 0) {
            throw IllegalArgumentException("memory expiry must be zero or a Unix timestamp")
        }
        this.kind = kind
        this.scope = scope
        this.content = content.trimAscii()
        this.context = context.trimAscii()
        this.source = source.trimAscii()
        this.importancePermille = memoryV3ClampPermille(importancePermille)
        this.expiresAt = expiresAt
    }
}

public class MemoryV3Record {
    public let id: String
    public let kind: MemoryKind
    public let scope: MemoryScope
    public let content: String
    public let context: String
    public let source: String
    public let importancePermille: Int64
    public let status: MemoryStatus
    public let expiresAt: Int64
    public let correctionOf: String
    public let replacementId: String
    public let conflictIds: Array<String>
    public let conflictReason: String
    public let deletionReason: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let deletedAt: Int64
    public let revision: Int64

    public init(
        id: String,
        kind: MemoryKind,
        scope: MemoryScope,
        content: String,
        context: String,
        source: String,
        importancePermille: Int64,
        status: MemoryStatus,
        expiresAt: Int64,
        correctionOf: String,
        replacementId: String,
        conflictIds: Array<String>,
        conflictReason: String,
        deletionReason: String,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64,
        revision: Int64
    ) {
        this.id = id
        this.kind = kind
        this.scope = scope
        this.content = content
        this.context = context
        this.source = source
        this.importancePermille = importancePermille
        this.status = status
        this.expiresAt = expiresAt
        this.correctionOf = correctionOf
        this.replacementId = replacementId
        this.conflictIds = conflictIds
        this.conflictReason = conflictReason
        this.deletionReason = deletionReason
        this.createdAt = createdAt
        this.updatedAt = updatedAt
        this.deletedAt = deletedAt
        this.revision = revision
    }

    public func effectiveStatus(nowMillis!: Int64 = 0): MemoryStatus {
        let now = if (nowMillis <= 0) { memoryV3NowMillis() } else { nowMillis }
        if (status == MemoryStatus.Active && expiresAt > 0 && expiresAt <= now) {
            MemoryStatus.Expired
        } else {
            status
        }
    }

    public func isRetrievable(nowMillis!: Int64 = 0): Bool {
        effectiveStatus(nowMillis: nowMillis) == MemoryStatus.Active
    }
}

public class MemoryV3SearchOptions {
    public let scope: ?MemoryScope
    public let kinds: Array<MemoryKind>
    public let limit: Int64
    public let semanticEnabled: Bool
    public let lexicalWeightPermille: Int64
    public let semanticWeightPermille: Int64
    public let nowMillis: Int64

    public init(
        scope!: ?MemoryScope = None,
        kinds!: Array<MemoryKind> = [],
        limit!: Int64 = 10,
        semanticEnabled!: Bool = true,
        lexicalWeightPermille!: Int64 = 650,
        semanticWeightPermille!: Int64 = 350,
        nowMillis!: Int64 = 0
    ) {
        if (limit < 1 || limit > 100) {
            throw IllegalArgumentException("memory search limit must be between 1 and 100")
        }
        if (lexicalWeightPermille < 0 || semanticWeightPermille < 0 ||
            lexicalWeightPermille + semanticWeightPermille != 1000) {
            throw IllegalArgumentException("memory search weights must be non-negative and sum to 1000")
        }
        this.scope = scope
        this.kinds = kinds
        this.limit = limit
        this.semanticEnabled = semanticEnabled
        this.lexicalWeightPermille = lexicalWeightPermille
        this.semanticWeightPermille = semanticWeightPermille
        this.nowMillis = nowMillis
    }
}

public class MemoryV3SearchHit {
    public let memory: MemoryV3Record
    public let scorePermille: Int64
    public let lexicalRank: Int64
    public let semanticRank: Int64

    public init(
        memory: MemoryV3Record,
        scorePermille: Int64,
        lexicalRank!: Int64 = 0,
        semanticRank!: Int64 = 0
    ) {
        this.memory = memory
        this.scorePermille = scorePermille
        this.lexicalRank = lexicalRank
        this.semanticRank = semanticRank
    }
}

public class MemoryV3SearchResult {
    public let hits: Array<MemoryV3SearchHit>
    public let strategy: MemorySearchStrategy
    public let embeddingFallback: Bool

    public init(
        hits: Array<MemoryV3SearchHit>,
        strategy: MemorySearchStrategy,
        embeddingFallback: Bool
    ) {
        this.hits = hits
        this.strategy = strategy
        this.embeddingFallback = embeddingFallback
    }
}

// Implementations may use a local model, a provider API, or a prebuilt index.
// The repository treats this capability as optional and never makes durable
// memory unavailable merely because embedding generation failed.
public interface MemoryEmbeddingPort {
    func embed(text: String): Result<Array<Float64>>
}

class MemoryV3LexicalEntry {
    let memory: MemoryV3Record
    let score: Int64

    init(memory: MemoryV3Record, score: Int64) {
        this.memory = memory
        this.score = score
    }
}

class MemoryV3SemanticEntry {
    let memory: MemoryV3Record
    let score: Float64

    init(memory: MemoryV3Record, score: Float64) {
        this.memory = memory
        this.score = score
    }
}

// Every mutation appends a complete record state to events.jsonl. Replay keeps
// the last revision per id while history remains available for audit,
// correction, deletion, and conflict diagnosis.
public class MemoryV3Repository {
    private let root: String
    private let path: String
    private let database: ?SqliteDatabase
    private let embedding: ?MemoryEmbeddingPort
    private let lock = Mutex()
    private var idCounter: Int64 = 0

    public init(
        stateRoot: String,
        embedding!: ?MemoryEmbeddingPort = None
    ) {
        this.root = stateRoot + "/memory-v3"
        this.path = this.root + "/events.jsonl"
        this.database = None
        this.embedding = embedding
        ensureDirectory(this.root)
    }

    public init(
        database: SqliteDatabase,
        embedding!: ?MemoryEmbeddingPort = None
    ) {
        this.root = ""
        this.path = ""
        this.database = Some(database)
        this.embedding = embedding
    }

    public func retain(draft: MemoryV3Draft): Result<MemoryV3Record> {
        withLock({=>
            let history = match (loadHistory()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3Record>.Err(error)
            }
            let current = memoryV3Current(history)
            let now = memoryV3NowMillis()
            let record = MemoryV3Record(
                nextId(current, now),
                draft.kind,
                draft.scope,
                draft.content,
                draft.context,
                draft.source,
                draft.importancePermille,
                MemoryStatus.Active,
                draft.expiresAt,
                "",
                "",
                [],
                "",
                "",
                now,
                now,
                0,
                1
            )
            match (appendStates("retain", [record])) {
                case Result.Ok(_) => Result.Ok(record)
                case Result.Err(error) => Result<MemoryV3Record>.Err(error)
            }
        })
    }

    public func correct(
        id: String,
        replacement: MemoryV3Draft
    ): Result<MemoryV3Record> {
        withLock({=>
            let history = match (loadHistory()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3Record>.Err(error)
            }
            let current = memoryV3Current(history)
            let target = match (memoryV3Find(current, id)) {
                case Some(value) => value
                case None => return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.not_found",
                    "memory does not exist"
                )
            }
            if (target.status == MemoryStatus.Deleted || target.status == MemoryStatus.Corrected) {
                return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.Conflict,
                    "memory_v3.not_correctable",
                    "deleted or corrected memory cannot be corrected again"
                )
            }
            let now = memoryV3NowMillis()
            let replacementId = nextId(current, now)
            let corrected = memoryV3Copy(
                target,
                status: MemoryStatus.Corrected,
                replacementId: replacementId,
                updatedAt: now,
                revision: target.revision + 1
            )
            let created = MemoryV3Record(
                replacementId,
                replacement.kind,
                replacement.scope,
                replacement.content,
                replacement.context,
                replacement.source,
                replacement.importancePermille,
                MemoryStatus.Active,
                replacement.expiresAt,
                target.id,
                "",
                [],
                "",
                "",
                now,
                now,
                0,
                1
            )
            match (appendStates("correct", [corrected, created])) {
                case Result.Ok(_) => Result.Ok(created)
                case Result.Err(error) => Result<MemoryV3Record>.Err(error)
            }
        })
    }

    public func delete(id: String, reason!: String = ""): Result<MemoryV3Record> {
        withLock({=>
            let current = match (loadCurrent()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3Record>.Err(error)
            }
            let target = match (memoryV3Find(current, id)) {
                case Some(value) => value
                case None => return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.not_found",
                    "memory does not exist"
                )
            }
            if (target.status == MemoryStatus.Deleted) {
                return Result.Ok(target)
            }
            let now = memoryV3NowMillis()
            let deleted = memoryV3Copy(
                target,
                status: MemoryStatus.Deleted,
                deletionReason: reason.trimAscii(),
                updatedAt: now,
                deletedAt: now,
                revision: target.revision + 1
            )
            match (appendStates("delete", [deleted])) {
                case Result.Ok(_) => Result.Ok(deleted)
                case Result.Err(error) => Result<MemoryV3Record>.Err(error)
            }
        })
    }

    public func markConflict(
        ids: Array<String>,
        reason: String
    ): Result<Array<MemoryV3Record>> {
        if (ids.size < 2 || reason.trimAscii() == "") {
            return memoryV3Error<Array<MemoryV3Record>>(
                AgentErrorKind.InvalidInput,
                "memory_v3.conflict_invalid",
                "a memory conflict requires at least two ids and a reason"
            )
        }
        if (memoryV3HasDuplicateStrings(ids)) {
            return memoryV3Error<Array<MemoryV3Record>>(
                AgentErrorKind.InvalidInput,
                "memory_v3.conflict_duplicate",
                "memory conflict ids must be unique"
            )
        }
        withLock({=>
            let current = match (loadCurrent()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
            }
            let now = memoryV3NowMillis()
            let updates = ArrayList<MemoryV3Record>()
            for (id in ids) {
                let target = match (memoryV3Find(current, id)) {
                    case Some(value) => value
                    case None => return memoryV3Error<Array<MemoryV3Record>>(
                        AgentErrorKind.InvalidInput,
                        "memory_v3.conflict_not_found",
                        "conflicting memory does not exist: " + id
                    )
                }
                if (target.status != MemoryStatus.Active) {
                    return memoryV3Error<Array<MemoryV3Record>>(
                        AgentErrorKind.Conflict,
                        "memory_v3.conflict_state",
                        "only active memories can enter a conflict"
                    )
                }
                updates.add(memoryV3Copy(
                    target,
                    status: MemoryStatus.Conflicted,
                    conflictIds: ids,
                    conflictReason: reason.trimAscii(),
                    updatedAt: now,
                    revision: target.revision + 1
                ))
            }
            match (appendStates("conflict", updates.toArray())) {
                case Result.Ok(_) => Result.Ok(updates.toArray())
                case Result.Err(error) => Result<Array<MemoryV3Record>>.Err(error)
            }
        })
    }

    public func resolveConflict(winnerId: String): Result<MemoryV3Record> {
        withLock({=>
            let current = match (loadCurrent()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3Record>.Err(error)
            }
            let winner = match (memoryV3Find(current, winnerId)) {
                case Some(value) => value
                case None => return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.conflict_not_found",
                    "conflict winner does not exist"
                )
            }
            if (winner.status != MemoryStatus.Conflicted || winner.conflictIds.size < 2) {
                return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.Conflict,
                    "memory_v3.not_conflicted",
                    "memory is not part of an unresolved conflict"
                )
            }
            let now = memoryV3NowMillis()
            let updates = ArrayList<MemoryV3Record>()
            let resolvedWinner = memoryV3Copy(
                winner,
                status: MemoryStatus.Active,
                conflictIds: [],
                conflictReason: "",
                updatedAt: now,
                revision: winner.revision + 1
            )
            updates.add(resolvedWinner)
            for (id in winner.conflictIds where id != winner.id) {
                let loser = match (memoryV3Find(current, id)) {
                    case Some(value) => value
                    case None => return memoryV3Error<MemoryV3Record>(
                        AgentErrorKind.RecoveryRequired,
                        "memory_v3.conflict_incomplete",
                        "conflict journal is missing member " + id
                    )
                }
                if (loser.status != MemoryStatus.Conflicted) {
                    return memoryV3Error<MemoryV3Record>(
                        AgentErrorKind.Conflict,
                        "memory_v3.conflict_diverged",
                        "conflict members no longer share the same state"
                    )
                }
                updates.add(memoryV3Copy(
                    loser,
                    status: MemoryStatus.Corrected,
                    replacementId: winner.id,
                    conflictIds: [],
                    conflictReason: "",
                    updatedAt: now,
                    revision: loser.revision + 1
                ))
            }
            match (appendStates("resolve_conflict", updates.toArray())) {
                case Result.Ok(_) => Result.Ok(resolvedWinner)
                case Result.Err(error) => Result<MemoryV3Record>.Err(error)
            }
        })
    }

    public func get(
        id: String,
        nowMillis!: Int64 = 0
    ): Result<?MemoryV3Record> {
        withLock({=>
            match (loadCurrent()) {
                case Result.Ok(current) =>
                    match (memoryV3Find(current, id)) {
                        case Some(record) => Result.Ok(Some(memoryV3ProjectExpiry(record, nowMillis)))
                        case None => Result.Ok(None)
                    }
                case Result.Err(error) => Result<?MemoryV3Record>.Err(error)
            }
        })
    }

    public func list(
        includeInactive!: Bool = false,
        nowMillis!: Int64 = 0
    ): Result<Array<MemoryV3Record>> {
        withLock({=>
            let current = match (loadCurrent()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
            }
            let output = ArrayList<MemoryV3Record>()
            for (record in current) {
                let projected = memoryV3ProjectExpiry(record, nowMillis)
                if (includeInactive || projected.status == MemoryStatus.Active) {
                    output.add(projected)
                }
            }
            Result.Ok(output.toArray())
        })
    }

    public func history(id: String): Result<Array<MemoryV3Record>> {
        withLock({=>
            match (loadHistory()) {
                case Result.Ok(history) =>
                    let result = ArrayList<MemoryV3Record>()
                    for (record in history where record.id == id) {
                        result.add(record)
                    }
                    Result.Ok(result.toArray())
                case Result.Err(error) => Result<Array<MemoryV3Record>>.Err(error)
            }
        })
    }

    public func eventCount(): Result<Int64> {
        withLock({=>
            match (loadHistory()) {
                case Result.Ok(history) => Result.Ok(history.size)
                case Result.Err(error) => Result<Int64>.Err(error)
            }
        })
    }

    public func search(
        query: String,
        options!: MemoryV3SearchOptions = MemoryV3SearchOptions()
    ): Result<MemoryV3SearchResult> {
        let normalized = query.trimAscii().toAsciiLower()
        if (normalized == "") {
            return memoryV3Error<MemoryV3SearchResult>(
                AgentErrorKind.InvalidInput,
                "memory_v3.query_empty",
                "memory search query must not be empty"
            )
        }
        withLock({=>
            let current = match (loadCurrent()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3SearchResult>.Err(error)
            }
            let now = if (options.nowMillis <= 0) {
                memoryV3NowMillis()
            } else {
                options.nowMillis
            }
            let candidates = ArrayList<MemoryV3Record>()
            for (record in current where
                 record.isRetrievable(nowMillis: now) &&
                 memoryV3MatchesScope(record.scope, options.scope) &&
                 memoryV3MatchesKind(record.kind, options.kinds)) {
                candidates.add(record)
            }
            let lexical = memoryV3LexicalRanking(candidates.toArray(), normalized)
            if (!options.semanticEnabled) {
                return Result.Ok(memoryV3LexicalResult(
                    lexical,
                    options.limit,
                    MemorySearchStrategy.Lexical,
                    false
                ))
            }
            match (embedding) {
                case Some(port) => memoryV3HybridResult(
                    query.trimAscii(),
                    candidates.toArray(),
                    lexical,
                    options,
                    port
                )
                case None => Result.Ok(memoryV3LexicalResult(
                    lexical,
                    options.limit,
                    MemorySearchStrategy.Lexical,
                    false
                ))
            }
        })
    }

    private func loadCurrent(): Result<Array<MemoryV3Record>> {
        match (loadHistory()) {
            case Result.Ok(history) => Result.Ok(memoryV3Current(history))
            case Result.Err(error) => Result<Array<MemoryV3Record>>.Err(error)
        }
    }

    private func loadHistory(): Result<Array<MemoryV3Record>> {
        match (database) {
            case Some(store) => try {
                let result = ArrayList<MemoryV3Record>()
                for (row in store.query(
                    "SELECT payload FROM memory_events ORDER BY id"
                )) {
                    let event = match (decodeAgentValue(row.required(0), maxBytes: 67108864)) {
                        case Result.Ok(value) => value
                        case Result.Err(error) => return Result.Err(error)
                    }
                    match (memoryV3DecodeEvent(event)) {
                        case Result.Ok(value) => result.add(value)
                        case Result.Err(error) => return Result.Err(error)
                    }
                }
                return Result.Ok(result.toArray())
            } catch (error: Exception) {
                return memoryV3Error<Array<MemoryV3Record>>(
                    AgentErrorKind.Internal, "memory_v3.sqlite_read", error.message
                )
            }
            case None => ()
        }
        if (!exists(Path(path))) { return Result.Ok([]) }
        let source = match (readTextResult(path, "memory_v3.read")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
        }
        let result = ArrayList<MemoryV3Record>()
        for (line in source.split("\n") where line.trimAscii() != "") {
            let event = match (decodeAgentValue(line, maxBytes: 67108864)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
            }
            let record = match (memoryV3DecodeEvent(event)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
            }
            result.add(record)
        }
        Result.Ok(result.toArray())
    }

    private func appendStates(
        operation: String,
        records: Array<MemoryV3Record>
    ): Result<Unit> {
        match (database) {
            case Some(store) => try {
                store.transaction<Unit>({ transaction =>
                    for (record in records) {
                        let payload = encodeAgentValue(memoryV3EventValue(operation, record))
                        transaction.execute(
                            "INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(" +
                                sqliteText(record.id) + "," + record.revision.toString() + "," +
                                sqliteText(operation) + "," + sqliteText(payload) + "," +
                                memoryV3NowMillis().toString() + ")"
                        )
                        transaction.execute(
                            "INSERT OR REPLACE INTO memories(id,thread_id,kind,payload,revision) VALUES(" +
                                sqliteText(record.id) + ",NULL," +
                                sqliteText(memoryV3KindName(record.kind)) + "," +
                                sqliteText(payload) + "," + record.revision.toString() + ")"
                        )
                    }
                })
                return Result.Ok(())
            } catch (error: Exception) {
                return memoryV3Error<Unit>(
                    AgentErrorKind.Internal, "memory_v3.sqlite_append", error.message
                )
            }
            case None => ()
        }
        var body = ""
        for (record in records) {
            body += encodeAgentValue(memoryV3EventValue(operation, record)) + "\n"
        }
        try {
            File.appendTo(path, body.toArray())
            Result.Ok(())
        } catch (error: Exception) {
            memoryV3Error<Unit>(
                AgentErrorKind.Internal,
                "memory_v3.append_failed",
                error.message
            )
        }
    }

    private func nextId(
        current: Array<MemoryV3Record>,
        now: Int64
    ): String {
        while (true) {
            idCounter += 1
            let candidate = "memv3-" + now.toString() + "-" + idCounter.toString()
            if (memoryV3Find(current, candidate).isNone()) { return candidate }
        }
        ""
    }

    private func withLock<T>(action: () -> Result<T>): Result<T> {
        lock.lock()
        try { action() } finally { lock.unlock() }
    }
}

func memoryV3HybridResult(
    query: String,
    candidates: Array<MemoryV3Record>,
    lexical: Array<MemoryV3LexicalEntry>,
    options: MemoryV3SearchOptions,
    port: MemoryEmbeddingPort
): Result<MemoryV3SearchResult> {
    let queryVector = match (port.embed(query)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return Result.Ok(memoryV3LexicalResult(
            lexical,
            options.limit,
            MemorySearchStrategy.LexicalFallback,
            true
        ))
    }
    if (!memoryV3ValidVector(queryVector)) {
        return Result.Ok(memoryV3LexicalResult(
            lexical,
            options.limit,
            MemorySearchStrategy.LexicalFallback,
            true
        ))
    }
    let semantic = ArrayList<MemoryV3SemanticEntry>()
    for (record in candidates) {
        let vector = match (port.embed(record.content + "\n" + record.context)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return Result.Ok(memoryV3LexicalResult(
                lexical,
                options.limit,
                MemorySearchStrategy.LexicalFallback,
                true
            ))
        }
        if (!memoryV3ValidVector(vector) || vector.size != queryVector.size) {
            return Result.Ok(memoryV3LexicalResult(
                lexical,
                options.limit,
                MemorySearchStrategy.LexicalFallback,
                true
            ))
        }
        semantic.add(MemoryV3SemanticEntry(
            record,
            memoryV3Dot(queryVector, vector)
        ))
        var index = semantic.size - 1
        while (index > 0 && memoryV3SemanticBefore(semantic[index], semantic[index - 1])) {
            let previous = semantic[index - 1]
            semantic[index - 1] = semantic[index]
            semantic[index] = previous
            index -= 1
        }
    }
    let combined = ArrayList<MemoryV3SearchHit>()
    for (record in candidates) {
        let lexicalRank = memoryV3LexicalRank(lexical, record.id)
        let semanticRank = memoryV3SemanticRank(semantic, record.id)
        let score = memoryV3RankContribution(
            lexicalRank,
            options.lexicalWeightPermille
        ) + memoryV3RankContribution(
            semanticRank,
            options.semanticWeightPermille
        )
        if (score > 0) {
            memoryV3InsertHit(combined, MemoryV3SearchHit(
                record,
                score,
                lexicalRank: lexicalRank,
                semanticRank: semanticRank
            ))
        }
    }
    Result.Ok(MemoryV3SearchResult(
        memoryV3LimitHits(combined, options.limit),
        MemorySearchStrategy.Hybrid,
        false
    ))
}

func memoryV3LexicalResult(
    lexical: Array<MemoryV3LexicalEntry>,
    limit: Int64,
    strategy: MemorySearchStrategy,
    fallback: Bool
): MemoryV3SearchResult {
    let hits = ArrayList<MemoryV3SearchHit>()
    var index: Int64 = 0
    while (index < lexical.size && index < limit) {
        hits.add(MemoryV3SearchHit(
            lexical[index].memory,
            min(1000, lexical[index].score),
            lexicalRank: index + 1
        ))
        index += 1
    }
    MemoryV3SearchResult(hits.toArray(), strategy, fallback)
}

func memoryV3LexicalRanking(
    candidates: Array<MemoryV3Record>,
    query: String
): Array<MemoryV3LexicalEntry> {
    let values = ArrayList<MemoryV3LexicalEntry>()
    for (record in candidates) {
        let score = memoryV3LexicalScore(record, query)
        if (score <= 0) { continue }
        values.add(MemoryV3LexicalEntry(record, score))
        var index = values.size - 1
        while (index > 0 && memoryV3LexicalBefore(values[index], values[index - 1])) {
            let previous = values[index - 1]
            values[index - 1] = values[index]
            values[index] = previous
            index -= 1
        }
    }
    values.toArray()
}

func memoryV3LexicalScore(record: MemoryV3Record, query: String): Int64 {
    let content = record.content.toAsciiLower()
    let context = record.context.toAsciiLower()
    var score: Int64 = 0
    if (content.contains(query)) { score += 650 }
    for (raw in query.replace("\t", " ").split(" ")) {
        let token = raw.trimAscii()
        if (token == "") { continue }
        if (content.contains(token)) {
            score += 100
        } else if (context.contains(token)) {
            score += 35
        }
    }
    if (score == 0) { return 0 }
    score + record.importancePermille / 10
}

func memoryV3LexicalBefore(left: MemoryV3LexicalEntry, right: MemoryV3LexicalEntry): Bool {
    if (left.score != right.score) { return left.score > right.score }
    if (left.memory.updatedAt != right.memory.updatedAt) {
        return left.memory.updatedAt > right.memory.updatedAt
    }
    left.memory.id < right.memory.id
}

func memoryV3SemanticBefore(left: MemoryV3SemanticEntry, right: MemoryV3SemanticEntry): Bool {
    if (left.score != right.score) { return left.score > right.score }
    left.memory.id < right.memory.id
}

func memoryV3InsertHit(
    values: ArrayList<MemoryV3SearchHit>,
    value: MemoryV3SearchHit
): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 && memoryV3HitBefore(values[index], values[index - 1])) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index -= 1
    }
}

func memoryV3HitBefore(left: MemoryV3SearchHit, right: MemoryV3SearchHit): Bool {
    if (left.scorePermille != right.scorePermille) {
        return left.scorePermille > right.scorePermille
    }
    left.memory.id < right.memory.id
}

func memoryV3LimitHits(values: ArrayList<MemoryV3SearchHit>, limit: Int64): Array<MemoryV3SearchHit> {
    let result = ArrayList<MemoryV3SearchHit>()
    var index: Int64 = 0
    while (index < values.size && index < limit) {
        result.add(values[index])
        index += 1
    }
    result.toArray()
}

func memoryV3LexicalRank(values: Array<MemoryV3LexicalEntry>, id: String): Int64 {
    for (index in 0..values.size where values[index].memory.id == id) {
        return index + 1
    }
    0
}

func memoryV3SemanticRank(values: ArrayList<MemoryV3SemanticEntry>, id: String): Int64 {
    for (index in 0..values.size where values[index].memory.id == id) {
        return index + 1
    }
    0
}

func memoryV3RankContribution(rank: Int64, weightPermille: Int64): Int64 {
    if (rank <= 0 || weightPermille <= 0) { 0 } else {
        weightPermille * 60 / (60 + rank)
    }
}

func memoryV3ValidVector(value: Array<Float64>): Bool {
    if (value.isEmpty()) { return false }
    for (item in value) {
        if (item != item) { return false }
    }
    true
}

func memoryV3Dot(left: Array<Float64>, right: Array<Float64>): Float64 {
    var result: Float64 = 0.0
    for (index in 0..left.size) {
        result += left[index] * right[index]
    }
    result
}

func memoryV3MatchesScope(scope: MemoryScope, filter: ?MemoryScope): Bool {
    match (filter) {
        case Some(value) => scope.kind == value.kind && scope.key == value.key
        case None => true
    }
}

func memoryV3MatchesKind(kind: MemoryKind, kinds: Array<MemoryKind>): Bool {
    if (kinds.isEmpty()) { return true }
    for (value in kinds where value == kind) { return true }
    false
}

func memoryV3ProjectExpiry(record: MemoryV3Record, nowMillis: Int64): MemoryV3Record {
    if (record.effectiveStatus(nowMillis: nowMillis) != MemoryStatus.Expired) {
        return record
    }
    memoryV3Copy(record, status: MemoryStatus.Expired)
}

func memoryV3Current(history: Array<MemoryV3Record>): Array<MemoryV3Record> {
    let current = ArrayList<MemoryV3Record>()
    for (record in history) {
        var replaced = false
        for (index in 0..current.size where current[index].id == record.id) {
            current[index] = record
            replaced = true
            break
        }
        if (!replaced) { current.add(record) }
    }
    current.toArray()
}

func memoryV3Find(records: Array<MemoryV3Record>, id: String): ?MemoryV3Record {
    for (record in records where record.id == id) { return Some(record) }
    None
}

func memoryV3HasDuplicateStrings(values: Array<String>): Bool {
    for (index in 0..values.size) {
        for (other in index + 1..values.size where values[index] == values[other]) {
            return true
        }
    }
    false
}

func memoryV3Copy(
    record: MemoryV3Record,
    status!: MemoryStatus = record.status,
    replacementId!: String = record.replacementId,
    conflictIds!: Array<String> = record.conflictIds,
    conflictReason!: String = record.conflictReason,
    deletionReason!: String = record.deletionReason,
    updatedAt!: Int64 = record.updatedAt,
    deletedAt!: Int64 = record.deletedAt,
    revision!: Int64 = record.revision
): MemoryV3Record {
    MemoryV3Record(
        record.id,
        record.kind,
        record.scope,
        record.content,
        record.context,
        record.source,
        record.importancePermille,
        status,
        record.expiresAt,
        record.correctionOf,
        replacementId,
        conflictIds,
        conflictReason,
        deletionReason,
        record.createdAt,
        updatedAt,
        deletedAt,
        revision
    )
}

func memoryV3EventValue(operation: String, record: MemoryV3Record): AgentValue {
    objectValue([
        ValueField("version", integerValue(3)),
        ValueField("operation", textValue(operation)),
        ValueField("record", memoryV3RecordValue(record))
    ])
}

func memoryV3RecordValue(record: MemoryV3Record): AgentValue {
    let conflicts = ArrayList<AgentValue>()
    for (id in record.conflictIds) { conflicts.add(textValue(id)) }
    objectValue([
        ValueField("id", textValue(record.id)),
        ValueField("kind", textValue(memoryV3KindName(record.kind))),
        ValueField("scopeKind", textValue(memoryV3ScopeName(record.scope.kind))),
        ValueField("scopeKey", textValue(record.scope.key)),
        ValueField("content", textValue(record.content)),
        ValueField("context", textValue(record.context)),
        ValueField("source", textValue(record.source)),
        ValueField("importancePermille", integerValue(record.importancePermille)),
        ValueField("status", textValue(memoryV3StatusName(record.status))),
        ValueField("expiresAt", integerValue(record.expiresAt)),
        ValueField("correctionOf", textValue(record.correctionOf)),
        ValueField("replacementId", textValue(record.replacementId)),
        ValueField("conflictIds", listValue(conflicts.toArray())),
        ValueField("conflictReason", textValue(record.conflictReason)),
        ValueField("deletionReason", textValue(record.deletionReason)),
        ValueField("createdAt", integerValue(record.createdAt)),
        ValueField("updatedAt", integerValue(record.updatedAt)),
        ValueField("deletedAt", integerValue(record.deletedAt)),
        ValueField("revision", integerValue(record.revision))
    ])
}

func memoryV3DecodeEvent(value: AgentValue): Result<MemoryV3Record> {
    if (integerOr(value, "version") != 3 || textOr(value, "operation") == "") {
        return memoryV3Error<MemoryV3Record>(
            AgentErrorKind.RecoveryRequired,
            "memory_v3.event_invalid",
            "memory event version or operation is invalid"
        )
    }
    let item = match (value.field("record")) {
        case Some(record) => record
        case None => return memoryV3Error<MemoryV3Record>(
            AgentErrorKind.RecoveryRequired,
            "memory_v3.record_missing",
            "memory event has no record"
        )
    }
    let id = textOr(item, "id")
    let content = textOr(item, "content")
    let kind = memoryV3ParseKind(textOr(item, "kind"))
    let scope = memoryV3ParseScope(textOr(item, "scopeKind"), textOr(item, "scopeKey"))
    let status = memoryV3ParseStatus(textOr(item, "status"))
    if (id == "" || content == "" || kind.isNone() || scope.isNone() || status.isNone()) {
        return memoryV3Error<MemoryV3Record>(
            AgentErrorKind.RecoveryRequired,
            "memory_v3.record_invalid",
            "memory event record is incomplete"
        )
    }
    let conflicts = ArrayList<String>()
    match (item.field("conflictIds")) {
        case Some(list) =>
            for (entry in list.items where entry.kind == ValueKind.Text) {
                conflicts.add(entry.text)
            }
        case None => ()
    }
    Result.Ok(MemoryV3Record(
        id,
        kind.getOrThrow(),
        scope.getOrThrow(),
        content,
        textOr(item, "context"),
        textOr(item, "source"),
        memoryV3ClampPermille(integerOr(item, "importancePermille")),
        status.getOrThrow(),
        integerOr(item, "expiresAt"),
        textOr(item, "correctionOf"),
        textOr(item, "replacementId"),
        conflicts.toArray(),
        textOr(item, "conflictReason"),
        textOr(item, "deletionReason"),
        integerOr(item, "createdAt"),
        integerOr(item, "updatedAt"),
        integerOr(item, "deletedAt"),
        integerOr(item, "revision")
    ))
}

func memoryV3KindName(value: MemoryKind): String {
    match (value) {
        case MemoryKind.Preference => "preference"
        case MemoryKind.ProjectFact => "project_fact"
        case MemoryKind.Decision => "decision"
        case MemoryKind.Constraint => "constraint"
        case MemoryKind.Observation => "observation"
    }
}

func memoryV3ScopeName(value: MemoryScopeKind): String {
    match (value) {
        case MemoryScopeKind.Global => "global"
        case MemoryScopeKind.User => "user"
        case MemoryScopeKind.Workspace => "workspace"
        case MemoryScopeKind.Session => "session"
    }
}

func memoryV3StatusName(value: MemoryStatus): String {
    match (value) {
        case MemoryStatus.Active => "active"
        case MemoryStatus.Corrected => "corrected"
        case MemoryStatus.Deleted => "deleted"
        case MemoryStatus.Conflicted => "conflicted"
        case MemoryStatus.Expired => "expired"
    }
}

func memoryV3ParseKind(value: String): ?MemoryKind {
    match (value) {
        case "preference" => Some(MemoryKind.Preference)
        case "project_fact" => Some(MemoryKind.ProjectFact)
        case "decision" => Some(MemoryKind.Decision)
        case "constraint" => Some(MemoryKind.Constraint)
        case "observation" => Some(MemoryKind.Observation)
        case _ => None
    }
}

func memoryV3ParseScope(kind: String, key: String): ?MemoryScope {
    match (kind) {
        case "global" => if (key == "") { Some(MemoryScope(MemoryScopeKind.Global)) } else { None }
        case "user" => if (key == "") { None } else { Some(MemoryScope(MemoryScopeKind.User, key: key)) }
        case "workspace" => if (key == "") { None } else { Some(MemoryScope(MemoryScopeKind.Workspace, key: key)) }
        case "session" => if (key == "") { None } else { Some(MemoryScope(MemoryScopeKind.Session, key: key)) }
        case _ => None
    }
}

func memoryV3ParseStatus(value: String): ?MemoryStatus {
    match (value) {
        case "active" => Some(MemoryStatus.Active)
        case "corrected" => Some(MemoryStatus.Corrected)
        case "deleted" => Some(MemoryStatus.Deleted)
        case "conflicted" => Some(MemoryStatus.Conflicted)
        case "expired" => Some(MemoryStatus.Expired)
        case _ => None
    }
}

func memoryV3ClampPermille(value: Int64): Int64 {
    if (value < 0) { 0 } else if (value > 1000) { 1000 } else { value }
}

func memoryV3NowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func memoryV3Error<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}
