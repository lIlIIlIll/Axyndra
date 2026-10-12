package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Private fixed-curl preparation; never an executable/argv contribution point.
// Only an admitted executor may resolve and supply credential values. The
// returned argv and secrets have no wire/durable representation.
public class HostHttpStreamLaunch {
    public let request: AgentValue
    public let arguments: Array<String>
    public let body: Array<Byte>
    public let secrets: Array<String>
    public let maxBodyBytes: Int64
    public let timeoutMillis: Int64
    init(request: AgentValue, arguments: Array<String>, body: Array<Byte>, secrets: Array<String>) {
        this.request = request; this.arguments = arguments; this.body = body; this.secrets = secrets
        this.maxBodyBytes = Int64.parse(request.field("max_response_bytes").getOrThrow().asNumberText())
        this.timeoutMillis = Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText())
    }
}

public func prepareHostHttpStreamLaunch(raw: AgentValue, credentials: Array<HostPluginHttpCredentialValue>,
    policy: NetworkPolicy, payloadBody!: ?Array<Byte> = None, expanded!: Bool = false,
    timeoutMaximum!: Int64 = 120000, allowZeroTimeout!: Bool = false, modelEnvelope!: Bool = false): Result<HostHttpStreamLaunch> {
    let request = try { parseUnifiedJson(stringifyUnifiedJson(raw), maxBytes: if (expanded) { HOST_HTTP_STREAM_ENCODED_MAX_BYTES } else { 196608 }) }
        catch (_: Exception) { return hostPluginHttpConfigError("http.stream_request_invalid", "HTTP request could not be frozen") }
    let maximum = if (expanded) { HOST_HTTP_STREAM_PAYLOAD_REQUEST_MAX_BYTES } else { HOST_HTTP_STREAM_REQUEST_MAX_BYTES }
    let response = if (expanded) { if (modelEnvelope) { modelHttpWireMaximum(HOST_HTTP_STREAM_PAYLOAD_RESPONSE_MAX_BYTES) } else { HOST_HTTP_STREAM_PAYLOAD_RESPONSE_MAX_BYTES } } else { HOST_HTTP_STREAM_RESPONSE_MAX_BYTES }
    match (httpStreamRequestPolicy(request, policy, maximumBytes: maximum, responseBytes: response, allowPayload: expanded,
        timeoutMaximum: timeoutMaximum, allowZeroTimeout: allowZeroTimeout, modelEnvelope: modelEnvelope)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let refs = request.field("credential_refs").getOrThrow().items
    if (credentials.size != refs.size) {
        return hostPluginHttpConfigError("http.stream_credentials_invalid", "HTTP credentials do not match the bound references")
    }
    let args = ArrayList<String>(["-q", "--silent", "--show-error", "--globoff", "--path-as-is",
        "--proto", "=http,https", "--proto-redir", "=http,https", "--max-redirs", "0",
        "--connect-timeout", "10", "--include", "--no-buffer", "--suppress-connect-headers",
        "--max-filesize", request.field("max_response_bytes").getOrThrow().asNumberText(),
        "--request", httpIntentText(request, "method"), "--url", httpIntentText(request, "url")])
    let headers = request.field("headers").getOrThrow()
    let targets = HashSet<String>()
    for (field in headers.fields) {
        targets.add(field.name.toAsciiLower())
        args.add("--header")
        // curl's semicolon syntax sends an explicitly empty value instead of
        // suppressing the header. Names are validated tokens without ';'.
        args.add(field.name + if (field.value.text == "") { ";" } else { ": " + field.value.text })
    }
    let secrets = ArrayList<String>()
    for (index in 0..credentials.size) {
        let credential = credentials[index]
        let header = credential.header.toAsciiLower()
        if (credential.ref != refs[index].text || credential.jsonPointer != "" ||
            (header != "authorization" && !httpServiceHeaderAllowed(header)) || targets.contains(header) ||
            credential.secret == "" || !hostPluginHttpHeaderPrefixValid(credential.headerPrefix) ||
            credential.headerValue().size > HOST_PLUGIN_HTTP_SECRET_MAX_BYTES) {
            return hostPluginHttpConfigError("http.stream_credentials_invalid", "HTTP stream credentials require unique authorized headers")
        }
        for (byte in credential.secret.toArray() where byte < 32u8 || byte > 126u8) {
            return hostPluginHttpConfigError("http.stream_credentials_invalid", "HTTP stream header credentials must contain visible ASCII")
        }
        targets.add(header); for (value in credential.redactedValues()) { secrets.add(value) }
        args.add("--header"); args.add(header + ": " + credential.headerValue())
    }
    // Disable curl's conditional Expect generation; the exact body is fed as
    // binary stdin and then half-closed. No shell, temp body file or JSON rewrite.
    args.add("--header"); args.add("Expect:")
    if (httpIntentText(request, "method") == "POST") {
        args.add("--data-binary"); args.add("@-")
    }
    let body = match (request.field("body_payload")) {
        case Some(reference) =>
            let count = servicePayloadReferenceBytes(reference, maximum).value().getOrThrow()
            if (payloadBody.isNone() || payloadBody.getOrThrow().size != count ||
                hostArtifactSha256(payloadBody.getOrThrow()) != httpIntentText(reference, "sha256")) {
                return hostPluginHttpConfigError("http.stream_payload_changed", "HTTP body no longer matches its canonical content identity")
            }
            payloadBody.getOrThrow().clone()
        case None =>
            if (payloadBody.isSome()) { return hostPluginHttpConfigError("http.stream_payload_changed", "unreferenced HTTP request cannot substitute payload bytes") }
            match (httpStreamRequestBody(request, maximumBytes: maximum)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
    }
    Result.Ok(HostHttpStreamLaunch(request, args.toArray(), body, secrets.toArray()))
}
