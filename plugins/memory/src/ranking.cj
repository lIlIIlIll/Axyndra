package memory_plugin

import agent_domain.*
import std.collection.*
import std.deriving.*

// Existing lexical/hybrid policy, separated from journal and Host authority.
// Current time and embedding outcomes are supplied as immutable input facts.
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
        let now = if (nowMillis <= 0) { 0 } else { nowMillis }
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


func memoryV3ClampPermille(value: Int64): Int64 { max(0, min(1000, value)) }
