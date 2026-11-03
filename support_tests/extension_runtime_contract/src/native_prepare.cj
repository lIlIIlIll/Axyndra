package extension_runtime_contract

import agent_sdk.*
import legacy_extension_sdk.*
import agent_domain.ServiceProtocolLimits
import agent_domain.parseServiceProtocolLimits
import yjson_support.*
import agent_extension_runtime.*
import legacy_extension_runtime.*
import process4cj.*
import std.env.*
import std.fs.*
import std.time.*

func nativePrepareIdentity(): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(threadId: "prepare-thread", runId: "prepare-run",
        epoch: 7, operationId: "", callId: "prepare-call", kind: "prepare")
}

func nativePrepareFixture(observer: JavaScriptHostObserver, noRead!: Bool = false, limits!: ?ServiceProtocolLimits = None): JavaScriptExtensionHost {
    let executable = match (getVariable("AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE")) {
        case Some(value) => canonicalize(Path(value))
        case None => throw IllegalStateException(
            "build support_tests/native_plugin_fixture/build.sh --tool and set AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE")
    }
    match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        executable.parent.toString(), executable.fileName,
        extensionId: if (noRead) { "native-prepare-no-read-fixture" } else { "native-prepare-fixture" },
        extensionVersion: "1.0.0", generation: 37u64,
        profile: JavaScriptHostLaunchProfile.NativeExecutable,
        maxFrameBytes: match (limits) { case Some(value) => value.maxFrameBytes; case None => JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES },
        serviceLimits: limits,
        contributions: [PluginContributionDefinition("echo", PluginContributionKind.Tool)]
    ), observer: Some(observer))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

func expectPrepareError(
    result: JavaScriptHostResult<JavaScriptHostInvocationResult>, code: String, message: String
): Unit {
    match (result) {
        case JavaScriptHostResult.Err(error) => expect(error.code == code,
            message + ": expected " + code + "; actual " + error.code + ": " + error.message)
        case JavaScriptHostResult.Ok(value) => throw IllegalStateException(message + ": unexpected result " + value.resultJson)
    }
}

func nativePrepareContracts(): Unit {
    let observer = JavaScriptServiceRecorder()
    let host = nativePrepareFixture(observer)
    try {
        let prepared = host.invoke("echo", "{}", identity: nativePrepareIdentity(),
            context: Some(JavaScriptHostInvocationContext(cwd: "/untrusted-context", hasUI: true)),
            observer: Some(observer))
        expect(match (prepared) {
            case JavaScriptHostResult.Ok(value) => !value.isError &&
                value.resultJson.contains("\"prepared\":true") && value.resultJson.contains("\"has_ui\":false")
            case JavaScriptHostResult.Err(_) => false
        }, "native preparation returns a result with no Operation and forcibly disables UI")
        expectPrepareError(host.invoke("missing", "{}", identity: nativePrepareIdentity()),
            "extension.tool_not_registered", "prepare cannot address an unregistered Tool")
        let atLimit = "{\"text\":\"" + repeatedFixtureText("x", NATIVE_PLUGIN_PREPARE_MAX_INPUT_BYTES - 11) + "\"}"
        expect(atLimit.size == NATIVE_PLUGIN_PREPARE_MAX_INPUT_BYTES &&
            host.invoke("echo", atLimit, identity: nativePrepareIdentity()).isOk(),
            "prepare accepts exactly 16 KiB of JSON arguments")
        expectPrepareError(host.invoke("echo", atLimit + " ", identity: nativePrepareIdentity()),
            "extension.prepare_input_too_large", "prepare rejects oversized input before writing")
        expect(!host.isClosed && host.invoke("echo", "{}", identity: fixtureInvocationIdentity("after-prepare")).isOk(),
            "input validation failures do not poison the endpoint or change ordinary tool invocation")
        expect(observer.progressCountValue.load() == 0 && observer.serviceCountValue.load() == 0,
            "successful pure preparation has no observer side effects")
    } finally { host.close() }

    for (mode in ["prepare_wrong_operation", "prepare_service", "prepare_progress", "prepare_oversized"]) {
        let isolatedObserver = JavaScriptServiceRecorder()
        let isolated = nativePrepareFixture(isolatedObserver)
        try {
            let code = if (mode == "prepare_wrong_operation") { "extension.protocol_identity_mismatch" }
                else if (mode == "prepare_oversized") { "extension.prepare_output_too_large" }
                else { "extension.prepare_effect_forbidden" }
            expectPrepareError(isolated.invoke("echo", "{\"mode\":\"" + mode + "\"}",
                identity: nativePrepareIdentity(), observer: Some(isolatedObserver)), code,
                "pure preparation rejects native fixture mode " + mode)
            expect(isolated.isClosed && isolatedObserver.progressCountValue.load() == 0 &&
                isolatedObserver.serviceCountValue.load() == 0,
                "invalid preparation closes the endpoint before any observer effect: " + mode)
        } finally { isolated.close() }
    }

    let cancelledHost = nativePrepareFixture(JavaScriptServiceRecorder())
    let cancellation = CancellationSource()
    let cancelFuture = spawn {
        sleep(Duration.millisecond * 100)
        cancellation.cancel(cause: Some(CancellationCause(CancellationKind.Explicit,
            "fixture.prepare_cancelled", "cancel native preparation")))
    }
    let cancelStart = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    try {
        expectPrepareError(cancelledHost.invoke("echo", "{\"mode\":\"prepare_wait\"}",
            identity: nativePrepareIdentity(), cancellation: cancellation.token),
            "fixture.prepare_cancelled", "native preparation observes host cancellation")
        expect(cancelledHost.isClosed && DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - cancelStart < 3000,
            "cancelled preparation closes its managed process promptly")
    } finally {
        let _ = cancelFuture.get()
        cancelledHost.close()
        cancellation.close()
    }

    let timedHost = nativePrepareFixture(JavaScriptServiceRecorder())
    let started = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    try {
        expectPrepareError(timedHost.invoke("echo", "{\"mode\":\"prepare_wait\"}",
            identity: nativePrepareIdentity(), timeoutMillis: 60000),
            "extension.invocation_timeout", "prepare timeout cannot exceed five seconds")
        let elapsed = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - started
        expect(timedHost.isClosed && elapsed >= 4500 && elapsed < 7500,
            "prepare enforces its five-second timeout ceiling despite a larger requested timeout")
    } finally { timedHost.close() }

    let noRead = nativePrepareFixture(JavaScriptServiceRecorder(), noRead: true)
    let blockedStart = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    try {
        let arguments = "{\"text\":\"" + repeatedFixtureText("x", NATIVE_PLUGIN_PREPARE_MAX_INPUT_BYTES - 11) + "\"}"
        expectPrepareError(noRead.invoke("echo", arguments, identity: nativePrepareIdentity(), timeoutMillis: 100),
            "extension.invocation_timeout", "prepare watchdog bounds a blocked stdin invoke and cancel write")
        expect(noRead.isClosed && DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - blockedStart < 3000,
            "a native endpoint that stops reading stdin is forcibly reclaimed within the timeout bound")
    } finally { noRead.close() }

    let profile = parseServiceProtocolLimits(parseUnifiedJson(
        "{\"max_frame_bytes\":4194304,\"max_input_bytes\":1048576,\"max_prepare_bytes\":2097152," +
        "\"max_result_bytes\":4128768,\"max_directory_bytes\":2097152,\"max_tools\":8192,\"call_timeout_ms\":120000}")).value().getOrThrow()
    let toolOnly = nativePrepareFixture(JavaScriptServiceRecorder(), limits: Some(profile))
    try {
        expectPrepareError(toolOnly.invoke("echo", "{\"text\":\"" + repeatedFixtureText("x", 16384) + "\"}",
            identity: nativePrepareIdentity()), "extension.prepare_input_too_large",
            "host Service profile does not expand ordinary native Tool preparation input")
        expectPrepareError(toolOnly.invoke("echo", "{\"mode\":\"prepare_oversized\"}", identity: nativePrepareIdentity()),
            "extension.prepare_output_too_large", "Service profile does not expand Tool preparation output")
    } finally { toolOnly.close() }

    let root = canonicalize(Path("fixtures")).toString()
    let protocolWorker = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_echo_v1.js", extensionId: "prepare-not-native", extensionVersion: "1.0.0"
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    try {
        expectPrepareError(protocolWorker.invoke("echo", "{}", identity: nativePrepareIdentity()),
            "extension.prepare_unsupported", "ProtocolWorker cannot receive native pure preparation")
        expect(!protocolWorker.isClosed && protocolWorker.invoke("echo", "{}",
            identity: fixtureInvocationIdentity("worker-after-rejected-prepare")).isOk(),
            "unsupported prepare leaves ordinary ProtocolWorker invocation unchanged")
    } finally { protocolWorker.close() }
}
