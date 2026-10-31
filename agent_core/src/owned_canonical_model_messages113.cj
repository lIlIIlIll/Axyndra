package agent_core

import agent_domain.*
import agent_runtime.*
import std.collection.*

// Same provider-neutral projection as modelMessagesFromCanonicalItems. A
// message boundary and its ordered blocks replace the corpus Array. Complete
// row custody stays live during each consumer; no ordinary frame size/history
// count is imposed and no Native datum becomes a Source or context cut.
public func visitOwnedCanonicalModelMessages113(cursor: PaidCanonicalThreadCursor113,
    thread: ThreadId, revision: Int64, nextOrdinal: Int64, through: Int64,
    allocate: (Int64) -> LogicalJsonOwnerReservation, localGuard: () -> Result<Unit>, current: () -> Result<Unit>,
    begin: (ModelRole) -> Unit, consume: (ModelRole, ModelBlock, OwnedCanonicalThreadItemAliasCustody) -> Unit): Result<Unit> {
    if (through < 0 || through >= nextOrdinal) { return ownedModelMessagesError113("context.prefix_invalid") }
    let owner = allocate(65536)
    let state = try { OwnedModelMessageState113(owner, begin, consume) }
        catch (failure: Exception) { owner.close(); throw failure }
    try {
        compactionModelRequire113(cursor.requireBoundary(thread, revision, nextOrdinal, localGuard))
        // Original complete-prefix read-call filter and first-call name lookup,
        // including calls after their results. Only detached small metadata.
        for (ordinal in 1..=through) {
            compactionModelRequire113(cursor.withOrdinal(thread, revision, nextOrdinal, ordinal, localGuard, current,
                { item, _ =>
                    match (item.content) { case ThreadItemContent.ToolCall(call, name, _) =>
                        if (state.names.get(call.value).isNone()) {
                            state.pay(ownedModelMetadataPeak113(call.value, name))
                            state.names[String.fromUtf8(call.value.toArray())] = String.fromUtf8(name.toArray()) }
                        if (isContextReadItem(item)) {
                            state.pay(ownedModelMetadataPeak113(item.turnId.value, call.value))
                            state.internal.add(String.fromUtf8(item.turnId.value.toArray()) + "\u{0000}" + String.fromUtf8(call.value.toArray())) }
                        case _ => () }
                    Result<Unit>.Ok(())
                }))
        }
        for (ordinal in 1..=through) {
            compactionModelRequire113(cursor.withOrdinal(thread, revision, nextOrdinal, ordinal, localGuard, current,
                { item, actual =>
                    match (item.content) {
                        case ThreadItemContent.ToolCall(id, _, _) =>
                            compactionModelRequire113(actual.ensureAdditionalRetainedPeak(ownedModelMetadataPeak113(item.turnId.value, id.value)))
                            if (state.internal.contains(item.turnId.value + "\u{0000}" + id.value)) { return Result<Unit>.Ok(()) }
                        case ThreadItemContent.ToolResult(id, _, _, _, _) =>
                            compactionModelRequire113(actual.ensureAdditionalRetainedPeak(ownedModelMetadataPeak113(item.turnId.value, id.value)))
                            if (state.internal.contains(item.turnId.value + "\u{0000}" + id.value)) { return Result<Unit>.Ok(()) }
                        case _ => () }
                    // SUM includes original whole row plus its projected typed
                    // containers while the consumer/RPC callback remains live.
                    var projection: Int64 = 65536
                    match (item.content) {
                        case ThreadItemContent.UserMessage(parts) =>
                            for (part in parts) {
                                projection = ownedModelAdd113(projection, 16384)
                                match (part) { case ThreadMessagePart.Image(image) =>
                                    if (image.sourceKind == ThreadImageSourceKind.Artifact) {
                                        projection = ownedModelAdd113(projection, ownedModelMetadataPeak113(image.data, "")) }
                                    case _ => () }
                            }
                        case ThreadItemContent.AssistantMessage(parts) =>
                            for (part in parts) {
                                projection = ownedModelAdd113(projection, 16384)
                                match (part) { case ThreadMessagePart.Image(image) =>
                                    if (image.sourceKind == ThreadImageSourceKind.Artifact) {
                                        projection = ownedModelAdd113(projection, ownedModelMetadataPeak113(image.data, "")) }
                                    case _ => () }
                            }
                        case ThreadItemContent.ArtifactReference(hash, mime, _) =>
                            projection = ownedModelAdd113(projection, ownedModelMetadataPeak113(hash, mime))
                        case _ => () }
                    compactionModelRequire113(actual.ensureAdditionalRetainedPeak(projection))
                    match (item.content) {
                        case ThreadItemContent.UserMessage(parts) =>
                            state.startUser()
                            for (block in projectedMessageParts(parts)) { state.block(ModelRole.User, block, actual) }
                        case ThreadItemContent.AssistantMessage(parts) =>
                            state.startAssistant()
                            for (block in projectedMessageParts(parts)) { state.block(ModelRole.Assistant, block, actual) }
                        case ThreadItemContent.ToolCall(call, name, arguments) =>
                            state.startAssistant()
                            if (state.paired < state.opaque.size) {
                                let opaqueOrdinal = state.opaque[state.paired]; state.paired++
                                compactionModelRequire113(cursor.withOrdinal(thread, revision, nextOrdinal, opaqueOrdinal,
                                    localGuard, current, { opaqueItem, opaqueOwner =>
                                        match (opaqueItem.content) { case ThreadItemContent.ProviderOpaqueItem(opaque) =>
                                            compactionModelRequire113(opaqueOwner.ensureAdditionalRetainedPeak(65536))
                                            state.block(ModelRole.Assistant, ModelBlock(ModelBlockKind.ToolCall,
                                                callId: call.value, name: name, arguments: arguments, opaqueState: Some(opaque)), actual)
                                            case _ => throw IllegalStateException("original opaque pairing changed") }
                                        Result<Unit>.Ok(()) }) )
                            } else {
                                state.block(ModelRole.Assistant, ModelBlock(ModelBlockKind.ToolCall,
                                    callId: call.value, name: name, arguments: arguments), actual) }
                        case ThreadItemContent.ToolResult(call, _, receipt, result, failed) =>
                            state.startResult()
                            state.block(ModelRole.User, ModelBlock(ModelBlockKind.ToolResult, callId: call.value,
                                name: state.names.get(call.value) ?? "tool", arguments: result, isError: failed, receiptId: receipt), actual)
                        case ThreadItemContent.ReasoningReference(_, summary) =>
                            state.startAssistant(); state.block(ModelRole.Assistant, ModelBlock(ModelBlockKind.Reasoning, text: summary), actual)
                        case ThreadItemContent.ProviderOpaqueItem(opaque) =>
                            if (item.provenance.source == "provider_tool_call") { state.pay(1024); state.opaque.add(item.ordinal) }
                            else { state.startAssistant(); state.block(ModelRole.Assistant, ModelBlock(ModelBlockKind.Unknown, opaqueState: Some(opaque)), actual) }
                        case ThreadItemContent.ArtifactReference(hash, mime, size) =>
                            state.startAssistant(); state.block(ModelRole.Assistant, ModelBlock(ModelBlockKind.Text,
                                text: "[artifact " + hash + " " + mime + " " + size.toString() + "]"), actual)
                        case ThreadItemContent.SystemNote(_) => () }
                    Result<Unit>.Ok(())
                }))
        }
        // The original projection appends every remaining opaque item in order.
        while (state.paired < state.opaque.size) {
            let ordinal = state.opaque[state.paired]; state.paired++
            compactionModelRequire113(cursor.withOrdinal(thread, revision, nextOrdinal, ordinal, localGuard, current,
                { item, actual =>
                    compactionModelRequire113(actual.ensureAdditionalRetainedPeak(65536))
                    match (item.content) { case ThreadItemContent.ProviderOpaqueItem(opaque) =>
                        state.startAssistant(); state.block(ModelRole.Assistant, ModelBlock(ModelBlockKind.Unknown, opaqueState: Some(opaque)), actual)
                        case _ => throw IllegalStateException("original trailing opaque item changed") }
                    Result<Unit>.Ok(()) }))
        }
        cursor.requireBoundary(thread, revision, nextOrdinal, localGuard)
    } finally { state.clear(); owner.close() }
}

class OwnedModelMessageState113 {
    let names = HashMap<String, String>()
    let internal = HashSet<String>()
    let opaque = ArrayList<Int64>()
    var paired: Int64 = 0
    private let owner: LogicalJsonOwnerReservation
    private let begin: (ModelRole) -> Unit
    private let consume: (ModelRole, ModelBlock, OwnedCanonicalThreadItemAliasCustody) -> Unit
    private var retained: Int64 = 65536
    private var mode: Int64 = 0
    init(owner: LogicalJsonOwnerReservation, begin: (ModelRole) -> Unit,
        consume: (ModelRole, ModelBlock, OwnedCanonicalThreadItemAliasCustody) -> Unit) {
        this.owner = owner; this.begin = begin; this.consume = consume
        owner.ensureRetainedPeak(retained)
    }
    func pay(bytes: Int64): Unit { retained = ownedModelAdd113(retained, bytes); owner.ensureRetainedPeak(retained) }
    func startUser(): Unit { mode = 1; begin(ModelRole.User) }
    func startAssistant(): Unit { if (mode != 2) { mode = 2; begin(ModelRole.Assistant) } }
    func startResult(): Unit { if (mode != 3) { mode = 3; begin(ModelRole.User) } }
    func block(role: ModelRole, value: ModelBlock, custody: OwnedCanonicalThreadItemAliasCustody): Unit { consume(role, value, custody) }
    func clear(): Unit { names.clear(); internal.clear(); opaque.clear() }
}
func ownedModelAdd113(a: Int64, b: Int64): Int64 {
    if (a < 0 || b < 0 || a > Int64.Max - b) { throw IllegalStateException("model projection payment overflow") }; a + b
}
func ownedModelMetadataPeak113(a: String, b: String): Int64 {
    let bytes = ownedModelAdd113(a.size, b.size)
    if (bytes > Int64.Max / 8) { throw IllegalStateException("model projection payment overflow") }
    // Detached UTF8 Strings/temporary arrays plus one map/set entry and
    // backing growth. No ThreadItem, DOM, or message is stored in this index.
    ownedModelAdd113(1024, bytes * 8)
}
func compactionModelRequire113(value: Result<Unit>): Unit {
    match (value) { case Result.Ok(_) => (); case Result.Err(error) => throw OwnedCanonicalDataFailure113(error) }
}
public class OwnedCanonicalModelDataError113 <: Exception {
    public let error: AgentError
    public init(error: AgentError) { super("paid canonical model data is unavailable"); this.error = error }
}
func ownedModelMessagesError113(code: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, "canonical model data requires its actual paid prefix"))
}
