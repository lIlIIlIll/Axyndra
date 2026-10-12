package extension_runtime_contract

import agent_sdk.*
import legacy_extension_sdk.*
import agent_extension_runtime.*
import legacy_extension_runtime.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

func nativeServiceIdentity(thread: String, sequence: String): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(threadId: thread, runId: "service-run-" + sequence,
        epoch: 7, operationId: "service-operation-" + sequence, callId: "service-call-" + sequence, kind: "service")
}

func nativeServiceFixtureRequest(kind: PluginContributionKind): JavaScriptHostLaunchRequest {
    let executable = match (getVariable("AXYNDRA_NATIVE_SERVICE_PLUGIN_FIXTURE")) {
        case Some(value) => canonicalize(Path(value))
        case None => throw IllegalStateException("native Service fixture must be built explicitly before contract execution")
    }
    JavaScriptHostLaunchRequest(executable.parent.toString(), executable.fileName,
        extensionId: "native-service-fixture", extensionVersion: "1.0.0", generation: 47u64,
        profile: JavaScriptHostLaunchProfile.NativeExecutable,
        contributions: [PluginContributionDefinition("session", kind)])
}

func nativeServiceContracts(): Unit {
    let host = match (startFixtureJavaScriptExtensionHost(nativeServiceFixtureRequest(PluginContributionKind.Service))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    try {
        expect(host.services.size == 1 && host.services[0].name == "session" && host.tools.isEmpty() &&
            host.commands.isEmpty(), "a real service-only process completes the inspected native handshake")
        let exposed = host.services
        exposed[0] = PluginServiceDescriptor("changed", "changed copy")
        expect(host.services[0].name == "session", "route declarations do not expose a mutable host array")
        expectPrepareError(host.invoke("missing", "{}", identity: nativeServiceIdentity("maintenance", "missing")),
            "extension.service_not_registered", "undeclared service route cannot be invoked")
        expectPrepareError(host.invoke("session", "{}", identity: JavaScriptHostInvocationIdentity(
            threadId: "maintenance", runId: "run", epoch: 1, operationId: "operation", callId: "call")),
            "extension.tool_not_registered", "a Service is not fabricated as a Tool")
        let prepareIdentity = JavaScriptHostInvocationIdentity(threadId: "target-thread", runId: "service-run-prep",
            epoch: 7, operationId: "", callId: "service-call-prep", kind: "service_prepare")
        match (host.invoke("session", "{}", identity: prepareIdentity,
            context: Some(JavaScriptHostInvocationContext(hasUI: true)))) {
            case JavaScriptHostResult.Ok(value) => expect(!value.isError &&
                value.resultJson.contains("\"prepared\":true") && value.resultJson.contains("\"has_ui\":false"),
                "service-only endpoint prepares without operation authority or UI")
            case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        expectPrepareError(host.invoke("missing", "{}", identity: prepareIdentity),
            "extension.service_not_registered", "pure service preparation requires its declared route")
        for ((thread, sequence, expected) in [("maintenance", "1", "1"), ("target-thread", "2", "2")]) {
            match (host.invoke("session", "{}", identity: nativeServiceIdentity(thread, sequence))) {
                case JavaScriptHostResult.Ok(value) => expect(!value.isError &&
                    parseUnifiedJson(value.resultJson).field("calls").getOrThrow().asNumberText() == expected,
                    "fixed endpoint retains state while exact canonical envelope identities change")
                case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
        }
        match (host.invoke("session", "{\"mode\":\"service_read\"}",
            identity: nativeServiceIdentity("target-thread", "3"))) {
            case JavaScriptHostResult.Ok(value) => expect(value.isError &&
                value.resultJson.contains("extension.service_unsupported"),
                "Service routing alone cannot authorize an exec callback without a host observer")
            case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
    } finally { host.close() }
    expect(match (startFixtureJavaScriptExtensionHost(nativeServiceFixtureRequest(PluginContributionKind.Command))) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.contributions_mismatch"
        case JavaScriptHostResult.Ok(value) => value.close(); false
    }, "ready Service routes cannot substitute for the inspected contribution kind")
    for ((mode, errorCode) in [("prepare_service", "extension.prepare_effect_forbidden"),
        ("prepare_progress", "extension.prepare_effect_forbidden"),
        ("prepare_wrong_operation", "extension.protocol_identity_mismatch")]) {
        let prepareHost = match (startFixtureJavaScriptExtensionHost(nativeServiceFixtureRequest(PluginContributionKind.Service))) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
        }
        try {
            expectPrepareError(prepareHost.invoke("session", "{\"mode\":\"" + mode + "\"}",
                identity: JavaScriptHostInvocationIdentity(threadId: "target-thread", runId: "prepare-run",
                    epoch: 7, operationId: "", callId: mode, kind: "service_prepare")),
                errorCode, "pure Service preparation cannot emit effects or forge canonical identity")
        } finally { prepareHost.close() }
    }
    let nativeRequest = nativeServiceFixtureRequest(PluginContributionKind.Service)
    let executable = canonicalize(Path(nativeRequest.packageRoot).join(nativeRequest.entrypoint)).toString()
    // ProtocolWorker first requires a JavaScript entrypoint. The original
    // binary-entrypoint negative fixture is rejected before any handshake.
    match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        nativeRequest.packageRoot, nativeRequest.entrypoint, runtime: executable,
        profile: JavaScriptHostLaunchProfile.ProtocolWorker,
        extensionId: "native-service-fixture", extensionVersion: "1.0.0", generation: 48u64
    ))) {
        case JavaScriptHostResult.Err(error) =>
            expect(error.code == "extension.entrypoint_invalid",
                "native binary entrypoint must be rejected before launch, actual: " + error.code)
            println("ProtocolWorker binary entrypoint refusal: " + error.code)
        case JavaScriptHostResult.Ok(value) =>
            value.close()
            throw IllegalStateException("ProtocolWorker accepted a native executable as its Node runtime")
    }
    let nodeFixtureRoot = canonicalize(Path("fixtures")).toString()
    // With a valid JavaScript entrypoint, independently verify the Node-only
    // runtime restriction instead of confusing it with the earlier fence.
    match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        nodeFixtureRoot, "protocol_worker_service.js", runtime: executable,
        profile: JavaScriptHostLaunchProfile.ProtocolWorker,
        extensionId: "invalid-node-runtime", extensionVersion: "1.0.0", generation: 49u64
    ))) {
        case JavaScriptHostResult.Err(error) =>
            expect(error.code == "extension.runtime_unsupported",
                "non-Node runtime must be rejected before launch, actual: " + error.code)
            println("ProtocolWorker native runtime refusal: " + error.code)
        case JavaScriptHostResult.Ok(value) =>
            value.close()
            throw IllegalStateException("ProtocolWorker accepted a non-Node runtime")
    }
    // Now use a real Node endpoint so the ready.services rejection itself is
    // reached through the actual ProtocolWorker process/handshake path.
    match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        nodeFixtureRoot, "protocol_worker_service.js",
        profile: JavaScriptHostLaunchProfile.ProtocolWorker,
        extensionId: "node-service-fixture", extensionVersion: "1.0.0", generation: 50u64
    ))) {
        case JavaScriptHostResult.Err(error) =>
            expect(error.code == "extension.services_unsupported",
                "non-native ready.services must be rejected, actual: " + error.code + ": " + error.message)
        case JavaScriptHostResult.Ok(value) =>
            value.close()
            throw IllegalStateException("non-native process profile accepted Service routes")
    }
    println("Native Service protocol contract passed: real service-only endpoint, canonical identities, fixed state, declaration mismatch, no implicit broker grant")
}
