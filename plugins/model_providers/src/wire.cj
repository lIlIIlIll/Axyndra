package native_model_providers

import agent_domain.*
import model_provider_runtime.*
import process4cj as process
import std.collection.*
import std.convert.*
import std.io.*
import std.env.*
import std.time.*
import yjson.*
import yjson_support.*

let MODEL_WIRE_SCHEMA = "axyndra.model-provider/v1"
let MODEL_NATIVE_FRAME: Int64 = 262144
class ModelWireFailure <: Exception { init(message: String) { super(message) } }
func need(ok: Bool): Unit { if (!ok) { throw ModelWireFailure("model.plugin_protocol_invalid") } }
func field(value: AgentValue, name: String): AgentValue { value.field(name).getOrThrow() }
func txt(value: AgentValue, name: String): String { let item = field(value, name); need(item.unifiedKind == ValueKind.Text); item.text }
func num(value: AgentValue, name: String): Int64 {
    let item = field(value, name); need(item.unifiedKind == ValueKind.Number)
    let n = Int64.parse(item.asNumberText()); need(n.toString() == item.asNumberText()); n
}
func flag(value: AgentValue, name: String): Bool { let item = field(value, name); need(item.unifiedKind == ValueKind.Boolean); item.asBool() }
func exact(value: AgentValue, names: Array<String>): Unit {
    need(value.unifiedKind == ValueKind.Object && value.fields.size == names.size)
    for (name in names) { need(value.field(name).isSome()) }
}
func hex(bytes: Array<Byte>): String {
    let alphabet = "0123456789abcdef".toArray(); let out = ArrayList<Byte>()
    for (byte in bytes) { out.add(alphabet[Int64(byte / 16u8)]); out.add(alphabet[Int64(byte % 16u8)]) }
    String.fromUtf8(out.toArray())
}
func unhex(text: String): Array<Byte> {
    need(text.size % 2 == 0 && text.size <= 32768)
    let result = ArrayList<Byte>(); let bytes = text.toArray()
    for (index in 0..(bytes.size / 2)) {
        let a = digit(bytes[index * 2]); let b = digit(bytes[index * 2 + 1]); result.add(a * 16u8 + b)
    }
    result.toArray()
}
func digit(byte: Byte): Byte {
    if (byte >= b'0' && byte <= b'9') { byte - b'0' }
    else if (byte >= b'a' && byte <= b'f') { byte - b'a' + 10u8 }
    else { throw ModelWireFailure("model.plugin_hex_invalid") }
}

// Borrow fd 0 exactly once. Polling yields to the runtime rather than holding
// ConsoleReader/getc across GC. This endpoint never owns or closes the fd.
class ModelInput {
    private var buffered: Array<Byte> = []
    private var eof = false
    private var active = false
    private var logical: ?ModelProviderLogicalWire = None
    private var selectedLimits: ?ServicePayloadLimits = None
    func activate(): Unit { active = true }
    func configure(identity: AgentValue, window: String, limits: ServicePayloadLimits): Unit {
        need(logical.isNone())
        selectedLimits = Some(limits)
        logical = Some(ModelProviderLogicalWire(identity, window, limits, { => Result.Ok(()) }, { =>
            match (read()) { case Some(value) => Result.Ok(value)
                case None => Result.Err(AgentError(AgentErrorKind.Transport, "model.host_eof", "actual model host closed its channel")) }
        }, { value => rawWrite(value); Result.Ok(()) }))
    }
    func responseMaximum(): Int64 { match (selectedLimits) { case Some(value) => modelHttpWireMaximum(value.maxResultBytes); case None => 1048576 } }
    func payloadWriteMaximum(): Int64 { match (selectedLimits) { case Some(value) => value.maxWriteBytes; case None => 65536 } }
    func readMessage(): ModelProviderMessage {
        match (logical) { case Some(value) => match (value.receive()) {
                case Result.Ok(message) => message
                case Result.Err(_) => throw ModelWireFailure("model.logical_message_invalid")
            }
            case None => ModelProviderMessage(read().getOrThrow(), { => () })
        }
    }
    func sendMessage(value: AgentValue): Unit {
        match (logical) { case None => rawWrite(value)
            case Some(wire) => match (wire.send(value)) { case Result.Ok(_) => ()
                case Result.Err(_) => throw ModelWireFailure("model.logical_message_invalid") }
        }
    }
    func read(): ?AgentValue {
        let deadline = MonoTime.now() + Duration.second * 120
        while (true) {
            for (index in 0..buffered.size where buffered[index] == 10u8) {
                let line = buffered[..index].clone(); buffered = buffered[(index + 1)..].clone()
                need(line.size > 0 && line.size <= MODEL_NATIVE_FRAME)
                let source = String.fromUtf8(line); let _ = logicalJsonNodeCount(source)
                return Some(parseUnifiedJson(source, maxBytes: MODEL_NATIVE_FRAME, maxDepth: 64))
            }
            need(buffered.size <= MODEL_NATIVE_FRAME)
            if (eof) { need(buffered.isEmpty()); return None }
            // During inference the actual host Attempt/Run controls deadline
            // and process cancellation. Do not invent a second120s lifetime.
            need(active || MonoTime.now() < deadline)
            if (process.waitReadableFd(0, 10)) {
                match (process.readFdChunk(0, maxBytes: 8192)) {
                    case None => eof = true
                    case Some(bytes) => let next = ArrayList<Byte>(buffered); next.add(all: bytes); buffered = next.toArray()
                }
            } else { sleep(Duration.millisecond) }
        }
        None
    }
}
class ModelOutput {
    private let identity: AgentValue
    private let input: ModelInput
    private var sequence: Int64 = 0
    init(identity: AgentValue, input: ModelInput) { this.identity = parseUnifiedJson(identity.stringify()); this.input = input }
    func write(value: AgentValue): Unit {
        input.sendMessage(value)
    }
    func event(kind: String, payload: AgentValue): Unit {
        // Keep text events physical. Logical hex chunks would double the
        // same text against the unchanged host process output budget.
        if (kind == "event" && payload.field("kind").isSome() &&
            ["text", "reasoning"].contains(txt(payload, "kind")) && txt(payload, "text").size > 16384) {
            let bytes = txt(payload, "text").toArray(); var offset: Int64 = 0
            while (offset < bytes.size) {
                var end = min(bytes.size, offset + 16384)
                while (end < bytes.size && (bytes[end] & 0xc0u8) == 0x80u8) { end-- }
                need(end > offset)
                event(kind, objectValue([ValueField("kind", field(payload, "kind")),
                    ValueField("text", textValue(String.fromUtf8(bytes[offset..end])))]))
                offset = end
            }
            return
        }
        sequence += 1
        write(objectValue([ValueField("schema", textValue(MODEL_WIRE_SCHEMA)), ValueField("identity", identity),
            ValueField("sequence", integerValue(sequence)), ValueField("kind", textValue(kind)), ValueField("payload", payload)]))
    }
    func request(sequence: Int64, action: String, arguments: AgentValue): Unit {
        write(objectValue([ValueField("schema", textValue(MODEL_WIRE_SCHEMA)), ValueField("identity", identity),
            ValueField("type", textValue("http_request")), ValueField("sequence", integerValue(sequence)),
            ValueField("action", textValue(action)), ValueField("arguments", arguments)]))
    }
    func done(): Unit { write(objectValue([ValueField("schema", textValue(MODEL_WIRE_SCHEMA)),
        ValueField("identity", identity), ValueField("type", textValue("done"))])) }
    func sameIdentity(other: AgentValue): Bool { canonicalAgentValue(other) == canonicalAgentValue(identity) }
}
