package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.reserveNativeObservationBuffer
import std.collection.*
import yjson.*
import yjson_support.*

// Exact original canonicalAgentValue framing of the original neutral model
// codec. Two complete cursor passes retain only per-message numeric lengths.
// The full corpus is neither a JSON string nor an Array<ModelMessage> here.
func checkpointOwnedProjectionDigest113(cursor: PaidCanonicalThreadCursor113,
    thread: ThreadId, revision: Int64, nextOrdinal: Int64, through: Int64,
    goal: AgentValue, todos: AgentValue, allocate: (Int64) -> LogicalJsonOwnerReservation,
    localGuard: () -> Result<Unit>, current: () -> Result<Unit>): String {
    let metadata = allocate(65536)
    let buffer = try { reserveNativeObservationBuffer() }
        catch (failure: Exception) { metadata.close(); throw failure }
    let digest = ProductPolicyDataDigest()
    let plan = CheckpointProjectionLengths113(metadata)
    try {
        metadata.ensureRetainedPeak(1048576)
        let projection = modelRequestSnapshotValue(ModelRequest("compaction-history", []))
        let facts = objectValue([ValueField("projection", projection), ValueField("goal", goal), ValueField("todos", todos)])
        compactionDataRequire(current())
        compactionDataRequire(visitOwnedCanonicalModelMessages113(cursor, thread, revision, nextOrdinal, through,
            allocate, localGuard, current, { role => plan.begin(role) }, { role, block, custody =>
                compactionDataRequire(custody.ensureAdditionalRetainedPeak(65536))
                let encoded = checkpointOriginalBlockValue113(role, block)
                plan.block(digest.measureData113(encoded))
            }))
        plan.complete(digest)
        let projectionBytes = checkpointVirtualFieldSize113(digest, projection, "messages", plan.messagesBytes)
        checkpointEmitVirtualField113(digest, facts, "projection", projectionBytes, { =>
            checkpointEmitVirtualField113(digest, projection, "messages", plan.messagesBytes, { =>
                digest.emitText113("[")
                let emit = CheckpointProjectionEmitter113(digest, plan)
                compactionDataRequire(visitOwnedCanonicalModelMessages113(cursor, thread, revision, nextOrdinal, through,
                    allocate, localGuard, current, { role => emit.begin(role) }, { role, block, custody =>
                        compactionDataRequire(custody.ensureAdditionalRetainedPeak(65536))
                        let encoded = checkpointOriginalBlockValue113(role, block)
                        emit.block(encoded)
                    }))
                emit.finish()
                digest.emitText113("]")
            })
        })
        compactionDataRequire(current())
        compactionDataRequire(cursor.requireBoundary(thread, revision, nextOrdinal, localGuard))
        digest.finishData113()
    } finally { plan.clear(); buffer.close(); metadata.close() }
}

func checkpointOriginalBlockValue113(role: ModelRole, block: ModelBlock): AgentValue {
    modelRequestSnapshotValue(ModelRequest("compaction-history", [ModelMessage(role, [block])]))
        .field("messages").getOrThrow().items[0].field("blocks").getOrThrow().items[0]
}
func checkpointProjectionAdd113(a: Int64, b: Int64): Int64 {
    if (a < 0 || b < 0 || a > Int64.Max - b) { throw IllegalStateException("checkpoint projection size overflow") }; a + b
}
func checkpointProjectionFrame113(bytes: Int64): Int64 {
    checkpointProjectionAdd113(bytes, bytes.toString().size + 1)
}
func checkpointProjectionRole113(role: ModelRole): AgentValue {
    textValue(match (role) { case ModelRole.User => "user"; case ModelRole.Assistant => "assistant" })
}
func checkpointVirtualFieldSize113(digest: ProductPolicyDataDigest, value: AgentValue,
    name: String, bytes: Int64): Int64 {
    if (value.unifiedKind != ValueKind.Object || value.field(name).isNone()) {
        throw IllegalStateException("original projection codec changed its required field") }
    let old = checkpointProjectionFrame113(digest.measureData113(value.field(name).getOrThrow()))
    let total = digest.measureData113(value)
    if (total < old) { throw IllegalStateException("original projection framing is invalid") }
    checkpointProjectionAdd113(total - old, checkpointProjectionFrame113(bytes))
}
func checkpointEmitVirtualField113(digest: ProductPolicyDataDigest, value: AgentValue,
    name: String, bytes: Int64, emit: () -> Unit): Unit {
    let used = Array<Bool>(value.fields.size, repeat: false)
    var replacements: Int64 = 0
    digest.emitText113("{")
    for (_ in 0..value.fields.size) {
        var selected: Int64 = -1
        for (index in 0..value.fields.size where !used[index]) {
            if (selected < 0 || value.fields[index].name < value.fields[selected].name) { selected = index } }
        used[selected] = true
        let field = value.fields[selected]
        digest.emitFrameText113(field.name)
        if (field.name == name) {
            replacements++; digest.emitText113(bytes.toString() + ":"); emit()
        } else {
            digest.emitText113(digest.measureData113(field.value).toString() + ":")
            digest.emitData113(field.value) }
    }
    if (replacements != 1) { throw IllegalStateException("original projection replacement is not unique") }
    digest.emitText113("}")
}

class CheckpointProjectionMessageLength113 {
    let role: ModelRole
    var blocksBytes: Int64 = 2
    var messageBytes: Int64 = 0
    init(role: ModelRole) { this.role = role }
}
class CheckpointProjectionLengths113 {
    let messages = ArrayList<CheckpointProjectionMessageLength113>()
    var messagesBytes: Int64 = 2
    private let owner: LogicalJsonOwnerReservation
    private var retained: Int64 = 1048576
    init(owner: LogicalJsonOwnerReservation) { this.owner = owner }
    func begin(role: ModelRole): Unit {
        // Four scalar fields + ArrayList entry/backing growth. This numeric
        // plan has no per-message DOM/String copy: 1024 includes both old and
        // new pointer backing during growth and object/header/alignment.
        retained = checkpointProjectionAdd113(retained, 1024)
        owner.ensureRetainedPeak(retained)
        messages.add(CheckpointProjectionMessageLength113(role))
    }
    func block(bytes: Int64): Unit {
        if (messages.isEmpty()) { throw IllegalStateException("canonical block has no original message") }
        let message = messages[messages.size - 1]
        message.blocksBytes = checkpointProjectionAdd113(message.blocksBytes, checkpointProjectionFrame113(bytes))
    }
    func complete(digest: ProductPolicyDataDigest): Unit {
        for (message in messages) {
            // Original message object sorts blocks BEFORE role. The small
            // role value is the original model codec's exact text spelling.
            message.messageBytes = checkpointProjectionAdd113(2,
                checkpointProjectionAdd113(checkpointProjectionFrame113("blocks".size),
                checkpointProjectionAdd113(checkpointProjectionFrame113(message.blocksBytes),
                checkpointProjectionAdd113(checkpointProjectionFrame113("role".size),
                    checkpointProjectionFrame113(digest.measureData113(checkpointProjectionRole113(message.role)))))))
            messagesBytes = checkpointProjectionAdd113(messagesBytes, checkpointProjectionFrame113(message.messageBytes))
        }
    }
    func clear(): Unit { messages.clear() }
}
class CheckpointProjectionEmitter113 {
    private let digest: ProductPolicyDataDigest
    private let plan: CheckpointProjectionLengths113
    private var next: Int64 = 0
    private var blocksBytes: Int64 = 2
    private var active: ?CheckpointProjectionMessageLength113 = None<CheckpointProjectionMessageLength113>
    init(digest: ProductPolicyDataDigest, plan: CheckpointProjectionLengths113) { this.digest = digest; this.plan = plan }
    func begin(role: ModelRole): Unit {
        closeMessage()
        if (next >= plan.messages.size || plan.messages[next].role != role) {
            throw IllegalStateException("canonical projection changed between complete passes") }
        let message = plan.messages[next]; next++; active = Some(message); blocksBytes = 2
        digest.emitText113(message.messageBytes.toString() + ":{")
        digest.emitFrameText113("blocks"); digest.emitText113(message.blocksBytes.toString() + ":[")
    }
    func block(value: AgentValue): Unit {
        if (active.isNone()) { throw IllegalStateException("canonical block has no measured message") }
        let bytes = digest.measureData113(value)
        blocksBytes = checkpointProjectionAdd113(blocksBytes, checkpointProjectionFrame113(bytes))
        digest.emitText113(bytes.toString() + ":"); digest.emitData113(value)
    }
    private func closeMessage(): Unit {
        match (active) { case Some(message) =>
            if (blocksBytes != message.blocksBytes) { throw IllegalStateException("canonical block framing changed") }
            digest.emitText113("]"); digest.emitFrameText113("role")
            let role = checkpointProjectionRole113(message.role)
            digest.emitText113(digest.measureData113(role).toString() + ":"); digest.emitData113(role); digest.emitText113("}")
            active = None<CheckpointProjectionMessageLength113>
            case None => () }
    }
    func finish(): Unit {
        closeMessage()
        if (next != plan.messages.size) { throw IllegalStateException("canonical projection omitted measured messages") }
    }
}
