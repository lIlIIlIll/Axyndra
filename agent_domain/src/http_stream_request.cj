package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// The logical result limit remains semantic. Only an actual ModelAttempt
// owner may select this small, fixed allowance for provider SSE envelopes.
// This pure bound calculation grants no process or network authority.
public let MODEL_HTTP_ENVELOPE_BYTES: Int64 = 65536

// Exact generic HTTP bytes. This DTO is neither a network grant nor proof of
// canonical handoff. The same validator is used by preparation and execution.
public let HOST_HTTP_STREAM_REQUEST_MAX_BYTES: Int64 = 65536
public let HOST_HTTP_STREAM_RESPONSE_MAX_BYTES: Int64 = 1048576
public let HOST_HTTP_STREAM_PAYLOAD_REQUEST_MAX_BYTES: Int64 = 4194304
public let HOST_HTTP_STREAM_PAYLOAD_RESPONSE_MAX_BYTES: Int64 = 8388608
public let HOST_HTTP_STREAM_ENCODED_MAX_BYTES: Int64 = 8585216

public func modelHttpWireMaximum(semanticBytes: Int64): Int64 {
    if (semanticBytes < 1 || semanticBytes > HOST_HTTP_STREAM_PAYLOAD_RESPONSE_MAX_BYTES) {
        throw IllegalArgumentException("invalid model semantic response bound")
    }
    semanticBytes + MODEL_HTTP_ENVELOPE_BYTES
}

public func httpStreamEndpoint(url: String): Result<HttpServiceEndpoint> {
    if (url.size > 16384 || url.contains("#") || url.contains("\\")) {
        return httpIntentError("http.stream_url_invalid", "HTTP stream URL is invalid or oversized")
    }
    for (byte in url.toArray() where byte < 33u8 || byte > 126u8) {
        return httpIntentError("http.stream_url_invalid", "HTTP stream URL requires visible ASCII")
    }
    let query = url.indexOf("?")
    let base = match (query) { case Some(index) => url[..index]; case None => url }
    // Grant matching uses the configured origin/path. Query bytes remain in
    // the approved request verbatim, including order and duplicate parameters.
    httpServiceEndpoint(base)
}

public func httpStreamRequestBody(value: AgentValue, maximumBytes!: Int64 = HOST_HTTP_STREAM_REQUEST_MAX_BYTES): Result<Array<Byte>> {
    let body = match (value.field("body_hex")) {
        case Some(item) => item
        case None => return httpIntentError("http.stream_body_invalid", "HTTP stream request omitted its exact body")
    }
    if (body.unifiedKind != ValueKind.Text || maximumBytes < 1 || maximumBytes > HOST_HTTP_STREAM_PAYLOAD_REQUEST_MAX_BYTES || body.text.size > maximumBytes * 2 ||
        body.text.size % 2 != 0) {
        return httpIntentError("http.stream_body_invalid", "HTTP stream body exceeds the finite byte bound")
    }
    let bytes = body.text.toArray()
    let result = Array<Byte>(bytes.size / 2, repeat: 0)
    for (index in 0..result.size) {
        let high = channelIntentHex(bytes[index * 2]); let low = channelIntentHex(bytes[index * 2 + 1])
        if (high < 0 || low < 0) {
            return httpIntentError("http.stream_body_invalid", "HTTP stream body requires lowercase hexadecimal")
        }
        result[index] = UInt8(high * 16 + low)
    }
    Result.Ok(result)
}

public func validateHttpStreamRequest(value: AgentValue, maximumBytes!: Int64 = HOST_HTTP_STREAM_REQUEST_MAX_BYTES,
    responseBytes!: Int64 = HOST_HTTP_STREAM_RESPONSE_MAX_BYTES, allowPayload!: Bool = false,
    timeoutMaximum!: Int64 = 120000, allowZeroTimeout!: Bool = false, modelEnvelope!: Bool = false): Result<Unit> {
    let referenced = value.field("body_payload").isSome()
    if (timeoutMaximum < 1 || maximumBytes < 1 || maximumBytes > HOST_HTTP_STREAM_PAYLOAD_REQUEST_MAX_BYTES ||
        responseBytes < 1 || responseBytes > HOST_HTTP_STREAM_PAYLOAD_RESPONSE_MAX_BYTES + (if (modelEnvelope) { MODEL_HTTP_ENVELOPE_BYTES } else { 0 }) ||
        (referenced && !allowPayload) || !httpIntentExactFields(value, ["method", "url", "headers",
        if (referenced) { "body_payload" } else { "body_hex" }, "credential_refs",
        "timeout_ms", "max_response_bytes"]) || stringifyUnifiedJson(value).size > maximumBytes * 2 + 196608) {
        return httpIntentError("http.stream_request_invalid", "HTTP stream request fields are invalid or oversized")
    }
    let method = httpIntentText(value, "method")
    if (method != "GET" && method != "POST") {
        return httpIntentError("http.stream_method_invalid", "HTTP stream supports GET and POST")
    }
    match (httpStreamEndpoint(httpIntentText(value, "url"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
    }
    let bodyBytes = match (httpStreamRequestBodySize(value, maximumBytes, allowPayload)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(bytes) => bytes
    }
    if (method == "GET" && bodyBytes != 0) {
        return httpIntentError("http.stream_body_invalid", "GET must have an empty body")
    }
    let headers = value.field("headers").getOrThrow()
    if (headers.unifiedKind != ValueKind.Object || headers.fields.size > 32) {
        return httpIntentError("http.stream_headers_invalid", "HTTP stream headers must be bounded")
    }
    let seen = HashSet<String>()
    for (field in headers.fields) {
        let key = field.name.toAsciiLower()
        if (!httpServiceHeaderAllowed(key) || seen.contains(key) ||
            field.value.unifiedKind != ValueKind.Text || field.value.text.size > 4096) {
            return httpIntentError("http.stream_headers_invalid", "HTTP stream header is repeated, host-controlled or invalid")
        }
        seen.add(key)
        for (byte in field.value.text.toArray() where byte < 32u8 || byte == 127u8) {
            return httpIntentError("http.stream_headers_invalid", "HTTP stream header contains controls")
        }
    }
    let refs = value.field("credential_refs").getOrThrow()
    if (refs.unifiedKind != ValueKind.List || refs.items.size > 4) {
        return httpIntentError("http.stream_credentials_invalid", "HTTP stream accepts at most four credential references")
    }
    let seenRefs = HashSet<String>()
    for (item in refs.items) {
        if (item.unifiedKind != ValueKind.Text || !httpIntentIdentifier(item.text) || seenRefs.contains(item.text)) {
            return httpIntentError("http.stream_credentials_invalid", "HTTP stream credential references must be unique")
        }
        seenRefs.add(item.text)
    }
    for ((name, maximum) in [("timeout_ms", timeoutMaximum), ("max_response_bytes", responseBytes)]) {
        let field = value.field(name).getOrThrow()
        let parsed = try { Int64.parse(field.asNumberText()) } catch (_: Exception) { 0 }
        if (field.unifiedKind != ValueKind.Number || parsed < (if (name == "timeout_ms" && allowZeroTimeout) { 0 } else { 1 }) || parsed > maximum ||
            parsed.toString() != field.asNumberText()) {
            return httpIntentError("http.stream_limits_invalid", "HTTP stream requires canonical finite time and output limits")
        }
    }
    Result.Ok(())
}

public func httpStreamRequestPolicy(request: AgentValue, policy: NetworkPolicy,
    maximumBytes!: Int64 = HOST_HTTP_STREAM_REQUEST_MAX_BYTES, responseBytes!: Int64 = HOST_HTTP_STREAM_RESPONSE_MAX_BYTES,
    allowPayload!: Bool = false, timeoutMaximum!: Int64 = 120000, allowZeroTimeout!: Bool = false, modelEnvelope!: Bool = false): Result<Unit> {
    match (validateHttpStreamRequest(request, maximumBytes: maximumBytes, responseBytes: responseBytes, allowPayload: allowPayload,
        timeoutMaximum: timeoutMaximum, allowZeroTimeout: allowZeroTimeout, modelEnvelope: modelEnvelope)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let endpoint = match (httpStreamEndpoint(httpIntentText(request, "url"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
    }
    if (policy.mode != NetworkPolicyMode.Mediated || policy.egress.size != 1 || !policy.publish.isEmpty() ||
        policy.egress[0].host != endpoint.host || policy.egress[0].port != endpoint.port) {
        return httpIntentError("http.stream_network_invalid", "HTTP stream must mediate exactly its own origin")
    }
    Result.Ok(())
}

// A reference is only an immutable description. The canonical Store must still
// verify the exact preparation witness, source and handoff before content IO.
public func httpStreamRequestBodySize(value: AgentValue, maximum: Int64, allowPayload: Bool): Result<Int64> {
    match (value.field("body_payload")) {
        case Some(payload) =>
            if (!allowPayload || value.field("body_hex").isSome()) {
                return httpIntentError("http.stream_payload_not_granted", "HTTP body payload requires its exact operator profile")
            }
            servicePayloadReferenceBytes(payload, maximum)
        case None => match (httpStreamRequestBody(value, maximumBytes: maximum)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(bytes) => Result.Ok(bytes.size)
        }
    }
}
public func httpStreamPayloadCanonicalBytes(binding: AgentValue): Int64 {
    match (servicePayloadLimits(binding).value().getOrThrow()) {
        case Some(value) => value.maxMessageBytes - 65536
        case None => serviceProtocolLimits(binding).value().getOrThrow().canonicalBytes
    }
}
