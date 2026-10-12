package native_model_providers

import agent_domain.*
import model_adapters.*
import model_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// ProviderSpec and wire codecs retain their existing behavior. This transport
// owns no sockets, OS processes, environment lookup, credentials or retries.
class BrokerModelTransport <: ProviderTransport {
    private let input: ModelInput
    private let output: ModelOutput
    private let refs: Array<String>
    private var serial: Int64 = 0
    private var used = false
    private var responseBudget: ?LogicalJsonOwnerReservation = None
    public func usesIncrementalStreamReply(): Bool { true }
    func closeBudget(): Unit {
        match (responseBudget) { case Some(value) => value.close(); responseBudget = None; case None => () }
    }
    init(input: ModelInput, output: ModelOutput, refs: Array<String>) {
        this.input = input; this.output = output; this.refs = refs.clone()
    }
    private func request(action: String, arguments: AgentValue): AgentValue {
        serial += 1
        output.request(serial, action, arguments)
        let message = input.readMessage()
        try {
        let frame = message.value
        exact(frame, ["schema", "type", "identity", "sequence", "action", "ok", "result"])
        need(txt(frame, "schema") == MODEL_WIRE_SCHEMA && txt(frame, "type") == "http_response" &&
            output.sameIdentity(field(frame, "identity")) && num(frame, "sequence") == serial && txt(frame, "action") == action)
        if (!flag(frame, "ok")) { throw ModelWireFailure("model.http_transport_failed") }
        // HTTP replies carry only bounded head metadata or one16KiB chunk.
        // Copy this small value before releasing its shared message charge.
        parseUnifiedJson(field(frame, "result").stringify(), maxBytes: 65536)
        } finally { message.close() }
    }
    public func post(provider: ProviderSpec, payload: String, streaming: Bool,
        requestId: String, chunks: (String) -> Unit): Result<String> {
        let _ = requestId
        if (used) { return Result.Err(AgentError(AgentErrorKind.Protocol, "model.http_repeated", "one Attempt may dispatch one provider request")) }
        used = true
        var opened = false
        var closed = false
        try {
            // The response/decoder's retained allocation shares the same
            // worker pool as physical/logical frames. Keep this charge until
            // adapter parsing and the final typed terminal have completed.
            responseBudget = Some(reserveModelProviderResponse())
            need(payload.size <= input.payloadWriteMaximum())
            let headers = ArrayList<ValueField>([ValueField("content-type", textValue("application/json")),
                ValueField("accept", textValue(if (streaming) { "text/event-stream" } else { "application/json" }))])
            let seen = HashSet<String>(["content-type", "accept"])
            for (values in [provider.profileHeaders, provider.modelHeaders]) { for (header in values) {
                let name = header.name.toAsciiLower()
                // Honor the adapter's last-value-wins behavior while rejecting
                // credentials using the existing ProviderHeader constructor.
                if (seen.contains(name)) {
                    for (index in 0..headers.size) { if (headers[index].name == name) { headers.remove(at: index); break } }
                }
                seen.add(name); headers.add(ValueField(name, textValue(header.value)))
            } }
            let raw = objectValue([ValueField("method", textValue("POST")), ValueField("url", textValue(provider.endpoint())),
                ValueField("headers", objectValue(headers.toArray())), ValueField("body_hex", textValue(hex(payload.toArray()))),
                ValueField("credential_refs", listValue(refs.map { ref => textValue(ref) })),
                ValueField("timeout_ms", integerValue(provider.timeoutMillis)),
                ValueField("max_response_bytes", integerValue(input.responseMaximum()))])
            let open = request("open", objectValue([ValueField("request", raw)]))
            exact(open, ["opened"]); need(flag(open, "opened")); opened = true
            var head: ?AgentValue = None
            while (head.isNone()) {
                let polled = request("head", objectValue([]))
                if (polled.unifiedKind != ValueKind.Null) { head = Some(polled) }
            }
            let metadata = head.getOrThrow(); exact(metadata, ["status", "content_type", "retry_after"])
            let status = num(metadata, "status"); need(status >= 200 && status <= 599)
            let body = ArrayList<Byte>(); let line = ArrayList<Byte>()
            var eof = false
            var receivedBytes: Int64 = 0
            while (!eof) {
                let read = request("read", objectValue([])); exact(read, ["bytes_hex", "eof"])
                let bytes = unhex(txt(read, "bytes_hex")); eof = flag(read, "eof")
                need(bytes.size <= input.responseMaximum() - receivedBytes)
                receivedBytes += bytes.size
                // A conservative monotonic reservation includes decoder
                // state and complete non-streaming/error bodies. Successful
                // SSE does not retain the transport bytes a second time.
                responseBudget.getOrThrow().ensureDecoded(receivedBytes, 65536)
                if (!(streaming && status >= 200 && status < 300)) { body.add(all: bytes) }
                if (streaming && status >= 200 && status < 300) { for (byte in bytes) {
                    line.add(byte)
                    // UTF-8 is decoded only after a complete SSE line. A
                    // network chunk may split a Unicode code point anywhere.
                    if (byte == 10u8) { chunks(String.fromUtf8(line.toArray())); line.clear() }
                } }
            }
            if (streaming && !line.isEmpty() && status >= 200 && status < 300) { chunks(String.fromUtf8(line.toArray())) }
            let end = request("close", objectValue([])); exact(end, ["closed"]); need(flag(end, "closed")); closed = true
            let text = if (streaming && status >= 200 && status < 300) { "" }
                else { String.fromUtf8(body.toArray()) }
            if (status < 200 || status >= 300) {
                return Result.Err(modelProviderHttpFailure(status, text, provider.id, txt(metadata, "retry_after")))
            }
            Result.Ok(text)
        } catch (_: Exception) {
            Result.Err(AgentError(AgentErrorKind.Transport, "model.http_interrupted", "provider HTTP exchange was not completed",
                attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTransportError))))
        } finally {
            if (opened && !closed) { try { let _ = request("close", objectValue([])) } catch (_: Exception) {} }
        }
    }
}
