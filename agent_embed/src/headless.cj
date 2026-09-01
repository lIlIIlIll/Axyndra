package agent_embed

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.deriving.*
import std.sync.*

public type JsonLineOutput = (String) -> Unit
public type JsonTextRedactor = (String) -> String

public class JsonAgentEventSink {
    private let lock = Mutex()
    private let streamLock = Mutex()
    private let values = ArrayList<String>()
    private let output: ?JsonLineOutput
    private let redact: JsonTextRedactor
    private let customRedact: JsonTextRedactor
    private let textStream: JsonEventDeltaBuffer
    private let reasoningStream: JsonEventDeltaBuffer
    private let toolStreams = ArrayList<JsonToolDeltaBuffer>()

    public init(
        output!: ?JsonLineOutput = None,
        redact!: JsonTextRedactor = { value => value }
    ) {
        this.output = output
        this.customRedact = redact
        this.redact = composeJsonRedactor(redact)
        this.textStream = JsonEventDeltaBuffer(redact)
        this.reasoningStream = JsonEventDeltaBuffer(redact)
    }

    public func sink(): AgentEventSink {
        { event => accept(event) }
    }

    public func accept(event: AgentEvent): Unit {
        streamLock.lock()
        try {
            match (event.payload) {
                case AgentEventPayload.TextDelta(delta) =>
                    emitDelta(
                        textStream.push(event, delta),
                        { value => AgentEventPayload.TextDelta(value) }
                    )
                    return
                case AgentEventPayload.ReasoningDelta(delta) =>
                    emitDelta(
                        reasoningStream.push(event, delta),
                        { value => AgentEventPayload.ReasoningDelta(value) }
                    )
                    return
                case AgentEventPayload.ToolOutput(callId, channel, delta) =>
                    let buffer = toolDeltaBuffer(callId, channel)
                    emitDelta(
                        buffer.stream.push(event, delta),
                        { value => AgentEventPayload.ToolOutput(callId, channel, value) }
                    )
                    return
                case AgentEventPayload.ToolCompleted(callId, _, _) =>
                    flushTool(callId)
                case AgentEventPayload.TurnCompleted(_) |
                     AgentEventPayload.RunCompleted => flushModelStreams()
                case _ => ()
            }
            appendEncodedEvent(event)
        } finally {
            streamLock.unlock()
        }
    }

    public func finish(): Unit {
        streamLock.lock()
        try {
            flushModelStreams()
            for (buffer in toolStreams) {
                emitDelta(
                    buffer.stream.finish(),
                    { value => AgentEventPayload.ToolOutput(
                        buffer.callId,
                        buffer.channel,
                        value
                    ) }
                )
            }
            toolStreams.clear()
        } finally {
            streamLock.unlock()
        }
    }

    private func appendEncodedEvent(event: AgentEvent): Unit {
        appendLine(
            "{\"type\":\"agent_event\",\"sequence\":" + event.sequence.toString() +
                ",\"run_id\":" + quoteUnifiedJson(redact(event.runId.value)) +
                ",\"kind\":" + quoteUnifiedJson(eventKindName(event.kind)) +
                ",\"detail\":" + encodeAgentValue(event.detail, redact) + "}"
        )
    }

    private func emitDelta(
        value: ?RedactedEventDelta,
        payload: (String) -> AgentEventPayload
    ): Unit {
        match (value) {
            case Some(item) => appendEncodedEvent(AgentEvent(
                item.meta,
                payload(item.text)
            ))
            case None => ()
        }
    }

    private func flushModelStreams(): Unit {
        emitDelta(
            textStream.finish(),
            { value => AgentEventPayload.TextDelta(value) }
        )
        emitDelta(
            reasoningStream.finish(),
            { value => AgentEventPayload.ReasoningDelta(value) }
        )
    }

    private func toolDeltaBuffer(
        callId: ToolCallId,
        channel: ToolOutputChannel
    ): JsonToolDeltaBuffer {
        for (value in toolStreams where value.callId.value == callId.value &&
            value.channel == channel) {
            return value
        }
        let value = JsonToolDeltaBuffer(callId, channel, customRedact)
        toolStreams.add(value)
        value
    }

    private func flushTool(callId: ToolCallId): Unit {
        var index: Int64 = 0
        while (index < toolStreams.size) {
            let buffer = toolStreams[index]
            if (buffer.callId.value == callId.value) {
                emitDelta(
                    buffer.stream.finish(),
                    { value => AgentEventPayload.ToolOutput(
                        buffer.callId,
                        buffer.channel,
                        value
                    ) }
                )
                toolStreams.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    public func acceptError(error: AgentError): Unit {
        finish()
        appendLine(
            "{\"type\":\"error\",\"kind\":" + quoteUnifiedJson(errorKindName(error.kind)) +
                ",\"code\":" + quoteUnifiedJson(redact(error.code)) +
                ",\"message\":" + quoteUnifiedJson(redact(error.message)) +
                ",\"retryable\":" + error.retryable.toString() + "}"
        )
    }

    public func lines(): Array<String> {
        lock.lock()
        try { values.toArray() } finally { lock.unlock() }
    }

    public func jsonLines(): String {
        finish()
        let snapshot = lines()
        var result = ""
        for (index in 0..snapshot.size) {
            if (index > 0) { result += "\n" }
            result += snapshot[index]
        }
        result
    }

    private func appendLine(line: String): Unit {
        lock.lock()
        try {
            values.add(line)
        } finally {
            lock.unlock()
        }
        match (output) {
            case Some(emit) => emit(line)
            case None => ()
        }
    }
}

class RedactedEventDelta {
    let meta: EventMeta
    let text: String

    init(meta: EventMeta, text: String) {
        this.meta = meta
        this.text = text
    }
}

class JsonEventDeltaBuffer {
    private let redactor: StreamingJsonTextRedactor
    private var firstMeta: ?EventMeta = None

    init(redact: JsonTextRedactor) {
        this.redactor = StreamingJsonTextRedactor(redact: redact)
    }

    func push(event: AgentEvent, value: String): ?RedactedEventDelta {
        if (firstMeta.isNone()) { firstMeta = Some(event.meta) }
        let redacted = redactor.push(value)
        if (redacted == "") { return None }
        let meta = firstMeta.getOrThrow()
        firstMeta = if (redactor.hasPending()) {
            Some(event.meta)
        } else {
            None
        }
        Some(RedactedEventDelta(meta, redacted))
    }

    func finish(): ?RedactedEventDelta {
        let redacted = redactor.finish()
        if (redacted == "") {
            firstMeta = None
            return None
        }
        let meta = match (firstMeta) {
            case Some(value) => value
            case None => return None
        }
        firstMeta = None
        Some(RedactedEventDelta(meta, redacted))
    }
}

class JsonToolDeltaBuffer {
    let callId: ToolCallId
    let channel: ToolOutputChannel
    let stream: JsonEventDeltaBuffer

    init(
        callId: ToolCallId,
        channel: ToolOutputChannel,
        redact: JsonTextRedactor
    ) {
        this.callId = callId
        this.channel = channel
        this.stream = JsonEventDeltaBuffer(redact)
    }
}

// Streaming JSONL must not expose a credential merely because the provider or
// tool split it across delta events. Complete lines are emitted incrementally;
// an unterminated line and a PEM block stay buffered until a safe boundary or
// finish(). Model output bounds keep this buffer finite.
public class StreamingJsonTextRedactor {
    private let lock = Mutex()
    private let redact: JsonTextRedactor
    private var pending = ""

    public init(redact!: JsonTextRedactor = { value => value }) {
        this.redact = composeJsonRedactor(redact)
    }

    public func push(value: String): String {
        lock.lock()
        try {
            pending += value
            drain(false)
        } finally {
            lock.unlock()
        }
    }

    public func finish(): String {
        lock.lock()
        try { drain(true) } finally { lock.unlock() }
    }

    public func hasPending(): Bool {
        lock.lock()
        try { pending != "" } finally { lock.unlock() }
    }

    private func drain(finishing: Bool): String {
        if (pending == "") { return "" }
        let boundary = if (finishing) {
            pending.size
        } else {
            safeJsonStreamBoundary(pending)
        }
        if (boundary <= 0) { return "" }
        let value = pending[..boundary]
        pending = pending[boundary..]
        redact(value)
    }
}

func safeJsonStreamBoundary(value: String): Int64 {
    let complete = lastJsonLineBoundary(value)
    if (complete <= 0) { return 0 }
    var offset: Int64 = 0
    while (offset < complete) {
        let pemStart = match (value[offset..].indexOf("-----BEGIN ")) {
            case Some(relative) => offset + relative
            case None => return complete
        }
        if (pemStart >= complete) { return complete }
        let pemEnd = match (value[pemStart..].indexOf("-----END ")) {
            case Some(relative) => pemStart + relative
            case None => return lastJsonLineBoundary(value[..pemStart])
        }
        let close = match (value[pemEnd + 9..].indexOf("-----")) {
            case Some(relative) => pemEnd + 9 + relative + 5
            case None => return lastJsonLineBoundary(value[..pemStart])
        }
        if (close > complete) {
            return lastJsonLineBoundary(value[..pemStart])
        }
        offset = close
    }
    complete
}

func lastJsonLineBoundary(value: String): Int64 {
    var index = value.size
    while (index > 0) {
        index -= 1
        if (value[index] == b'\n') { return index + 1 }
    }
    0
}

@Derive[Equatable]
public enum HeadlessStatus {
    Completed
    | AwaitingApproval
    | Cancelled
    | TimedOut
    | BudgetExceeded
    | ConfigurationError
    | PermissionDenied
    | Failed
}

public func headlessExitCode(status: HeadlessStatus): Int64 {
    match (status) {
        case HeadlessStatus.Completed => 0
        case HeadlessStatus.AwaitingApproval => 3
        case HeadlessStatus.ConfigurationError => 64
        case HeadlessStatus.BudgetExceeded => 75
        case HeadlessStatus.PermissionDenied => 77
        case HeadlessStatus.TimedOut => 124
        case HeadlessStatus.Cancelled => 130
        case HeadlessStatus.Failed => 1
    }
}

public class HeadlessResult {
    public let status: HeadlessStatus
    public let exitCode: Int64
    public let text: String
    public let jsonEvents: String
    public let run: ?SdkRunResult
    public let error: ?AgentError

    init(
        status: HeadlessStatus,
        text: String,
        jsonEvents: String,
        run: ?SdkRunResult,
        error: ?AgentError
    ) {
        this.status = status
        this.exitCode = headlessExitCode(status)
        this.text = text
        this.jsonEvents = jsonEvents
        this.run = run
        this.error = error
    }
}

public class HeadlessRunner {
    private let sdk: AgentSdk
    private let output: ?JsonLineOutput
    private let redact: JsonTextRedactor

    public init(
        sdk: AgentSdk,
        output!: ?JsonLineOutput = None,
        redact!: JsonTextRedactor = { value => value }
    ) {
        this.sdk = sdk
        this.output = output
        this.redact = redact
    }

    public func run(
        prompt: String,
        cancellation!: ?CancellationToken = None
    ): HeadlessResult {
        let transcriptBoundary = headlessTranscriptBoundary(sdk.transcript())
        let json = JsonAgentEventSink(output: output, redact: redact)
        let text = HeadlessTextCollector()
        let sink: AgentEventSink = { event =>
            text.accept(event)
            json.accept(event)
        }
        finish(
            sdk.run(prompt, eventSink: sink, cancellation: cancellation),
            text,
            json,
            transcriptBoundary
        )
    }

    public func run(prompt: String, cancellation: CancellationToken): HeadlessResult {
        run(prompt, cancellation: Some(cancellation))
    }

    public func continueApproval(
        pending: SdkPendingApproval,
        decision: ApprovalDecision,
        cancellation!: ?CancellationToken = None
    ): HeadlessResult {
        let transcriptBoundary = headlessTranscriptBoundary(sdk.transcript())
        let json = JsonAgentEventSink(output: output, redact: redact)
        let text = HeadlessTextCollector()
        let sink: AgentEventSink = { event =>
            text.accept(event)
            json.accept(event)
        }
        finish(
            sdk.continueApproval(
                pending,
                decision,
                eventSink: sink,
                cancellation: cancellation
            ),
            text,
            json,
            transcriptBoundary
        )
    }

    public func continueApproval(
        pending: SdkPendingApproval,
        decision: ApprovalDecision,
        cancellation: CancellationToken
    ): HeadlessResult {
        continueApproval(pending, decision, cancellation: Some(cancellation))
    }

    private func finish(
        result: Result<SdkRunResult>,
        text: HeadlessTextCollector,
        json: JsonAgentEventSink,
        transcriptBoundary: ?Int64
    ): HeadlessResult {
        match (result) {
            case Result.Ok(value) =>
                let status = match (value.status) {
                    case SdkRunStatus.Completed => HeadlessStatus.Completed
                    case SdkRunStatus.AwaitingApproval => HeadlessStatus.AwaitingApproval
                }
                let captured = text.text()
                HeadlessResult(
                    status,
                    if (captured != "") {
                        captured
                    } else {
                        latestAssistantTextSince(
                            sdk.transcript(),
                            transcriptBoundary
                        )
                    },
                    json.jsonLines(),
                    Some(value),
                    None
                )
            case Result.Err(error) =>
                json.acceptError(error)
                let status = headlessStatus(error)
                let captured = text.text()
                HeadlessResult(
                    status,
                    if (captured != "") {
                        captured
                    } else {
                        latestAssistantTextSince(
                            sdk.transcript(),
                            transcriptBoundary
                        )
                    },
                    json.jsonLines(),
                    None,
                    Some(error)
                )
        }
    }
}

class HeadlessTextCollector {
    private let lock = Mutex()
    private var value: String = ""

    func accept(event: AgentEvent): Unit {
        match (event.payload) {
            case AgentEventPayload.TextDelta(delta) => append(delta)
            case _ => ()
        }
    }

    private func append(delta: String): Unit {
        lock.lock()
        try { value += delta } finally { lock.unlock() }
    }

    func text(): String {
        lock.lock()
        try { value } finally { lock.unlock() }
    }
}

func headlessStatus(error: AgentError): HeadlessStatus {
    match (error.kind) {
        case AgentErrorKind.Cancelled => HeadlessStatus.Cancelled
        case AgentErrorKind.Timeout => HeadlessStatus.TimedOut
        case AgentErrorKind.BudgetExceeded => HeadlessStatus.BudgetExceeded
        case AgentErrorKind.Configuration | AgentErrorKind.InvalidInput => HeadlessStatus.ConfigurationError
        case AgentErrorKind.PermissionDenied => HeadlessStatus.PermissionDenied
        case _ => HeadlessStatus.Failed
    }
}

func headlessTranscriptBoundary(result: Result<Array<ModelMessage>>): ?Int64 {
    match (result) {
        case Result.Ok(value) => Some(value.size)
        case Result.Err(_) => None
    }
}

func latestAssistantTextSince(
    result: Result<Array<ModelMessage>>,
    boundary: ?Int64
): String {
    let start = match (boundary) {
        case Some(value) => value
        // If the pre-run transcript could not be read, no historical text is
        // safe to attribute to this invocation.
        case None => return ""
    }
    let messages = match (result) {
        case Result.Ok(value) => value
        case Result.Err(_) => return ""
    }
    if (start < 0 || start > messages.size) {
        return ""
    }
    var index = messages.size - 1
    while (index >= start) {
        let message = messages[index]
        let assistant = match (message.role) {
            case ModelRole.Assistant => true
            case ModelRole.User => false
        }
        if (assistant) {
            var value = ""
            for (block in message.blocks where block.kind == ModelBlockKind.Text) {
                value += block.text
            }
            if (value != "") { return value }
        }
        index -= 1
    }
    ""
}

func eventKindName(kind: AgentEventKind): String {
    match (kind) {
        case AgentEventKind.RunStarted => "run_started"
        case AgentEventKind.RunStateChanged => "run_state_changed"
        case AgentEventKind.Model => "model"
        case AgentEventKind.Tool => "tool"
        case AgentEventKind.Approval => "approval"
        case AgentEventKind.Budget => "budget"
        case AgentEventKind.Diagnostic => "diagnostic"
        case AgentEventKind.Audit => "audit"
        case AgentEventKind.Transcript => "transcript"
        case AgentEventKind.Completed => "completed"
    }
}

func errorKindName(kind: AgentErrorKind): String {
    match (kind) {
        case AgentErrorKind.Configuration => "configuration"
        case AgentErrorKind.Authentication => "authentication"
        case AgentErrorKind.PermissionDenied => "permission_denied"
        case AgentErrorKind.InvalidInput => "invalid_input"
        case AgentErrorKind.RateLimited => "rate_limited"
        case AgentErrorKind.Timeout => "timeout"
        case AgentErrorKind.Transport => "transport"
        case AgentErrorKind.Provider => "provider"
        case AgentErrorKind.Protocol => "protocol"
        case AgentErrorKind.Cancelled => "cancelled"
        case AgentErrorKind.BudgetExceeded => "budget_exceeded"
        case AgentErrorKind.Conflict => "conflict"
        case AgentErrorKind.RecoveryRequired => "recovery_required"
        case AgentErrorKind.Internal => "internal"
    }
}

func encodeAgentValue(value: AgentValue, redact: JsonTextRedactor): String {
    stringifyUnifiedJson(redactAgentValue(value, redact))
}

func redactAgentValue(value: AgentValue, redact: JsonTextRedactor): JsonNode {
    match (value.unifiedKind) {
        case ValueKind.Null => jsonNull()
        case ValueKind.Boolean => jsonBool(value.boolean)
        case ValueKind.Number => if (validJsonNumber(value.number)) {
            jsonNumber(value.number)
        } else {
            // AgentValue is an extension boundary and older callers could
            // construct an invalid numeric token. Preserve the payload as a
            // string rather than emitting malformed JSONL.
            jsonString(redact(value.number))
        }
        case ValueKind.Text => jsonString(redact(value.text))
        case ValueKind.List =>
            let items = ArrayList<JsonNode>()
            for (item in value.items) { items.add(redactAgentValue(item, redact)) }
            jsonArray(items.toArray())
        case ValueKind.Object =>
            let fields = ArrayList<JsonObjectEntry>()
            for (field in value.fields) {
                fields.add(
                    JsonObjectEntry(field.name, if (jsonSensitiveFieldName(field.name)) {
                        jsonString("[REDACTED]")
                    } else {
                        redactAgentValue(field.value, redact)
                    })
                )
            }
            jsonObject(fields.toArray())
    }
}

func composeJsonRedactor(custom: JsonTextRedactor): JsonTextRedactor {
    { value =>
        // Do not expose a raw recognized credential to a caller hook. The
        // second baseline pass also prevents a hook from accidentally
        // reintroducing a recognizable credential into durable JSONL.
        let baseline = defaultJsonTextRedaction(value)
        let customized = try {
            custom(baseline)
        } catch (_: Exception) {
            // A caller redactor may tighten the policy, but it cannot disable
            // the built-in safety baseline by failing.
            baseline
        }
        defaultJsonTextRedaction(customized)
    }
}

// JSONL is frequently redirected to durable logs. Apply a conservative
// baseline even when the caller does not know which provider/tool fields may
// contain credentials. Callers can only add redaction; the baseline is always
// applied last.
public func defaultJsonTextRedaction(value: String): String {
    var result = value
    for (key in [
        "api_key",
        "apiKey",
        "x-api-key",
        "token",
        "access_token",
        "refresh_token",
        "authorization",
        "cookie",
        "set-cookie",
        "password",
        "secret",
        "private_key",
        "credential",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY"
    ]) {
        result = redactJsonSensitiveField(result, key)
    }
    for (marker in [
        "Authorization:",
        "authorization:",
        "X-Api-Key:",
        "x-api-key:",
        "Cookie:",
        "cookie:",
        "Set-Cookie:",
        "set-cookie:"
    ]) {
        result = redactJsonHeaderValue(result, marker)
    }
    for (prefix in [
        "Authorization: Bearer ",
        "authorization: bearer ",
        "api_key=",
        "API_KEY=",
        "apiKey=",
        "access_token=",
        "refresh_token=",
        "password=",
        "secret=",
        "token=",
        "cookie=",
        "X-Api-Key: ",
        "x-api-key: ",
        "AWS_ACCESS_KEY_ID=",
        "AWS_SECRET_ACCESS_KEY="
    ]) {
        result = redactJsonAssignment(result, prefix)
    }
    for (prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-"]) {
        result = redactJsonPrefixedSecret(result, prefix)
    }
    result = redactJsonPem(result)
    redactJsonUrlCredentials(result)
}

public func redactJsonAgentValue(value: AgentValue): AgentValue {
    match (value.unifiedKind) {
        case ValueKind.Null => nullValue()
        case ValueKind.Boolean => boolValue(value.boolean)
        case ValueKind.Number => numberValue(value.number)
        case ValueKind.Text => textValue(defaultJsonTextRedaction(value.text))
        case ValueKind.List =>
            let values = ArrayList<AgentValue>()
            for (item in value.items) { values.add(redactJsonAgentValue(item)) }
            listValue(values.toArray())
        case ValueKind.Object =>
            let fields = ArrayList<ValueField>()
            for (field in value.fields) {
                fields.add(ValueField(
                    field.name,
                    if (jsonSensitiveFieldName(field.name)) {
                        textValue("[REDACTED]")
                    } else {
                        redactJsonAgentValue(field.value)
                    }
                ))
            }
            objectValue(fields.toArray())
    }
}

func jsonSensitiveFieldName(value: String): Bool {
    let name = value.toAsciiLower().replace("-", "_")
    let compact = name.replace("_", "")
    let credentialToken = compact == "token" || compact.endsWith("token")
    name.contains("api_key") || compact.contains("apikey") ||
        credentialToken ||
        name.contains("authorization") || name.contains("cookie") ||
        name.contains("password") || name.contains("secret") ||
        name.contains("private_key") || compact.contains("privatekey") ||
        name.contains("credential") || name.contains("passwd")
}

func redactJsonHeaderValue(value: String, marker: String): String {
    var result = value
    var offset: Int64 = 0
    while (offset < result.size) {
        match (result[offset..].indexOf(marker)) {
            case None => break
            case Some(relative) =>
                let start = offset + relative + marker.size
                var end = start
                while (end < result.size && result[end] != b'\n' && result[end] != b'\r') {
                    end += 1
                }
                result = result[..start] + " [REDACTED]" + result[end..]
                offset = start + " [REDACTED]".size
        }
    }
    result
}

func redactJsonAssignment(value: String, prefix: String): String {
    var result = value
    var offset: Int64 = 0
    while (offset < result.size) {
        let found = result.indexOf(prefix, offset)
        match (found) {
            case None => break
            case Some(index) =>
                let start = index + prefix.size
                var end = start
                while (end < result.size && !jsonSecretDelimiter(result[end])) {
                    end += 1
                }
                result = result[..start] + "[REDACTED]" + result[end..]
                offset = start + "[REDACTED]".size
        }
    }
    result
}

func redactJsonPrefixedSecret(value: String, prefix: String): String {
    var result = value
    var offset: Int64 = 0
    while (offset < result.size) {
        match (result[offset..].indexOf(prefix)) {
            case None => break
            case Some(relative) =>
                let start = offset + relative
                var end = start + prefix.size
                while (end < result.size && !jsonSecretDelimiter(result[end])) {
                    end += 1
                }
                if (end - start >= prefix.size + 4) {
                    result = result[..start] + "[REDACTED]" + result[end..]
                    offset = start + "[REDACTED]".size
                } else {
                    offset = end
                }
        }
    }
    result
}

func jsonSecretDelimiter(value: Byte): Bool {
    value == b' ' || value == b'\t' || value == b'\n' || value == b'\r' ||
        value == b'"' || value == b'\'' || value == b',' || value == b'}' ||
        value == b']' || value == b'&'
}

func redactJsonSensitiveField(value: String, key: String): String {
    var result = value
    let needle = "\"" + key + "\""
    var offset: Int64 = 0
    while (offset < result.size) {
        let found = match (result[offset..].indexOf(needle)) {
            case Some(relative) => offset + relative
            case None => break
        }
        let restStart = found + needle.size
        let rest = result[restStart..]
        let colon = match (rest.indexOf(":")) {
            case Some(value) => value
            case None => break
        }
        var start = colon + 1
        while (start < rest.size && (rest[start] == b' ' || rest[start] == b'\t')) {
            start += 1
        }
        if (start >= rest.size) { break }
        let quoted = rest[start] == b'"'
        let valueStart = if (quoted) { start + 1 } else { start }
        if (rest[valueStart..].startsWith("[REDACTED]")) {
            offset = restStart + valueStart + "[REDACTED]".size
            continue
        }
        var end = valueStart
        if (quoted) {
            while (end < rest.size) {
                if (rest[end] == b'\\') {
                    end += 2
                    continue
                }
                if (rest[end] == b'"') { break }
                end += 1
            }
        } else {
            while (end < rest.size && rest[end] != b',' && rest[end] != b'}') {
                end += 1
            }
        }
        result = result[..restStart] + rest[..valueStart] + "[REDACTED]" + rest[end..]
        offset = restStart + valueStart + "[REDACTED]".size
    }
    result
}

func redactJsonPem(value: String): String {
    match (value.indexOf("-----BEGIN ")) {
        case None => value
        case Some(start) => match (value[start..].indexOf("-----END ")) {
            case None => value[..start] + "[REDACTED PRIVATE KEY]"
            case Some(relative) =>
                let endStart = start + relative
                match (value[endStart + 9..].indexOf("-----")) {
                    case None => value[..start] + "[REDACTED PRIVATE KEY]"
                    case Some(endRelative) =>
                        let end = endStart + 9 + endRelative + 5
                        value[..start] + "[REDACTED PRIVATE KEY]" + redactJsonPem(value[end..])
                }
        }
    }
}

func redactJsonUrlCredentials(value: String): String {
    match (value.indexOf("://")) {
        case None => value
        case Some(scheme) =>
            let start = scheme + 3
            match (value[start..].indexOf("@")) {
                case None => value
                case Some(relative) =>
                    let at = start + relative
                    if (!value[start..at].contains(":")) { return value }
                    value[..start] + "[REDACTED]@" + value[at + 1..]
            }
    }
}

func validJsonNumber(source: String): Bool {
    try {
        parseUnifiedJson(source, maxBytes: 1024, maxDepth: 1).unifiedKind == UnifiedJsonKind.Number
    } catch (_: JsonException) {
        false
    }
}
