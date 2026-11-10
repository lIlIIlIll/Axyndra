package agent_tui

// Fixed-size diagnostic DATA. A completed coalesced frame must not lose an
// actual interactive input merely because a later async event labels it.
// No text, payload, capability or task/transport acknowledgment is recorded.
class TuiFrameInputKind240 {
    let name: String
    var count: Int64 = 0
    var firstNanos: Int64 = 0
    init(name: String) { this.name = name }
}
class TuiFrameInputs240 {
    private let kinds = [TuiFrameInputKind240("key_down"), TuiFrameInputKind240("paste"),
        TuiFrameInputKind240("mouse"), TuiFrameInputKind240("resize"), TuiFrameInputKind240("timer")]
    func received240(name: String, nanos: Int64): Unit {
        for (kind in kinds where kind.name == name) {
            if (kind.count == 0) { kind.firstNanos = nanos }
            kind.count = min(kind.count, Int64.Max - 1) + 1
        }
    }
    func value240(): String {
        var value = "["
        var separator = ""
        for (kind in kinds where kind.count > 0) {
            value += separator + "{\"event\":\"" + kind.name + "\",\"count\":" + kind.count.toString() +
                ",\"first_received_ns\":" + kind.firstNanos.toString() + "}"
            separator = ","
        }
        value + "]"
    }
    func clear240(): Unit {
        for (kind in kinds) { kind.count = 0; kind.firstNanos = 0 }
    }
}
