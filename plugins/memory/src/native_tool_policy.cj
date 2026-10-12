package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class NativeMemoryToolContext {
    let sessionId: SessionId
    let workspaceRoot: String
    let cancellation: CancellationToken
    init(sessionId: SessionId, workspaceRoot: String) {
        this.sessionId = sessionId; this.workspaceRoot = workspaceRoot
        this.cancellation = CancellationSource().token
    }
}

// Tool policy is now inside the selected Native package. Its already frozen
// facts are data; only the real Host Root/Receipt can publish this proposal.
class NativeMemoryBusinessPolicy <: MemoryRetrievalPolicy {
    private var contextCeiling: Int64 = 0
    func contextValidUntilMillis(): Int64 { contextCeiling }
    func validateCurrent(): Result<Unit> { Result.Ok(()) }
    public func retrieve(query: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> {
        let lexical = memoryV3LexicalRanking(records, query.toAsciiLower())
        match (embedding) { case Some(port) => if (options.semanticEnabled) {
            return memoryV3HybridResult(query, records, lexical, options, port) }; case None => () }
        Result.Ok(memoryV3LexicalResult(lexical, options.limit, MemorySearchStrategy.Lexical, false))
    }
    func correction(current: MemoryV3Record, changes: AgentValue): Result<AgentValue> {
        let record = memoryNativePolicyRecord(current)
        let digest = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("current",record),ValueField("changes",changes)])))
        try { let proposed=memoryPolicyCorrect(objectValue([ValueField("schema",textValue("axyndra.memory-policy/v1")),
            ValueField("action",textValue("correct")),ValueField("snapshot_digest",textValue(digest)),
            ValueField("current",record),ValueField("changes",changes)]))
            Result.Ok(proposed.field("replacement").getOrThrow())
        } catch (error: PureProviderError) { Result.Err(AgentError(AgentErrorKind.InvalidInput,error.code,error.message)) }
    }
    func renderContext(hits: Array<MemoryV3SearchHit>, maxBytes: Int64, repository: NativeMemoryJournal): Result<String> {
        match (repository.validateContextRecords(hits.map { hit => hit.memory })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
            let result=memoryPolicyContextWithValidity(objectValue([ValueField("schema",textValue("axyndra.memory-policy/v1")),
                ValueField("action",textValue("context")),ValueField("snapshot_digest",textValue("native-tool-context")),
                ValueField("hits",listValue(hits.map { hit => objectValue([ValueField("record",memoryNativePolicyRecord(hit.memory)),
                    ValueField("score",integerValue(hit.scorePermille))]) })),
                ValueField("max_bytes",integerValue(maxBytes)),ValueField("now_millis",integerValue(now))]))
            contextCeiling = if (result.field("valid_until_millis").isSome()) {
                memoryPolicyInt(result,"valid_until_millis") } else { 0 }
            Result.Ok(memoryPolicyText(result,"content"))
        } catch (error: PureProviderError) { Result.Err(AgentError(AgentErrorKind.InvalidInput,error.code,error.message)) }
    }
}
func memoryNativePolicyRecord(record: MemoryV3Record): AgentValue {
    objectValue([ValueField("id",textValue(record.id)),ValueField("revision",integerValue(record.revision)),
        ValueField("kind",textValue(memoryV3KindName(record.kind))),ValueField("scope",textValue(memoryV3ScopeName(record.scope.kind))),
        ValueField("scope_key",textValue(record.scope.key)),ValueField("content",textValue(record.content)),
        ValueField("context",textValue(record.context)),ValueField("source",textValue(record.source)),
        ValueField("importance_permille",integerValue(record.importancePermille)),ValueField("status",textValue(memoryV3StatusName(record.status))),
        ValueField("expires_at",integerValue(record.expiresAt)),ValueField("updated_at",integerValue(record.updatedAt))])
}
