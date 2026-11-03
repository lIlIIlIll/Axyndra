package agent_product

import agent_domain.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class MemoryLongEmbedding <: MemoryEmbeddingPort {
    private let failed: Bool
    init(failed!: Bool = false) { this.failed = failed }
    public func embed(text: String): Result<Array<Float64>> {
        if (failed) { return Result.Err(AgentError(AgentErrorKind.Transport, "fixture.embedding_failed", "observed embedding failure")) }
        Result.Ok(Array<Float64>(70001, repeat: if (text.contains("needle")) { 1.0 } else { -1.0 }))
    }
}
class MemoryIeeeEmbedding <: MemoryEmbeddingPort {
    private let mode: String
    init(mode: String) { this.mode = mode }
    public func embed(text: String): Result<Array<Float64>> {
        let infinity = Float64.fromBits(0x7ff0000000000000)
        if (text == "needle") {
            return Result.Ok(if (mode == "nan_query") { [Float64.fromBits(0x7ff8000000000001), 1.0] }
                else if (mode == "overflow") { [1.0e308, 1.0e308] }
                else if (mode == "infinity") { [infinity, 1.0] } else { [1.0, 1.0] })
        }
        if (text.contains("barrier")) {
            return Result.Ok(if (mode == "nan_record") { [Float64.fromBits(0x7ff8000000000001), 1.0] } else { [infinity, -infinity] }) }
        if (text.contains("huge")) { return Result.Ok([1.0e308, 1.0e308]) }
        if (text.contains("negative")) { return Result.Ok([-infinity, -infinity]) }
        Result.Ok([-0.0, 0.0])
    }
}
class MemoryFragmentCorruptingConsumer {
    private let fixture: MemoryPolicyFixture
    private let selected: ProductMemoryPolicy
    private let source: CancellationSource
    private let mode: String
    private var sequence: Int64 = 0
    init(fixture: MemoryPolicyFixture, selected: ProductMemoryPolicy, source: CancellationSource, mode: String) {
        this.fixture = fixture; this.selected = selected; this.source = source; this.mode = mode
    }
    func query(input: AgentValue): Result<AgentValue> {
        match (selected.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let record = fixture.record.getOrThrow(); sequence++
        let response = match (queryProductPluginPolicy(fixture.product.vnext.javascriptPlugins, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "memory",
            productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), input, ThreadId("fragment-negative"), source.token, mode + "-fragment-" + sequence.toString())) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            let value = parseUnifiedJson(stringifyUnifiedJson(response.value), maxBytes: 262144)
            if (httpIntentText(input, "action") == "lexical_fragment") {
                match (mode) {
                    case "offset" => value.put("next_offset", integerValue(productMemoryPolicyInt(value, "next_offset") + 1))
                    case "record" => value.put("record_digest", textValue("different"))
                    case "revision" => value.put("revision", integerValue(999))
                    case "cursor" => value.put("query_cursor", integerValue(99))
                    case "early_complete" => value.put("batch_complete", boolValue(true))
                    case "carry" => value.field("carry").getOrThrow().put("content_offset", integerValue(0))
                    case "cancel" => let _ = source.cancel()
                    case _ => ()
                }
            }
            if (httpIntentText(input, "action") == "correct_references" && mode == "correction") {
                value.field("replacement").getOrThrow().field("content").getOrThrow().put("sha256", textValue("forged")) }
            if (httpIntentText(input, "action") == "partition_semantic_page") {
                let groups = value.field("groups").getOrThrow().items.toArray()
                match (mode) {
                    case "partition_missing" => value.put("groups", listValue([]))
                    case "partition_duplicate" => value.put("groups", listValue([groups[0], groups[0]]))
                    case "partition_flag" => groups[0].put("sortable", textValue("true"))
                    case "partition_revision" => groups[0].field("rows").getOrThrow().items[0].put("revision", integerValue(99))
                    case "partition_cancel" => let _ = source.cancel()
                    case _ => ()
                }
            }
            match (selected.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(value)
        } finally { response.close() }
    }
}

@Test
class InstalledMemoryFragmentTests {
    @TestCase
    func actualEmbeddingSpecialValuesMatchNativeLegacyOracleAndCanonicalRepositoryFacts(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let repository = MemoryV3Repository(f.database)
            for (name in ["zero-before", "barrier", "huge", "negative", "zero-after"]) {
                let _ = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                    MemoryScope(MemoryScopeKind.Workspace, key: f.root), "needle " + name))) }
            let now = agentUtcMillis(); let records = lifecycleTestRequire(repository.list(nowMillis: now))
            let source = CancellationSource()
            try {
                let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("fragment-negative"), cancellation: source.token))
                let consumer = MemoryFragmentCorruptingConsumer(f, selected, source, "ieee-oracle")
                for (mode in ["finite", "overflow", "infinity", "nan_query", "nan_record"]) {
                    let embedding = MemoryIeeeEmbedding(mode)
                    let vectors = records.map { record => objectValue([ValueField("id", textValue(record.id)),
                        ValueField("revision", integerValue(record.revision)), ValueField("vector",
                            productMemoryVectorValue(lifecycleTestRequire(embedding.embed(record.content + "\n" + record.context))))]) }
                    let expected = lifecycleTestRequire(consumer.query(objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")),
                        ValueField("action", textValue("retrieve")), ValueField("snapshot_digest", textValue("actual-repository-ieee-oracle")),
                        ValueField("query", textValue("needle")), ValueField("records", listValue(records.map { record => productMemoryPolicyRecord(record) })),
                        ValueField("options", objectValue([ValueField("limit", integerValue(100)), ValueField("semantic_enabled", boolValue(true)),
                            ValueField("lexical_weight", integerValue(650)), ValueField("semantic_weight", integerValue(350)), ValueField("now_millis", integerValue(now))])),
                        ValueField("embeddings", objectValue([ValueField("state", textValue("ready")),
                            ValueField("query", productMemoryVectorValue(lifecycleTestRequire(embedding.embed("needle")))), ValueField("records", listValue(vectors))]))])))
                    let actual = lifecycleTestRequire(MemoryV3Repository(f.database, embedding: Some(embedding)).search("needle",
                        options: MemoryV3SearchOptions(limit: 100, nowMillis: now), policy: Some(selected)))
                    let hits = actual.hits.map { hit => objectValue([ValueField("id", textValue(hit.memory.id)), ValueField("revision", integerValue(hit.memory.revision)),
                        ValueField("score", integerValue(hit.scorePermille)), ValueField("lexical_rank", integerValue(hit.lexicalRank)),
                        ValueField("semantic_rank", integerValue(hit.semanticRank))]) }
                    @Expect(canonicalAgentValue(listValue(hits)), canonicalAgentValue(expected.field("hits").getOrThrow()))
                    @Expect(actual.embeddingFallback, mode == "nan_query" || mode == "nan_record")
                    @Expect(actual.strategy, if (actual.embeddingFallback) { MemorySearchStrategy.LexicalFallback } else { MemorySearchStrategy.Hybrid })
                }
            } finally { source.close() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 5)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
    @TestCase
    func actualPartitionResponsesCannotDropDuplicateChangeFactsOrIgnoreCancellation(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let repository = MemoryV3Repository(f.database)
            for (name in ["zero", "huge"]) { let _ = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), "needle " + name))) }
            let records = lifecycleTestRequire(repository.list())
            for (mode in ["partition_missing", "partition_duplicate", "partition_flag", "partition_revision", "partition_cancel"]) {
                let source = CancellationSource()
                try {
                    let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("fragment-negative"), cancellation: source.token))
                    let consumer = MemoryFragmentCorruptingConsumer(f, selected, source, mode)
                    let actual = ProductMemoryPagedRanking(records, MemoryV3SearchOptions(nowMillis: agentUtcMillis()), "needle",
                        { input => consumer.query(input) }, { => selected.validateCurrent() }).retrieve(Some(MemoryIeeeEmbedding("finite")))
                    @Expect(actual.isError())
                    if (mode == "partition_cancel") { @Expect(actual.error().getOrThrow().kind, AgentErrorKind.Cancelled) }
                    else { @Expect(actual.error().getOrThrow().code,
                        if (mode == "partition_revision") { "memory.page_result_invalid" } else { "memory.page_partition" }) }
                } finally { source.close() }
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { f.close() }
    }
    @TestCase
    func largeCorrectionDefaultsRemainExactAndCannotSelectAnInventedReference(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let repository = MemoryV3Repository(f.database)
            let body = String.fromUtf8(Array<Byte>(6291456, repeat: b'x'))
            let current = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), body, context: "previous")))
            let changes = objectValue([ValueField("context", textValue("approved replacement context"))])
            let source = CancellationSource()
            try {
                let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("fragment-negative"), cancellation: source.token))
                let consumer = MemoryFragmentCorruptingConsumer(f, selected, source, "correction")
                let rejected = ProductMemoryCorrectionFragments(current, changes, { input => consumer.query(input) }).correction()
                @Expect(rejected.isError()); @Expect(rejected.error().getOrThrow().code, "memory.policy_correction_changed")
                @Expect(lifecycleTestRequire(repository.get(current.id)).getOrThrow().revision, current.revision)
                let proposal = lifecycleTestRequire(selected.correction(current, changes))
                @Expect(httpIntentText(proposal, "content"), body)
                @Expect(httpIntentText(proposal, "context"), "approved replacement context")
                let corrected = lifecycleTestRequire(repository.correct(current.id, MemoryV3Draft(current.kind, current.scope,
                    httpIntentText(proposal, "content"), context: httpIntentText(proposal, "context")), expectedRevision: current.revision))
                @Expect(corrected.content, body); @Expect(corrected.context, "approved replacement context")
                @Expect(lifecycleTestRequire(repository.history(current.id)).size, 2)
                @Expect(repository.correct(current.id, MemoryV3Draft(current.kind, current.scope, "stale"), expectedRevision: current.revision).isError())
            } finally { source.close() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { f.close() }
    }
    @TestCase
    func actualAppContextAndRepositoryRetrievalReadOneLargeCanonicalRecordWithoutWireTruncation(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let body = "needle MEMORY-FRAGMENT-AUTO-CONTEXT " + String.fromUtf8(Array<Byte>(6291456, repeat: b'x'))
            let repository = MemoryV3Repository(f.database)
            // Existing public canonical Memory storage API, not SQL mutation or
            // a test-only oversized provider action. Memory's own record codec
            // has a distinct 64 MiB decode bound from ToolResult's 8 MiB bound.
            let record = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), body)))
            let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("large-record")))
            let found = lifecycleTestRequire(repository.search("needle", options: MemoryV3SearchOptions(
                scope: Some(record.scope), semanticEnabled: false), policy: Some(selected)))
            @Expect(found.hits.size, 1); @Expect(found.hits[0].memory.id, record.id)
            @Expect(found.hits[0].memory.content, body); @Expect(found.hits[0].scorePermille, 825)
            let context = lifecycleTestRequire(selected.renderContext(found.hits, 4096, repository))
            @Expect(context.size, 4096); @Expect(context.contains("MEMORY-FRAGMENT-AUTO-CONTEXT"))
            // Recorded API migration: the application explicitly selects the
            // actual typed Native window provider after owned Memory retires.
            // The original full record/rank/context/history oracle is intact.
            memoryWindowInitialContextProfile(f)
            let app = f.product.applicationSession()
            @Expect(app.submit("needle").isOk())
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("MEMORY-FRAGMENT-AUTO-CONTEXT"))
            @Expect(lifecycleTestRequire(repository.get(record.id)).getOrThrow().content, body)
            @Expect(lifecycleTestRequire(repository.history(record.id)).size, 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
        } finally { f.close() }
    }
    @TestCase
    func actualInstalledPolicyRanksLongVectorsAndKeepsWholeQueryFailureFallback(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let repository = MemoryV3Repository(f.database)
            let expected = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), "needle neighbor")))
            let _ = lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference, expected.scope, "unrelated")))
            let options = MemoryV3SearchOptions(scope: Some(expected.scope))
            for (failed in [false, true]) {
                let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("long-vector")))
                let result = lifecycleTestRequire(MemoryV3Repository(f.database, embedding: Some(MemoryLongEmbedding(failed: failed))).search(
                    "needle", options: options, policy: Some(selected)))
                @Expect(result.hits[0].memory.id, expected.id)
                @Expect(result.strategy, if (failed) { MemorySearchStrategy.LexicalFallback } else { MemorySearchStrategy.Hybrid })
                @Expect(result.embeddingFallback, failed)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { f.close() }
    }
    @TestCase
    func actualProviderFragmentsCannotSkipChangeReplayOrOutliveCallerCancellation(): Unit {
        let f = MemoryPolicyFixture()
        try {
            let record = lifecycleTestRequire(MemoryV3Repository(f.database).retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Workspace, key: f.root), "needle " + String.fromUtf8(Array<Byte>(4718592, repeat: b'x')))))
            for (mode in ["offset", "record", "revision", "cursor", "early_complete", "carry", "cancel"]) {
                let source = CancellationSource()
                try {
                    let selected = lifecycleTestRequire(f.legacyPolicy(SessionId("fragment-negative"), cancellation: source.token))
                    let consumer = MemoryFragmentCorruptingConsumer(f, selected, source, mode)
                    let result = ProductMemoryPagedRanking([record], MemoryV3SearchOptions(nowMillis: agentUtcMillis(), semanticEnabled: false),
                        "needle", { input => consumer.query(input) }, { => selected.validateCurrent() }).retrieve(None)
                    @Expect(result.isError())
                    if (mode == "cancel") { @Expect(result.error().getOrThrow().kind, AgentErrorKind.Cancelled) }
                    else { @Expect(result.error().getOrThrow().code, "memory.fragment_coverage") }
                } finally { source.close() }
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
}
