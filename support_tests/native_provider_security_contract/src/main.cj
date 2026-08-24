package native_provider_security_contract

import agent_domain as domain
import agent_product.*
import model_adapters.*
import std.collection.*
import std.env.*
import std.sync.*
import std.time.*

let TEST_API_KEY = "native-provider-secret-echo-20260810"
let TEST_API_KEY_ENV = "AXYNDRA_NATIVE_PROVIDER_SECURITY_KEY"

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size != 3) {
        println("usage: native_provider_security_contract <loopback-port> <invalid-tls-port>")
        return 2
    }
    expect(
        match (getVariable(TEST_API_KEY_ENV)) {
            case Some(value) => value == TEST_API_KEY
            case None => false
        },
        "security contract receives its scoped fixture credential"
    )
    let loopbackBase = "http://127.0.0.1:" + arguments[1]
    expectProductProfileUrlPolicy(loopbackBase)

    let transport = NativeProviderTransport()
    expectLoopbackUsable(transport, loopbackBase)
    expectEchoedErrorRedacted(transport, loopbackBase)
    expectStreamErrorRedacted(transport, loopbackBase)
    expectExceptionRedacted(transport, loopbackBase)
    expectPartialStreamTimeout(transport, loopbackBase)
    expectPublicCancellationLifecycle(transport, loopbackBase)
    expectNativeRemoteHttpRejected(transport)
    expectInvalidCertificateRejected(transport, "https://127.0.0.1:" + arguments[2])

    println(
        "native provider security contract passed: loopback HTTP, remote HTTP denial, " +
        "invalid-certificate TLS failure, error/stream/exception credential redaction"
    )
    0
}

class StreamSignal {
    private let lock = Mutex()
    private var active = false
    func mark(): Unit { lock.lock(); try { active = true } finally { lock.unlock() } }
    func observed(): Bool { lock.lock(); try { active } finally { lock.unlock() } }
}

func expectPublicCancellationLifecycle(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    let signal = StreamSignal()
    let requestId = "native-security-stalled-cancel"
    let stalled = spawn { transport.post(
        provider("stalled-cancel", baseUrl, timeoutMillis: 0),
        "{\"case\":\"stalled-cancel\"}", true, requestId,
        {_ => signal.mark()}) }
    let activeDeadline = MonoTime.now() + Duration.millisecond * 1000
    while (!signal.observed() && MonoTime.now() < activeDeadline) {
        sleep(Duration.millisecond)
    }
    expect(signal.observed(), "stalled SSE becomes observably active")
    let cancelStarted = MonoTime.now()
    expect(transport.cancel(requestId).isOk(), "public stalled-SSE cancel succeeds")
    expect((MonoTime.now() - cancelStarted).toMilliseconds() < 750,
        "public cancellation returns below the 750ms loopback threshold")
    expect(transport.cancel(requestId).isOk(), "repeated public cancel is idempotent")
    let finishDeadline = MonoTime.now() + Duration.millisecond * 1000
    while (stalled.tryGet().isNone() && MonoTime.now() < finishDeadline) {
        sleep(Duration.millisecond)
    }
    expect(stalled.tryGet().isSome(),
        "cancelled provider execution terminates and releases its active entry below 1000ms")
    expect(match (stalled.get()) {
        case domain.Result.Err(error) => match (error.kind) {
            case domain.AgentErrorKind.Cancelled => true
            case _ => false
        }
        case domain.Result.Ok(_) => false
    }, "cancelled stalled SSE returns the public Cancelled result")
    expect(transport.post(provider("reuse-after-finish", baseUrl),
        "{\"case\":\"success\"}", false, requestId, {_ => ()}).isOk(),
        "requestId reuse is valid after finishNative releases the record")

    let beforeAttachId = "native-security-cancel-before-attach"
    let beforeAttach = spawn { transport.post(
        provider("cancel-before-attach", baseUrl, timeoutMillis: 0),
        "{\"case\":\"delayed-headers\"}", false, beforeAttachId, {_ => ()}) }
    sleep(Duration.millisecond * 20)
    let beforeAttachStarted = MonoTime.now()
    expect(transport.cancel(beforeAttachId).isOk(), "cancel before response attach succeeds")
    expect((MonoTime.now() - beforeAttachStarted).toMilliseconds() < 750,
        "cancel-before-attach does not wait under activeLock")
    let beforeAttachDeadline = MonoTime.now() + Duration.millisecond * 1000
    while (beforeAttach.tryGet().isNone() && MonoTime.now() < beforeAttachDeadline) {
        sleep(Duration.millisecond)
    }
    expect(beforeAttach.tryGet().isSome(), "cancel-before-attach execution terminates below 1000ms")
    let _ = beforeAttach.get()

    let independentSignal = StreamSignal()
    let independentId = "native-security-independent-stall"
    let independent = spawn { transport.post(
        provider("independent-stall", baseUrl, timeoutMillis: 0),
        "{\"case\":\"stalled-cancel\"}", true, independentId,
        {_ => independentSignal.mark()}) }
    let independentDeadline = MonoTime.now() + Duration.millisecond * 1000
    while (!independentSignal.observed() && MonoTime.now() < independentDeadline) {
        sleep(Duration.millisecond)
    }
    expect(independentSignal.observed(), "independent stalled request becomes active")
    expect(transport.post(provider("independent-success", baseUrl),
        "{\"case\":\"success\"}", false,
        "native-security-independent-success", {_ => ()}).isOk(),
        "one active stalled request does not block an independent request")
    expect(transport.cancel(independentId).isOk(), "independent stalled request cancels")
    let independentFinish = MonoTime.now() + Duration.millisecond * 1000
    while (independent.tryGet().isNone() && MonoTime.now() < independentFinish) {
        sleep(Duration.millisecond)
    }
    expect(independent.tryGet().isSome(), "independent cancellation releases only its request")
    let _ = independent.get()
}

func expectPartialStreamTimeout(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    match (transport.post(
        provider("partial-timeout", baseUrl, timeoutMillis: 100),
        "{\"case\":\"partial-timeout\"}",
        true,
        "native-security-partial-timeout",
        {_ => ()}
    )) {
        case domain.Result.Err(error) => match (error.kind) {
            case domain.AgentErrorKind.Timeout => expect(
                error.code == "model.timeout" &&
                    error.field("provider_id") == Some("partial-timeout"),
                "a partial SSE body that outlives the request limit remains a timeout"
            )
            case _ => throw IllegalStateException(
                "partial SSE timeout was misclassified as " + error.code
            )
        }
        case domain.Result.Ok(_) => throw IllegalStateException(
            "partial SSE timeout unexpectedly returned a response body"
        )
    }
}

func expectInvalidCertificateRejected(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    match (transport.post(
        provider("invalid-certificate", baseUrl),
        "{}",
        false,
        "native-security-invalid-certificate",
        {_ => ()}
    )) {
        case domain.Result.Err(error) => expectInvalidCertificateError(error)
        case domain.Result.Ok(_) => throw IllegalStateException(
            "NativeProviderTransport accepted an invalid server certificate"
        )
    }
}

func expectInvalidCertificateError(error: domain.AgentError): Unit {
    let diagnostic = error.message.toAsciiLower()
    expect(
        error.code == "model.transport_internal" &&
            !diagnostic.contains("tls must be configured") &&
            (diagnostic.contains("certificate") || diagnostic.contains("verify") ||
                diagnostic.contains("tls")),
        "invalid server certificate is an explicit TLS transport error"
    )
}

func expectProductProfileUrlPolicy(loopbackBase: String): Unit {
    let accepted = ProviderProfile(
        "loopback",
        "fixture",
        "responses",
        loopbackBase,
        TEST_API_KEY_ENV
    )
    expect(
        accepted.baseUrl == loopbackBase,
        "ProviderProfile permits loopback HTTP"
    )
    var rejected = false
    try {
        let _ = ProviderProfile(
            "remote-plaintext",
            "fixture",
            "responses",
            "http://198.51.100.20",
            TEST_API_KEY_ENV
        )
    } catch (error: IllegalArgumentException) {
        rejected = error.message.contains("HTTPS or loopback HTTP") &&
            !error.message.contains(TEST_API_KEY)
    }
    expect(rejected, "ProviderProfile rejects credentialed remote HTTP")
}

func expectLoopbackUsable(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    match (transport.post(
        provider("loopback-ok", baseUrl),
        "{\"case\":\"success\"}",
        false,
        "native-security-loopback",
        {_ => ()}
    )) {
        case domain.Result.Ok(body) => expect(
            body.contains("\"ok\":true"),
            "NativeProviderTransport can call loopback HTTP"
        )
        case domain.Result.Err(error) => throw IllegalStateException(
            "loopback HTTP failed: " + error.code + ": " + error.message
        )
    }
}

func expectEchoedErrorRedacted(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    expectRedactedError(
        transport.post(
            provider("echo-error", baseUrl),
            "{\"case\":\"echo-error\"}",
            false,
            "native-security-echo-error",
            {_ => ()}
        ),
        "model.provider_error",
        "non-2xx provider body redacts an echoed API key"
    )
}

func expectStreamErrorRedacted(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    let chunks = ArrayList<String>()
    let result = transport.post(
        provider("stream-error", baseUrl),
        "{\"case\":\"stream-error\"}",
        true,
        "native-security-stream-error",
        {chunk => chunks.add(chunk)}
    )
    expectRedactedError(
        result,
        "model.provider_error",
        "streaming non-2xx provider body redacts an echoed API key"
    )
    expect(
        chunks.size > 0 && allRedacted(chunks.toArray()),
        "stream chunks are redacted before reaching the caller"
    )
}

func expectExceptionRedacted(
    transport: NativeProviderTransport,
    baseUrl: String
): Unit {
    expectRedactedError(
        transport.post(
            provider("callback-error", baseUrl),
            "{\"case\":\"callback-error\"}",
            true,
            "native-security-callback-error",
            {_ => throw IllegalStateException("callback failed: " + TEST_API_KEY)}
        ),
        "model.transport_internal",
        "transport exception diagnostics redact an API key"
    )
}

func expectNativeRemoteHttpRejected(transport: NativeProviderTransport): Unit {
    match (transport.post(
        provider("remote-plaintext", "http://198.51.100.20"),
        "{}",
        false,
        "native-security-remote-http",
        {_ => ()}
    )) {
        case domain.Result.Err(error) => expect(
            error.code == "model.insecure_provider_url" &&
                !error.message.contains(TEST_API_KEY),
            "NativeProviderTransport rejects remote HTTP before sending credentials"
        )
        case domain.Result.Ok(_) => throw IllegalStateException(
            "NativeProviderTransport unexpectedly accepted remote HTTP"
        )
    }
}

func provider(
    id: String,
    baseUrl: String,
    timeoutMillis!: Int64 = 5000
): ProviderSpec {
    ProviderSpec(
        id,
        ProviderProtocol.Responses,
        "fixture-model",
        baseUrl,
        TEST_API_KEY_ENV,
        timeoutMillis: timeoutMillis
    )
}

func expectRedactedError(
    result: domain.Result<String>,
    code: String,
    label: String
): Unit {
    match (result) {
        case domain.Result.Err(error) => expect(
            error.code == code &&
                error.message.contains("[REDACTED]") &&
                !error.message.contains(TEST_API_KEY),
            label
        )
        case domain.Result.Ok(_) => throw IllegalStateException(
            label + ": request unexpectedly succeeded"
        )
    }
}

func allRedacted(values: Array<String>): Bool {
    for (value in values where value.contains(TEST_API_KEY)) { return false }
    for (value in values where value.contains("[REDACTED]")) { return true }
    false
}

func expect(condition: Bool, label: String): Unit {
    if (!condition) { throw IllegalStateException(label) }
}
