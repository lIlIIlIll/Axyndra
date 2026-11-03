package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

private let ownedModelToolsDebts159 = OwnedModelToolsDebts159()

// Independently paid copies used by the actual PreparedModelRequest. The
// source Catalog/ModelLane loan can return after construction. These copies
// remain registered until their own complete request consumer frames return.
// A provider's completion never retires its caller or a storage observer.
public class OwnedModelTools159 <: ModelInputToolsLifetime159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var definitions: ?Array<ModelToolDefinition> = None<Array<ModelToolDefinition>>
    private var preparedReturned = false
    private var consumers: Int64 = 0
    private var firstConsumer: ?OwnedModelToolsConsumer159 = None<OwnedModelToolsConsumer159>
    private var held = false
    var next159: ?OwnedModelTools159 = None<OwnedModelTools159>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment)
        ownedModelToolsDebts159.retain159(this)
    }
    func installCopies159(snapshot: ToolSetSnapshot): Unit {
        lock.lock()
        try {
            if (definitions.isSome() || payment.isNone()) { throw IllegalStateException("model tool copies already installed") }
            definitions = Some(copyModelToolDefinitionsFrame159(snapshot))
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    // Named typed caller contract: these references belong to the prepared
    // request, not to its source Catalog. Unknown escaping consumers keep this
    // registered owner. No callback-Unit or terminal-run acknowledgment exists.
    public func definitionsForPreparedRequest159(): Array<ModelToolDefinition> {
        lock.lock()
        try {
            if (payment.isNone()) { throw IllegalStateException("model tool copies are retired") }
            definitions.getOrThrow()
        } finally { lock.unlock() }
    }
    public func holdUnknownRequestConsumer159(): Unit {
        lock.lock(); try { held = true } finally { lock.unlock() }
    }
    // Only the complete concrete request helper may transfer this marker.
    // It must first clear PreparedModelRequest and all its private raw aliases.
    // Independent provider/store leases are responsible for their own copies.
    public func borrowModelTools159(): ModelInputToolsBorrow159 {
        lock.lock()
        try {
            if (payment.isNone() || preparedReturned || consumers == Int64.Max) {
                throw IllegalStateException("model tool owner cannot admit another input frame")
            }
            let metadata = sharedSnapshotPhase159(payment.getOrThrow(), 4096)
            let value = OwnedModelToolsConsumer159(this, metadata)
            value.next159 = firstConsumer; firstConsumer = Some(value); consumers++
            value
        } finally { lock.unlock() }
    }
    public func closeAfterPreparedFrame159(): Unit {
        let returned = clearPreparedFrame159()
        match (returned) { case Some(value) => value.close(); case None => () }
    }
    private func clearPreparedFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try { preparedReturned = true; detachIfReturned159() }
        finally { lock.unlock() }
    }
    func returnedConsumer159(value: OwnedModelToolsConsumer159): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            var prior: ?OwnedModelToolsConsumer159 = None<OwnedModelToolsConsumer159>
            var cursor = firstConsumer
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (prior) { case Some(p) => p.next159 = current.next159; case None => firstConsumer = current.next159 }
                    current.next159 = None<OwnedModelToolsConsumer159>
                    consumers--
                    return detachIfReturned159()
                }
                prior = cursor; cursor = current.next159
            }
            throw IllegalStateException("model input frame was not registered")
        } finally { lock.unlock() }
    }
    private func detachIfReturned159(): ?LogicalJsonOwnerReservation {
        if (!preparedReturned || consumers != 0 || held || payment.isNone()) { return None<LogicalJsonOwnerReservation> }
        definitions = None<Array<ModelToolDefinition>>
        let returned = payment; payment = None<LogicalJsonOwnerReservation>
        ownedModelToolsDebts159.remove159(this)
        returned
    }
}
class OwnedModelToolsConsumer159 <: ModelInputToolsBorrow159 {
    private let lock = Mutex()
    private var owner: ?OwnedModelTools159
    private var metadata: ?LogicalJsonOwnerReservation
    var next159: ?OwnedModelToolsConsumer159 = None<OwnedModelToolsConsumer159>
    init(owner: OwnedModelTools159, metadata: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.metadata = Some(metadata)
    }
    public func returnModelToolsFrame159(): Unit {
        let payments = clearConsumerFrame159()
        match (payments[0]) { case Some(value) => value.close(); case None => () }
        match (payments[1]) { case Some(value) => value.close(); case None => () }
    }
    private func clearConsumerFrame159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (owner.isNone()) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            let data = owner.getOrThrow().returnedConsumer159(this)
            owner = None<OwnedModelTools159>
            let own = metadata; metadata = None<LogicalJsonOwnerReservation>
            (own, data)
        } finally { lock.unlock() }
    }
}
private func copyModelToolDefinitionsFrame159(snapshot: ToolSetSnapshot): Array<ModelToolDefinition> {
    let copied = ArrayList<ModelToolDefinition>()
    for (entry in snapshot.entries where entry.availableAtSnapshot) {
        // Original names/order/availability and full JsonNode deep-copy
        // semantics are preserved. There is no new whole-tree node/depth cap.
        copied.add(ModelToolDefinition(String.fromUtf8(entry.name.toArray()),
            String.fromUtf8(entry.description.toArray()), copyModelToolSchema159(entry.inputSchema)))
    }
    copied.toArray()
}
// This is a structural copy after the full actual schema invoice. Numeric
// materialize(1) visits one scalar only, preserving the original Int/UInt/Float/
// literal subtype; the default whole-tree materialize limit is never applied.
private func copyModelToolSchema159(value: AgentValue): AgentValue {
    if (value.unifiedKind == ValueKind.Text) {
        return textValue(String.fromUtf8(value.text.toArray()))
    }
    if (value.unifiedKind == ValueKind.Number) { return value.materialize(1) }
    if (value.unifiedKind == ValueKind.Null) { return nullValue() }
    if (value.unifiedKind == ValueKind.Boolean) { return boolValue(value.asBool()) }
    if (value.unifiedKind == ValueKind.List) {
        let source = value.asArray()
        let copied = JsonArray()
        for (index in 0..source.size()) {
            copied.insert(copied.size(), copyModelToolSchema159(source.get(index).getOrThrow()))
        }
        return copied
    }
    if (value.unifiedKind == ValueKind.Object) {
        let source = value.asObject()
        let copied: AgentValue = JsonObject()
        for (index in 0..source.size()) {
            copied.put(String.fromUtf8(source.nameAt(index).toArray()),
                copyModelToolSchema159(source.valueAt(index)))
        }
        return copied
    }
    throw IllegalArgumentException("unsupported original model schema node")
}
private class OwnedModelToolsDebts159 {
    private let lock = Mutex()
    private var first: ?OwnedModelTools159 = None<OwnedModelTools159>
    func retain159(value: OwnedModelTools159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedModelTools159): Unit {
        lock.lock()
        try {
            var prior: ?OwnedModelTools159 = None<OwnedModelTools159>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (prior) { case Some(parent) => parent.next159 = current.next159; case None => first = current.next159 }
                    current.next159 = None<OwnedModelTools159>; return
                }
                prior = cursor; cursor = current.next159
            }
        } finally { lock.unlock() }
    }
}
