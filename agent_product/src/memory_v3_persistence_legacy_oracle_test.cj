package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_store.*
import std.collection.*
import std.convert.*
import std.overflow.*
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
        this.importancePermille = legacyOracle_memoryV3ClampPermille(importancePermille)
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
        let now = if (nowMillis <= 0) { legacyOracle_memoryV3NowMillis() } else { nowMillis }
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

// Ranking is supplied by an explicitly selected policy. These data-only
// references carry no storage or visibility authority.
public interface MemoryRetrievalPolicy {
    func retrieve(query: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult>
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
        legacyOracle_ensureDirectory(this.root)
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
            let current = legacyOracle_memoryV3Current(history)
            let now = legacyOracle_memoryV3NowMillis()
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
        replacement: MemoryV3Draft,
        expectedRevision!: Int64 = 0
    ): Result<MemoryV3Record> {
        withLock({=>
            let history = match (loadHistory()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3Record>.Err(error)
            }
            let current = legacyOracle_memoryV3Current(history)
            let target = match (legacyOracle_memoryV3Find(current, id)) {
                case Some(value) => value
                case None => return legacyOracle_memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.not_found",
                    "memory does not exist"
                )
            }
            if (expectedRevision > 0 && target.revision != expectedRevision) {
                return legacyOracle_memoryV3Error<MemoryV3Record>(AgentErrorKind.Conflict,
                    "memory_v3.revision_changed", "memory changed after its policy proposal was prepared")
            }
            if (target.status == MemoryStatus.Deleted || target.status == MemoryStatus.Corrected) {
                return legacyOracle_memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.Conflict,
                    "memory_v3.not_correctable",
                    "deleted or corrected memory cannot be corrected again"
                )
            }
            let now = legacyOracle_memoryV3NowMillis()
            let replacementId = nextId(current, now)
            let corrected = legacyOracle_memoryV3Copy(
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
            match (appendStates("correct", [corrected, created], expected: if (expectedRevision > 0) { Some(target) } else { None })) {
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
            let target = match (legacyOracle_memoryV3Find(current, id)) {
                case Some(value) => value
                case None => return legacyOracle_memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.not_found",
                    "memory does not exist"
                )
            }
            if (target.status == MemoryStatus.Deleted) {
                return Result.Ok(target)
            }
            let now = legacyOracle_memoryV3NowMillis()
            let deleted = legacyOracle_memoryV3Copy(
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
            return legacyOracle_memoryV3Error<Array<MemoryV3Record>>(
                AgentErrorKind.InvalidInput,
                "memory_v3.conflict_invalid",
                "a memory conflict requires at least two ids and a reason"
            )
        }
        if (legacyOracle_memoryV3HasDuplicateStrings(ids)) {
            return legacyOracle_memoryV3Error<Array<MemoryV3Record>>(
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
            let now = legacyOracle_memoryV3NowMillis()
            let updates = ArrayList<MemoryV3Record>()
            for (id in ids) {
                let target = match (legacyOracle_memoryV3Find(current, id)) {
                    case Some(value) => value
                    case None => return legacyOracle_memoryV3Error<Array<MemoryV3Record>>(
                        AgentErrorKind.InvalidInput,
                        "memory_v3.conflict_not_found",
                        "conflicting memory does not exist: " + id
                    )
                }
                if (target.status != MemoryStatus.Active) {
                    return legacyOracle_memoryV3Error<Array<MemoryV3Record>>(
                        AgentErrorKind.Conflict,
                        "memory_v3.conflict_state",
                        "only active memories can enter a conflict"
                    )
                }
                updates.add(legacyOracle_memoryV3Copy(
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
            let winner = match (legacyOracle_memoryV3Find(current, winnerId)) {
                case Some(value) => value
                case None => return legacyOracle_memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.conflict_not_found",
                    "conflict winner does not exist"
                )
            }
            if (winner.status != MemoryStatus.Conflicted || winner.conflictIds.size < 2) {
                return legacyOracle_memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.Conflict,
                    "memory_v3.not_conflicted",
                    "memory is not part of an unresolved conflict"
                )
            }
            let now = legacyOracle_memoryV3NowMillis()
            let updates = ArrayList<MemoryV3Record>()
            let resolvedWinner = legacyOracle_memoryV3Copy(
                winner,
                status: MemoryStatus.Active,
                conflictIds: [],
                conflictReason: "",
                updatedAt: now,
                revision: winner.revision + 1
            )
            updates.add(resolvedWinner)
            for (id in winner.conflictIds where id != winner.id) {
                let loser = match (legacyOracle_memoryV3Find(current, id)) {
                    case Some(value) => value
                    case None => return legacyOracle_memoryV3Error<MemoryV3Record>(
                        AgentErrorKind.RecoveryRequired,
                        "memory_v3.conflict_incomplete",
                        "conflict journal is missing member " + id
                    )
                }
                if (loser.status != MemoryStatus.Conflicted) {
                    return legacyOracle_memoryV3Error<MemoryV3Record>(
                        AgentErrorKind.Conflict,
                        "memory_v3.conflict_diverged",
                        "conflict members no longer share the same state"
                    )
                }
                updates.add(legacyOracle_memoryV3Copy(
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
                    match (legacyOracle_memoryV3Find(current, id)) {
                        case Some(record) => Result.Ok(Some(legacyOracle_memoryV3ProjectExpiry(record, nowMillis)))
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
                let projected = legacyOracle_memoryV3ProjectExpiry(record, nowMillis)
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
        options!: MemoryV3SearchOptions = MemoryV3SearchOptions(),
        policy!: ?MemoryRetrievalPolicy = None
    ): Result<MemoryV3SearchResult> {
        if (query.trimAscii() == "") { return legacyOracle_memoryV3Error<MemoryV3SearchResult>(
            AgentErrorKind.InvalidInput, "memory_v3.query_empty", "memory search query must not be empty") }
        let selected = match (policy) {
            case Some(value) => value
            case None => return legacyOracle_memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.InvalidInput,
                "memory_v3.policy_required", "memory retrieval requires an explicitly selected policy")
        }
        // Freeze filtering options and records under the existing journal lock;
        // no callback or embedding I/O runs while holding that lock.
        let now = if (options.nowMillis <= 0) { legacyOracle_memoryV3NowMillis() } else { options.nowMillis }
        let frozenOptions = MemoryV3SearchOptions(scope: options.scope, kinds: options.kinds.clone(),
            limit: options.limit, semanticEnabled: options.semanticEnabled,
            lexicalWeightPermille: options.lexicalWeightPermille,
            semanticWeightPermille: options.semanticWeightPermille, nowMillis: now)
        let snapshot = match (captureSearch(frozenOptions)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        // A policy receives detached data. The validation copy below cannot be
        // changed through public Array fields in that callback.
        let callbackOptions = MemoryV3SearchOptions(scope: frozenOptions.scope, kinds: frozenOptions.kinds.clone(),
            limit: frozenOptions.limit, semanticEnabled: frozenOptions.semanticEnabled,
            lexicalWeightPermille: frozenOptions.lexicalWeightPermille,
            semanticWeightPermille: frozenOptions.semanticWeightPermille, nowMillis: frozenOptions.nowMillis)
        let proposed = match (selected.retrieve(query.trimAscii(),
            snapshot.map { record => legacyOracle_memoryV3Detached(record) }, callbackOptions, embedding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        return withLock({=>
            let current = match (captureSearchLocked(frozenOptions)) {
                case Result.Err(error) => return Result<MemoryV3SearchResult>.Err(error); case Result.Ok(value) => value }
            if (legacyOracle_memoryV3SnapshotDigest(current) != legacyOracle_memoryV3SnapshotDigest(snapshot)) {
                return legacyOracle_memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.Conflict,
                    "memory_v3.snapshot_changed", "authorized memory records changed while policy was running") }
            if (proposed.hits.size > frozenOptions.limit ||
                proposed.embeddingFallback != (proposed.strategy == MemorySearchStrategy.LexicalFallback)) {
                return legacyOracle_memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.InvalidInput,
                    "memory_v3.policy_result_invalid", "invalid policy result bounds") }
            let ids = HashSet<String>(); let hits = ArrayList<MemoryV3SearchHit>()
            for (hit in proposed.hits) {
                let original = legacyOracle_memoryV3Find(snapshot, hit.memory.id)
                if (ids.contains(hit.memory.id) || original.isNone() || hit.scorePermille < 0 || hit.scorePermille > 1000 ||
                    hit.lexicalRank < 0 || hit.lexicalRank > snapshot.size || hit.semanticRank < 0 || hit.semanticRank > snapshot.size) {
                    return legacyOracle_memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.InvalidInput,
                        "memory_v3.policy_result_invalid", "policy selected a foreign, duplicate, or invalid record") }
                let record = original.getOrThrow()
                let validationNow = if (options.nowMillis <= 0) { legacyOracle_memoryV3NowMillis() } else { now }
                if (record.revision != hit.memory.revision || !record.isRetrievable(nowMillis: validationNow)) {
                    return legacyOracle_memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.Conflict,
                        "memory_v3.snapshot_changed", "memory revision or expiry changed before consumption") }
                ids.add(record.id)
                hits.add(MemoryV3SearchHit(legacyOracle_memoryV3Detached(record), hit.scorePermille,
                    lexicalRank: hit.lexicalRank, semanticRank: hit.semanticRank))
            }
            Result.Ok(MemoryV3SearchResult(hits.toArray(), proposed.strategy, proposed.embeddingFallback))
        })
    }

    private func captureSearch(options: MemoryV3SearchOptions): Result<Array<MemoryV3Record>> {
        withLock({=> captureSearchLocked(options) })
    }
    private func captureSearchLocked(options: MemoryV3SearchOptions): Result<Array<MemoryV3Record>> {
        let current = match (loadCurrent()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let values = ArrayList<MemoryV3Record>()
        for (record in current where record.isRetrievable(nowMillis: options.nowMillis) &&
            legacyOracle_memoryV3MatchesScope(record.scope, options.scope) && legacyOracle_memoryV3MatchesKind(record.kind, options.kinds)) {
            values.add(legacyOracle_memoryV3Detached(record))
        }
        Result.Ok(values.toArray())
    }

    // Revalidate context/correction facts immediately before their consumer.
    // Ordering/ranking is deliberately absent from this data-integrity check.
    public func validateRecords(records: Array<MemoryV3Record>): Result<Unit> {
        withLock({=>
            let current = match (loadCurrent()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
            for (record in records) {
                let actual = legacyOracle_memoryV3Find(current, record.id)
                if (actual.isNone() || canonicalAgentValue(legacyOracle_memoryV3RecordValue(actual.getOrThrow())) !=
                    canonicalAgentValue(legacyOracle_memoryV3RecordValue(record))) {
                    return legacyOracle_memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.snapshot_changed", "memory fact changed") }
            }
            Result.Ok(())
        })
    }

    // Context text is consumed after retrieval and can outlive a record's
    // expiry without any durable revision change. Keep correction lifecycle
    // validation separate; only live, still-visible retrieval facts pass here.
    public func validateContextRecords(records: Array<MemoryV3Record>): Result<Unit> {
        withLock({=>
            let current = match (loadCurrent()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
            for (record in records) {
                let actual = legacyOracle_memoryV3Find(current, record.id)
                if (actual.isNone() || canonicalAgentValue(legacyOracle_memoryV3RecordValue(actual.getOrThrow())) !=
                    canonicalAgentValue(legacyOracle_memoryV3RecordValue(record))) {
                    return legacyOracle_memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.context_fact_expired_or_changed",
                        "memory context fact is no longer currently retrievable") }
            }
            let now = legacyOracle_memoryV3NowMillis()
            for (record in records where !record.isRetrievable(nowMillis: now)) {
                return legacyOracle_memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.context_fact_expired_or_changed",
                    "memory context fact expired before consumption") }
            Result.Ok(())
        })
    }

    private func loadCurrent(): Result<Array<MemoryV3Record>> {
        match (loadHistory()) {
            case Result.Ok(history) => Result.Ok(legacyOracle_memoryV3Current(history))
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
                    match (legacyOracle_memoryV3DecodeEvent(event)) {
                        case Result.Ok(value) => result.add(value)
                        case Result.Err(error) => return Result.Err(error)
                    }
                }
                return Result.Ok(result.toArray())
            } catch (error: Exception) {
                return legacyOracle_memoryV3Error<Array<MemoryV3Record>>(
                    AgentErrorKind.Internal, "memory_v3.sqlite_read", error.message
                )
            }
            case None => ()
        }
        if (!exists(Path(path))) { return Result.Ok([]) }
        let source = match (legacyOracle_memoryV3ReadTextResult(path, "memory_v3.read")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
        }
        let result = ArrayList<MemoryV3Record>()
        for (line in source.split("\n") where line.trimAscii() != "") {
            let event = match (decodeAgentValue(line, maxBytes: 67108864)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
            }
            let record = match (legacyOracle_memoryV3DecodeEvent(event)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<Array<MemoryV3Record>>.Err(error)
            }
            result.add(record)
        }
        Result.Ok(result.toArray())
    }

    private func appendStates(
        operation: String,
        records: Array<MemoryV3Record>,
        expected!: ?MemoryV3Record = None
    ): Result<Unit> {
        match (database) {
            case Some(store) => try {
                store.transaction<Unit>({ transaction =>
                    match (expected) { case Some(original) =>
                        let rows = transaction.query("SELECT payload,revision FROM memories WHERE id=?", [SqlParameter.Text(original.id)])
                        if (rows.size != 1 || rows[0].required(1) != original.revision.toString()) {
                            throw IllegalStateException("memory expected revision changed") }
                        let current = match (legacyOracle_memoryV3DecodeEvent(decodeAgentValue(rows[0].required(0), maxBytes: 67108864).value().getOrThrow())) {
                            case Result.Ok(value) => value; case Result.Err(_) => throw IllegalStateException("memory current record is invalid") }
                        if (canonicalAgentValue(legacyOracle_memoryV3RecordValue(current)) != canonicalAgentValue(legacyOracle_memoryV3RecordValue(original))) {
                            throw IllegalStateException("memory expected record changed") }
                        case None => () }
                    for (record in records) {
                        let payload = encodeAgentValue(legacyOracle_memoryV3EventValue(operation, record))
                        transaction.execute(
                            "INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(" +
                                sqliteText(record.id) + "," + record.revision.toString() + "," +
                                sqliteText(operation) + "," + sqliteText(payload) + "," +
                                legacyOracle_memoryV3NowMillis().toString() + ")"
                        )
                        transaction.execute(
                            "INSERT OR REPLACE INTO memories(id,thread_id,kind,payload,revision) VALUES(" +
                                sqliteText(record.id) + ",NULL," +
                                sqliteText(legacyOracle_memoryV3KindName(record.kind)) + "," +
                                sqliteText(payload) + "," + record.revision.toString() + ")"
                        )
                    }
                })
                return Result.Ok(())
            } catch (error: Exception) {
                return legacyOracle_memoryV3Error<Unit>(
                    AgentErrorKind.Internal, "memory_v3.sqlite_append", error.message
                )
            }
            case None => ()
        }
        var body = ""
        for (record in records) {
            body += encodeAgentValue(legacyOracle_memoryV3EventValue(operation, record)) + "\n"
        }
        try {
            File.appendTo(path, body.toArray())
            Result.Ok(())
        } catch (error: Exception) {
            legacyOracle_memoryV3Error<Unit>(
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
            if (legacyOracle_memoryV3Find(current, candidate).isNone()) { return candidate }
        }
        ""
    }

    private func withLock<T>(action: () -> Result<T>): Result<T> {
        lock.lock()
        try { action() } finally { lock.unlock() }
    }
}

func legacyOracle_memoryV3Detached(record: MemoryV3Record): MemoryV3Record {
    MemoryV3Record(record.id, record.kind, record.scope, record.content, record.context, record.source,
        record.importancePermille, record.status, record.expiresAt, record.correctionOf, record.replacementId,
        record.conflictIds.clone(), record.conflictReason, record.deletionReason, record.createdAt,
        record.updatedAt, record.deletedAt, record.revision)
}
func legacyOracle_memoryV3SnapshotDigest(records: Array<MemoryV3Record>): String {
    modelPolicySha256Text(canonicalAgentValue(listValue(records.map { record => legacyOracle_memoryV3RecordValue(record) })))
}

func legacyOracle_memoryV3MatchesScope(scope: MemoryScope, filter: ?MemoryScope): Bool {
    match (filter) {
        case Some(value) => scope.kind == value.kind && scope.key == value.key
        case None => true
    }
}

func legacyOracle_memoryV3MatchesKind(kind: MemoryKind, kinds: Array<MemoryKind>): Bool {
    if (kinds.isEmpty()) { return true }
    for (value in kinds where value == kind) { return true }
    false
}

func legacyOracle_memoryV3ProjectExpiry(record: MemoryV3Record, nowMillis: Int64): MemoryV3Record {
    if (record.effectiveStatus(nowMillis: nowMillis) != MemoryStatus.Expired) {
        return record
    }
    legacyOracle_memoryV3Copy(record, status: MemoryStatus.Expired)
}

func legacyOracle_memoryV3Current(history: Array<MemoryV3Record>): Array<MemoryV3Record> {
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

func legacyOracle_memoryV3Find(records: Array<MemoryV3Record>, id: String): ?MemoryV3Record {
    for (record in records where record.id == id) { return Some(record) }
    None
}

func legacyOracle_memoryV3HasDuplicateStrings(values: Array<String>): Bool {
    for (index in 0..values.size) {
        for (other in index + 1..values.size where values[index] == values[other]) {
            return true
        }
    }
    false
}

func legacyOracle_memoryV3Copy(
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

func legacyOracle_memoryV3EventValue(operation: String, record: MemoryV3Record): AgentValue {
    objectValue([
        ValueField("version", integerValue(3)),
        ValueField("operation", textValue(operation)),
        ValueField("record", legacyOracle_memoryV3RecordValue(record))
    ])
}

func legacyOracle_memoryV3RecordValue(record: MemoryV3Record): AgentValue {
    let conflicts = ArrayList<AgentValue>()
    for (id in record.conflictIds) { conflicts.add(textValue(id)) }
    objectValue([
        ValueField("id", textValue(record.id)),
        ValueField("kind", textValue(legacyOracle_memoryV3KindName(record.kind))),
        ValueField("scopeKind", textValue(legacyOracle_memoryV3ScopeName(record.scope.kind))),
        ValueField("scopeKey", textValue(record.scope.key)),
        ValueField("content", textValue(record.content)),
        ValueField("context", textValue(record.context)),
        ValueField("source", textValue(record.source)),
        ValueField("importancePermille", integerValue(record.importancePermille)),
        ValueField("status", textValue(legacyOracle_memoryV3StatusName(record.status))),
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

func legacyOracle_memoryV3DecodeEvent(value: AgentValue): Result<MemoryV3Record> {
    if (legacyOracle_integerOr(value, "version") != 3 || legacyOracle_textOr(value, "operation") == "") {
        return legacyOracle_memoryV3Error<MemoryV3Record>(
            AgentErrorKind.RecoveryRequired,
            "memory_v3.event_invalid",
            "memory event version or operation is invalid"
        )
    }
    let item = match (value.field("record")) {
        case Some(record) => record
        case None => return legacyOracle_memoryV3Error<MemoryV3Record>(
            AgentErrorKind.RecoveryRequired,
            "memory_v3.record_missing",
            "memory event has no record"
        )
    }
    let id = legacyOracle_textOr(item, "id")
    let content = legacyOracle_textOr(item, "content")
    let kind = legacyOracle_memoryV3ParseKind(legacyOracle_textOr(item, "kind"))
    let scope = legacyOracle_memoryV3ParseScope(legacyOracle_textOr(item, "scopeKind"), legacyOracle_textOr(item, "scopeKey"))
    let status = legacyOracle_memoryV3ParseStatus(legacyOracle_textOr(item, "status"))
    if (id == "" || content == "" || kind.isNone() || scope.isNone() || status.isNone()) {
        return legacyOracle_memoryV3Error<MemoryV3Record>(
            AgentErrorKind.RecoveryRequired,
            "memory_v3.record_invalid",
            "memory event record is incomplete"
        )
    }
    let conflicts = ArrayList<String>()
    match (item.field("conflictIds")) {
        case Some(list) =>
            for (entry in list.items where entry.unifiedKind == ValueKind.Text) {
                conflicts.add(entry.text)
            }
        case None => ()
    }
    Result.Ok(MemoryV3Record(
        id,
        kind.getOrThrow(),
        scope.getOrThrow(),
        content,
        legacyOracle_textOr(item, "context"),
        legacyOracle_textOr(item, "source"),
        legacyOracle_memoryV3ClampPermille(legacyOracle_integerOr(item, "importancePermille")),
        status.getOrThrow(),
        legacyOracle_integerOr(item, "expiresAt"),
        legacyOracle_textOr(item, "correctionOf"),
        legacyOracle_textOr(item, "replacementId"),
        conflicts.toArray(),
        legacyOracle_textOr(item, "conflictReason"),
        legacyOracle_textOr(item, "deletionReason"),
        legacyOracle_integerOr(item, "createdAt"),
        legacyOracle_integerOr(item, "updatedAt"),
        legacyOracle_integerOr(item, "deletedAt"),
        legacyOracle_integerOr(item, "revision")
    ))
}

func legacyOracle_memoryV3KindName(value: MemoryKind): String {
    match (value) {
        case MemoryKind.Preference => "preference"
        case MemoryKind.ProjectFact => "project_fact"
        case MemoryKind.Decision => "decision"
        case MemoryKind.Constraint => "constraint"
        case MemoryKind.Observation => "observation"
    }
}

func legacyOracle_memoryV3ScopeName(value: MemoryScopeKind): String {
    match (value) {
        case MemoryScopeKind.Global => "global"
        case MemoryScopeKind.User => "user"
        case MemoryScopeKind.Workspace => "workspace"
        case MemoryScopeKind.Session => "session"
    }
}

func legacyOracle_memoryV3StatusName(value: MemoryStatus): String {
    match (value) {
        case MemoryStatus.Active => "active"
        case MemoryStatus.Corrected => "corrected"
        case MemoryStatus.Deleted => "deleted"
        case MemoryStatus.Conflicted => "conflicted"
        case MemoryStatus.Expired => "expired"
    }
}

func legacyOracle_memoryV3ParseKind(value: String): ?MemoryKind {
    match (value) {
        case "preference" => Some(MemoryKind.Preference)
        case "project_fact" => Some(MemoryKind.ProjectFact)
        case "decision" => Some(MemoryKind.Decision)
        case "constraint" => Some(MemoryKind.Constraint)
        case "observation" => Some(MemoryKind.Observation)
        case _ => None
    }
}

func legacyOracle_memoryV3ParseScope(kind: String, key: String): ?MemoryScope {
    match (kind) {
        case "global" => if (key == "") { Some(MemoryScope(MemoryScopeKind.Global)) } else { None }
        case "user" => if (key == "") { None } else { Some(MemoryScope(MemoryScopeKind.User, key: key)) }
        case "workspace" => if (key == "") { None } else { Some(MemoryScope(MemoryScopeKind.Workspace, key: key)) }
        case "session" => if (key == "") { None } else { Some(MemoryScope(MemoryScopeKind.Session, key: key)) }
        case _ => None
    }
}

func legacyOracle_memoryV3ParseStatus(value: String): ?MemoryStatus {
    match (value) {
        case "active" => Some(MemoryStatus.Active)
        case "corrected" => Some(MemoryStatus.Corrected)
        case "deleted" => Some(MemoryStatus.Deleted)
        case "conflicted" => Some(MemoryStatus.Conflicted)
        case "expired" => Some(MemoryStatus.Expired)
        case _ => None
    }
}

func legacyOracle_memoryV3ClampPermille(value: Int64): Int64 {
    if (value < 0) { 0 } else if (value > 1000) { 1000 } else { value }
}

func legacyOracle_memoryV3NowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func legacyOracle_memoryV3Error<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

// Preserve the original file read and AgentError result in this historical test oracle.
private func legacyOracle_memoryV3ReadTextResult(path: String, code: String): Result<String> {
    try {
        Result.Ok(String.fromUtf8(File.readFrom(path)))
    } catch (error: Exception) {
        Result.Err(AgentError(AgentErrorKind.Internal, code, error.message))
    }
}
