package agent_app

import agent_domain.*
import agent_tui.TuiTurnResult
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Logical View-action DATA only. Physical broker limits and the original
// owner bank remain authoritative; no Tool or execution request is created.
let TUI_OWNER_VIEW_INPUT_BYTES180: Int64 = 16777216
let TUI_OWNER_VIEW_INPUT_WINDOW180 = "tui.view-action/v1"

class TuiOwnerViewInput180 {
    let sequence: Int64
    let deadline180 = MonoTime.now() + Duration.second * 5
    private var receiver: ?LogicalJsonReceiver
    private var decoded: ?AgentValue = None
    private var copied: ?TuiOwnerViewCallData180 = None
    var complete = false
    init(source: LogicalJsonOwnerReservation, sequence: Int64) {
        this.sequence = sequence
        let until = deadline180
        receiver = Some(source.acquireLogicalReceiverData(TUI_OWNER_VIEW_INPUT_BYTES180,
            TUI_OWNER_VIEW_INPUT_WINDOW180, sequence, "pluginViewAction", { =>
                if (MonoTime.now() >= until) { throw Exception("tui.owner_view_input_timeout") }
            }))
    }
    func accept(kind: String, header: AgentValue): ?AgentValue {
        let value = receiver.getOrThrow().accept(kind, header)
        if (value.isSome()) { decoded = value; complete = true }
        value
    }
    func bindCopiedData(value: TuiOwnerViewCallData180): Unit {
        if (!complete || copied.isSome()) { throw Exception("tui.owner_view_input_handoff_invalid") }
        copied = Some(value)
    }
    // Called only after the complete reader/decoder/capture helper returns.
    // Its raw buffer and DOM cannot overlap the worker's pending freeze.
    func retireAfterWholeReaderHelper180(): Unit {
        decoded = None
        match (receiver) { case Some(value) => value.close(); receiver = None; case None => () }
        let value = copied; copied = None
        match (value) { case Some(data) => data.readerReturned180.dec(); case None => () }
    }
}

// The caller prepays the complete existing TUI DATA invoice before creating
// this capsule, counter or genuinely independent UTF-8/DOM copy. Its Future
// retains this empty carrier after the closed request helper returns.
class TuiOwnerViewCallData180 {
    private var value: ?AgentValue
    private var payment: ?LogicalJsonOwnerReservation
    let readerReturned180 = SyncCounter(1)
    init(original: AgentValue, paid: LogicalJsonOwnerReservation) {
        payment = Some(paid)
        value = Some(tuiOwnerCopyViewCallData180(original))
    }
    func withArguments180(consume: (AgentValue) -> TuiTurnResult): TuiTurnResult {
        consumeArgumentsHelper180(consume)
    }
    private func consumeArgumentsHelper180(consume: (AgentValue) -> TuiTurnResult): TuiTurnResult {
        consume(value.getOrThrow().items[3])
    }
    func retireAfterWholeInvocationHelper180(): Unit {
        value = None
        match (payment) { case Some(paid) => paid.close(); payment = None; case None => () }
    }
}

// The private owner wire admits arrays and scalars, not arbitrary object
// dispatch. Avoid a full JSON stringify/parse merely to obtain this copy.
private func tuiOwnerCopyViewCallData180(value: AgentValue): AgentValue {
    if (value.unifiedKind == ValueKind.Text) { return textValue(String.fromUtf8(value.text.toArray())) }
    if (value.unifiedKind == ValueKind.Number) { return value.materialize(1) }
    if (value.unifiedKind == ValueKind.Null) { return nullValue() }
    if (value.unifiedKind == ValueKind.Boolean) { return boolValue(value.asBool()) }
    if (value.unifiedKind == ValueKind.List) {
        let source = value.asArray()
        let copied = JsonArray()
        for (index in 0..source.size()) {
            copied.insert(copied.size(), tuiOwnerCopyViewCallData180(source.get(index).getOrThrow()))
        }
        return copied
    }
    throw Exception("tui.owner_unexpected_object")
}
