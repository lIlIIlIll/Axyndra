package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

public interface MemoryRetrievalPolicy {
    func retrieve(query: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult>
}

// Pure Native business proposal. An ordinal is not a committed transaction,
// Source, success flag or Receipt. The actual generic executor must settle one
// original appendStates group at a time, preserving a committed failure prefix.
public class NativeMemoryTransactionGroup {
    public let ordinal:Int64
    public let operation:String
    public let events:Array<AgentValue>
    private let expected:?MemoryV3Record
    init(ordinal:Int64,operation:String,events:Array<AgentValue>,expected:?MemoryV3Record){
        this.ordinal=ordinal;this.operation=operation;this.events=events
        this.expected=match(expected){case Some(value)=>Some(memoryV3Detached(value));case None=>None}}
    public func value():AgentValue{objectValue([ValueField("schema",textValue("axyndra.memory-transaction-proposal/v1")),
        ValueField("ordinal",integerValue(ordinal)),ValueField("operation",textValue(operation)),ValueField("events",listValue(events)),
        ValueField("expected_record",match(expected){case Some(value)=>memoryV3RecordValue(value);case None=>nullValue()})])}
}

// Pure business state. No database, filesystem, Host handle or Source enters
// this object. The output events are proposals for an already observed journal.
public class NativeMemoryJournal {
    private var journal: Array<MemoryV3Record>
    private let embedding: ?MemoryEmbeddingPort
    private let lock = Mutex()
    private var idCounter: Int64 = 0
    private let frozenNow: Int64
    private let firstAppearance: Array<String>
    private let proposals = ArrayList<AgentValue>()
    private let captureTransactions:Bool
    private let snapshotOwner:?LogicalJsonOwnerReservation
    private let transactionGate:?NativeMemoryTransactionGate
    private let transactionGroups=ArrayList<NativeMemoryTransactionGroup>()
    private var authoritativeCurrent:?Array<MemoryV3Record>=None
    public init(history: Array<MemoryV3Record>, nowMillis: Int64, embedding!: ?MemoryEmbeddingPort = None, firstAppearance!: Array<String> = [],
        captureTransactions!:Bool=false,authoritativeCurrent!:?Array<MemoryV3Record>=None,
        transactionGate!:?NativeMemoryTransactionGate=None,
        snapshotOwner!:?LogicalJsonOwnerReservation=None) {
        if (nowMillis < 1) { throw IllegalArgumentException("memory clock fact must be positive") }
        this.journal = history.map { record => memoryV3Detached(record) }
        this.frozenNow = nowMillis; this.embedding = embedding; this.firstAppearance = firstAppearance.clone()
        this.captureTransactions=captureTransactions
        this.transactionGate=transactionGate;this.snapshotOwner=snapshotOwner
        this.authoritativeCurrent=match(authoritativeCurrent){case Some(rows)=>Some(rows.map{row=>memoryV3Detached(row)});case None=>None}
    }
    private func currentRecords(history: Array<MemoryV3Record>): Array<MemoryV3Record> {
        // In the new actual stream dialect, the Host-delivered history may
        // contain an earlier globally readable version whose latest private
        // version is structural only. Never reconstruct current from that
        // visible history. This Native-only explicit current input is still
        // untrusted data, with actual Root/fact/coherence checks outside it.
        let current=match(authoritativeCurrent){case Some(rows)=>rows.map{row=>memoryV3Detached(row)};case None=>memoryV3Current(history)}
        if(firstAppearance.isEmpty()){return current}
        let result=ArrayList<MemoryV3Record>();let seen=HashSet<String>()
        for(id in firstAppearance){for(record in current where record.id==id){result.add(record);seen.add(id)}}
        for(record in current where !seen.contains(record.id)){result.add(record)}
        result.toArray()
    }
    public func pendingEvents(): Array<AgentValue> { proposals.toArray() }
    public func pendingTransactions():Array<NativeMemoryTransactionGroup>{
        lock.lock();try{transactionGroups.toArray()}finally{lock.unlock()}}
    public func retain(draft: MemoryV3Draft): Result<MemoryV3Record> {
        withLock({=>
            let history = match (loadHistory()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result<MemoryV3Record>.Err(error)
            }
            let current = currentRecords(history)
            let now = frozenNow
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
            let current = currentRecords(history)
            let target = match (memoryV3Find(current, id)) {
                case Some(value) => value
                case None => return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.InvalidInput,
                    "memory_v3.not_found",
                    "memory does not exist"
                )
            }
            if (expectedRevision > 0 && target.revision != expectedRevision) {
                return memoryV3Error<MemoryV3Record>(AgentErrorKind.Conflict,
                    "memory_v3.revision_changed", "memory changed after its policy proposal was prepared")
            }
            if (target.status == MemoryStatus.Deleted || target.status == MemoryStatus.Corrected) {
                return memoryV3Error<MemoryV3Record>(
                    AgentErrorKind.Conflict,
                    "memory_v3.not_correctable",
                    "deleted or corrected memory cannot be corrected again"
                )
            }
            let now = frozenNow
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
            let now = frozenNow
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
            let now = frozenNow
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
            let now = frozenNow
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
            // Explicit stream-current authorization comes before historical
            // selection. An old readable event never grants access to a
            // currently private or absent record.
            match(authoritativeCurrent){case Some(rows)=>if(memoryV3Find(rows,id).isNone()){
                return Result<Array<MemoryV3Record>>.Ok([])};case None=>()}
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
        if (query.trimAscii() == "") { return memoryV3Error<MemoryV3SearchResult>(
            AgentErrorKind.InvalidInput, "memory_v3.query_empty", "memory search query must not be empty") }
        let selected = match (policy) {
            case Some(value) => value
            case None => return memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.InvalidInput,
                "memory_v3.policy_required", "memory retrieval requires an explicitly selected policy")
        }
        // Freeze filtering options and records under the existing journal lock;
        // no callback or embedding I/O runs while holding that lock.
        let now = if (options.nowMillis <= 0) { frozenNow } else { options.nowMillis }
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
            snapshot.map { record => memoryV3Detached(record) }, callbackOptions, embedding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        return withLock({=>
            let current = match (captureSearchLocked(frozenOptions)) {
                case Result.Err(error) => return Result<MemoryV3SearchResult>.Err(error); case Result.Ok(value) => value }
            if (digestSnapshot(current) != digestSnapshot(snapshot)) {
                return memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.Conflict,
                    "memory_v3.snapshot_changed", "authorized memory records changed while policy was running") }
            if (proposed.hits.size > frozenOptions.limit ||
                proposed.embeddingFallback != (proposed.strategy == MemorySearchStrategy.LexicalFallback)) {
                return memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.InvalidInput,
                    "memory_v3.policy_result_invalid", "invalid policy result bounds") }
            let ids = HashSet<String>(); let hits = ArrayList<MemoryV3SearchHit>()
            for (hit in proposed.hits) {
                let original = memoryV3Find(snapshot, hit.memory.id)
                if (ids.contains(hit.memory.id) || original.isNone() || hit.scorePermille < 0 || hit.scorePermille > 1000 ||
                    hit.lexicalRank < 0 || hit.lexicalRank > snapshot.size || hit.semanticRank < 0 || hit.semanticRank > snapshot.size) {
                    return memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.InvalidInput,
                        "memory_v3.policy_result_invalid", "policy selected a foreign, duplicate, or invalid record") }
                let record = original.getOrThrow()
                let validationNow = if (options.nowMillis <= 0) { frozenNow } else { now }
                if (record.revision != hit.memory.revision || !record.isRetrievable(nowMillis: validationNow)) {
                    return memoryV3Error<MemoryV3SearchResult>(AgentErrorKind.Conflict,
                        "memory_v3.snapshot_changed", "memory revision or expiry changed before consumption") }
                ids.add(record.id)
                hits.add(MemoryV3SearchHit(memoryV3Detached(record), hit.scorePermille,
                    lexicalRank: hit.lexicalRank, semanticRank: hit.semanticRank))
            }
            Result.Ok(MemoryV3SearchResult(hits.toArray(), proposed.strategy, proposed.embeddingFallback))
        })
    }

    private func digestSnapshot(records:Array<MemoryV3Record>):String {
        match(snapshotOwner){case Some(owner)=>nativeMemoryOwnedSnapshotDigest(records,owner);case None=>memoryV3SnapshotDigest(records)}
    }
    private func captureSearch(options: MemoryV3SearchOptions): Result<Array<MemoryV3Record>> {
        withLock({=> captureSearchLocked(options) })
    }
    private func captureSearchLocked(options: MemoryV3SearchOptions): Result<Array<MemoryV3Record>> {
        let current = match (loadCurrent()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let values = ArrayList<MemoryV3Record>()
        for (record in current where record.isRetrievable(nowMillis: options.nowMillis) &&
            memoryV3MatchesScope(record.scope, options.scope) && memoryV3MatchesKind(record.kind, options.kinds)) {
            values.add(memoryV3Detached(record))
        }
        Result.Ok(values.toArray())
    }

    // Revalidate context/correction facts immediately before their consumer.
    // Ordering/ranking is deliberately absent from this data-integrity check.
    public func validateRecords(records: Array<MemoryV3Record>): Result<Unit> {
        withLock({=>
            let current = match (loadCurrent()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
            for (record in records) {
                let actual = memoryV3Find(current, record.id)
                if (actual.isNone() || match(snapshotOwner){
                    case Some(owner)=>!nativeMemoryOwnedContextRecordEqual(actual.getOrThrow(),record,owner)
                    case None=>canonicalAgentValue(memoryV3RecordValue(actual.getOrThrow())) !=
                    canonicalAgentValue(memoryV3RecordValue(record))
                }) {
                    return memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.snapshot_changed", "memory fact changed") }
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
                let actual = memoryV3Find(current, record.id)
                if (actual.isNone() || match(snapshotOwner){
                    case Some(owner)=>!nativeMemoryOwnedContextRecordEqual(actual.getOrThrow(),record,owner)
                    case None=>canonicalAgentValue(memoryV3RecordValue(actual.getOrThrow())) !=
                    canonicalAgentValue(memoryV3RecordValue(record))
                }) {
                    return memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.context_fact_expired_or_changed",
                        "memory context fact is no longer currently retrievable") }
            }
            let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
            for (record in records where !record.isRetrievable(nowMillis: now)) {
                return memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.context_fact_expired_or_changed",
                    "memory context fact expired before consumption") }
            Result.Ok(())
        })
    }

    private func loadCurrent(): Result<Array<MemoryV3Record>> {
        match (loadHistory()) {
            case Result.Ok(history) => Result.Ok(currentRecords(history))
            case Result.Err(error) => Result<Array<MemoryV3Record>>.Err(error)
        }
    }

    private func loadHistory(): Result<Array<MemoryV3Record>> {
        Result.Ok(journal.map { record => memoryV3Detached(record) })
    }

    private func appendStates(operation: String, records: Array<MemoryV3Record>,
        expected!: ?MemoryV3Record = None): Result<Unit> {
        match (expected) { case Some(original) =>
            let current = memoryV3Find(currentRecords(journal), original.id)
            if (current.isNone() || match(snapshotOwner){
                case Some(owner)=>!nativeMemoryOwnedContextRecordEqual(current.getOrThrow(),original,owner)
                case None=>canonicalAgentValue(memoryV3RecordValue(current.getOrThrow())) !=
                canonicalAgentValue(memoryV3RecordValue(original))
            }) {
                return memoryV3Error<Unit>(AgentErrorKind.Conflict, "memory_v3.revision_changed", "memory expected record changed") }
            case None => () }
        // Opt-in actual Native driver yield. Ordinary whole-body algorithms
        // and the default proposal-only constructor remain unchanged.
        match(transactionGate){case Some(gate)=>match(gate.beforeAppend(operation,records,expected)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()};case None=>()}
        let firstProposal=proposals.size
        let next = ArrayList<MemoryV3Record>(journal)
        for (record in records) {
            next.add(memoryV3Detached(record)); proposals.add(memoryV3EventValue(operation, record))
        }
        if(captureTransactions){
            // Each invocation of the ORIGINAL appendStates is one group:
            // retain has one per draft; correction/conflict records remain
            // together. Do not flatten this into one actual SQLite commit.
            let events=Array<AgentValue>(proposals.size-firstProposal,{index=>proposals[firstProposal+index]})
            transactionGroups.add(NativeMemoryTransactionGroup(transactionGroups.size,operation,events,expected))}
        match(authoritativeCurrent){case Some(rows)=>
            let current=ArrayList<MemoryV3Record>(rows)
            for(record in records){current.add(memoryV3Detached(record))}
            authoritativeCurrent=Some(memoryV3Current(current.toArray()))
            case None=>()}
        journal = next.toArray(); Result.Ok(())
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

func memoryV3Detached(record: MemoryV3Record): MemoryV3Record {
    MemoryV3Record(record.id, record.kind, record.scope, record.content, record.context, record.source,
        record.importancePermille, record.status, record.expiresAt, record.correctionOf, record.replacementId,
        record.conflictIds.clone(), record.conflictReason, record.deletionReason, record.createdAt,
        record.updatedAt, record.deletedAt, record.revision)
}

func memoryV3SnapshotDigest(records: Array<MemoryV3Record>): String {
    modelPolicySha256Text(canonicalAgentValue(listValue(records.map { record => memoryV3RecordValue(record) })))
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

func memoryV3Error<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

func integerOr(value: AgentValue, field: String): Int64 {
    match (value.field(field)) { case Some(item) =>
        if (item.unifiedKind == ValueKind.Number) { try { return Int64.parse(item.asNumberText()) } catch (_: Exception) { () } }
        case None => () }; 0
}
func textOr(value: AgentValue, field: String): String {
    match (value.field(field)) { case Some(item) => if (item.unifiedKind == ValueKind.Text) { return item.text }
        case None => () }; ""
}
