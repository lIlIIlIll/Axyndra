package agent_rpc

import agent_domain.*
import yjson.*
import yjson_support.*

// The decoded RPC graph is private and immutable after dispatch. Pay its real
// captured UTF-8/DOM and worker carriers before spawning; no serialized copy or
// source authority is created by this numeric walk.
func rpcViewCapturedShape(value: AgentValue, depth: Int64): (Int64, Int64) {
    if (depth > 32) { throw LogicalJsonPayloadError("View RPC input exceeds its existing codec depth") }
    var bytes: Int64 = 0; var nodes: Int64 = 1
    if (value.unifiedKind == ValueKind.Object) {
        for (field in value.fields) {
            let child = rpcViewCapturedShape(field.value, depth + 1)
            bytes = rpcViewInvoiceAdd(bytes, rpcViewInvoiceAdd(field.name.size, child[0]))
            nodes = rpcViewInvoiceAdd(nodes, child[1])
        }
    } else if (value.unifiedKind == ValueKind.List) {
        for (item in value.items) {
            let child = rpcViewCapturedShape(item, depth + 1)
            bytes = rpcViewInvoiceAdd(bytes, child[0]); nodes = rpcViewInvoiceAdd(nodes, child[1])
        }
    } else if (value.unifiedKind == ValueKind.Text) { bytes = value.text.size }
    else if (value.unifiedKind == ValueKind.Number) { bytes = value.asNumberText().size }
    (bytes, nodes)
}

func rpcViewInvoiceAdd(first: Int64, second: Int64): Int64 {
    if (first < 0 || second < 0 || first > Int64.Max - second) {
        throw LogicalJsonPayloadError("View RPC DATA invoice overflow") }
    first + second
}

func rpcViewRequestPeak(value: AgentValue): Int64 {
    let shape = rpcViewCapturedShape(value, 0)
    if (shape[0] > (Int64.Max - 65536) / 8 || shape[1] > Int64.Max / 1024) {
        throw LogicalJsonPayloadError("View RPC DATA invoice overflow") }
    rpcViewInvoiceAdd(65536 + shape[0] * 8, shape[1] * 1024)
}

// Called only after the complete captured-shape invoice. The worker must not
// keep aliases into the retiring input message or pay an avoidable JSON
// stringify/parse round trip merely to obtain an independent private graph.
func rpcViewCopyCapturedValue(value: AgentValue): AgentValue {
    if (value.unifiedKind == ValueKind.Text) { return textValue(String.fromUtf8(value.text.toArray())) }
    if (value.unifiedKind == ValueKind.Number) { return value.materialize(1) }
    if (value.unifiedKind == ValueKind.Null) { return nullValue() }
    if (value.unifiedKind == ValueKind.Boolean) { return boolValue(value.asBool()) }
    if (value.unifiedKind == ValueKind.List) {
        let source = value.asArray()
        let copied = JsonArray()
        for (index in 0..source.size()) {
            copied.insert(copied.size(), rpcViewCopyCapturedValue(source.get(index).getOrThrow()))
        }
        return copied
    }
    if (value.unifiedKind == ValueKind.Object) {
        let source = value.asObject()
        let copied: AgentValue = JsonObject()
        for (index in 0..source.size()) {
            copied.put(String.fromUtf8(source.nameAt(index).toArray()),
                rpcViewCopyCapturedValue(source.valueAt(index)))
        }
        return copied
    }
    throw LogicalJsonPayloadError("View RPC input has an unsupported JSON kind")
}

// One real private graph, separate from its Future/output metadata. Only the
// closed request helper reads value; clearing follows that helper's return.
// Unexpected throws keep the data lease charged rather than inventing an ACK.
class RpcPluginViewRequestData {
    var value: ?AgentValue
    private var payment: ?LogicalJsonOwnerReservation
    init(original: AgentValue, paid: LogicalJsonOwnerReservation) {
        this.payment = Some(paid)
        value = Some(rpcViewCopyCapturedValue(original))
    }
    func clearAfterWholeRequestHelper(): Unit {
        value = None
        match (payment) { case Some(paid) => paid.close(); payment = None; case None => () }
    }
}
