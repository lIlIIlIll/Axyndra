package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process as transport_process
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func pluginHttpTransportCapabilities(): CapabilitySet {
    CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.NetworkAccess)])
}

func pluginHttpTransportOutput(result: Result<ToolInvocationResult>, fixture: PluginHttpProductFixture): AgentValue {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            if (value.isError) { throw IllegalStateException("HTTP root failed: " + fixture.evidenceSummary()) }
            value.output
        case Result.Err(error) => throw IllegalStateException(error.code + "; " + fixture.evidenceSummary())
        case _ => throw IllegalStateException("HTTP root did not complete; " + fixture.evidenceSummary())
    }
}

func pluginHttpTransportFailure(result: Result<ToolInvocationResult>): String {
    match (result) {
        case Result.Err(error) => ":code=" + error.code
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            if (value.isError) { pluginHttpTestErrorCodes(value.output) } else { "unexpected-success" }
        case _ => "unexpected-control-result"
    }
}

func pluginHttpTransportChildren(fixture: PluginHttpProductFixture, thread: String, outcome: String): Int64 {
    fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operations o ON o.id=r.operation_id " +
        "JOIN runs run ON run.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
        "WHERE run.thread_id='" + thread + "' AND e.tool_id='host.network.http' AND r.outcome='" + outcome + "'")
}

func pluginHttpTransportAwaitFile(path: String): Unit {
    let deadline = agentUtcMillis() + 3000
    while (!exists(Path(path)) && agentUtcMillis() < deadline) { sleep(Duration.millisecond * 10) }
    if (!exists(Path(path))) { throw IllegalStateException("HTTP origin did not observe connection cancellation") }
}

@Test
class PluginHttpTransportTests {
    @TestCase
    func curlConfigurationCannotAddAnAttackerRequest(): Unit {
        let fixture = PluginHttpProductFixture("curlrc", "normal", method: "GET")
        let previous = getVariable("CURL_HOME")
        try {
            let base = fixture.url[..fixture.url.lastIndexOf("/").getOrThrow()]
            File.writeTo(fixture.root + "/.curlrc", ("url = \"" + base + "/attacker\"\n").toArray())
            let request = fixture.request("normal", 3000)
            let configuration = match (loadPluginHttpConfiguration(fixture.root + "/settings",
                productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code)
            }
            let credentials = match (configuration.resolveCredentials(request)) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code)
            }
            let argv = match (pluginHttpCurlArguments(request, credentials)) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code)
            }
            @Expect(argv[0], "-q")
            // This first exchange proves -q with a real curl that CAN read
            // the polluted config. The second proves the Product gateway.
            let environment = HashMap<String, String>()
            environment["HOME"] = fixture.root
            environment["CURL_HOME"] = fixture.root
            environment["PATH"] = "/usr/bin:/bin"
            let (code, output, _) = transport_process.executeWithOutput("/usr/bin/curl", argv,
                environment: environment)
            @Expect(code, 0)
            @Expect(String.fromUtf8(output).endsWith("\n200"))
            fixture.awaitObserved(1)
            setVariable("CURL_HOME", fixture.root)
            let result = fixture.invoke("http-curlrc")
            @Expect(result.isOk())
            fixture.awaitObserved(2)
            for (exchange in fixture.observed()) {
                @Expect(exchange.field("path").getOrThrow().text, "/exchange")
                @Expect(exchange.field("header_ok").getOrThrow().asBool())
            }
            @Expect(pluginHttpTransportChildren(fixture, "http-curlrc", "completed"), 1)
            pluginHttpTestAssertNoSecrets(fixture, objectValue([]))
        } finally {
            match (previous) { case Some(value) => setVariable("CURL_HOME", value); case None => removeVariable("CURL_HOME") }
            fixture.close()
        }
    }

    @TestCase
    func redirectIsReturnedWithoutFollowingItsLocation(): Unit {
        let fixture = PluginHttpProductFixture("redirect", "redirect", method: "GET")
        try {
            let output = pluginHttpTransportOutput(fixture.product.vnext.executeCanonicalTool(SessionId("http-redirect"),
                pluginHttpTransportCapabilities(), ToolCall("redirect-call", fixture.tool(), objectValue([])),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)), fixture)
            fixture.awaitObserved(1)
            @Expect(output.field("service_result").getOrThrow().field("output").getOrThrow()
                .field("status").getOrThrow().asNumberText(), "302")
            @Expect(fixture.observed()[0].field("path").getOrThrow().text, "/exchange")
            @Expect(pluginHttpTransportChildren(fixture, "http-redirect", "completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        } finally { fixture.close() }
    }

    @TestCase
    func responseAndSerializedFrameLimitsRetainUnknownEvidence(): Unit {
        let fixture = PluginHttpProductFixture("response-bounds", "limit-length", method: "GET")
        try {
            let accepted = pluginHttpTransportOutput(fixture.product.vnext.executeCanonicalTool(SessionId("http-bound-exact"),
                pluginHttpTransportCapabilities(), ToolCall("exact-boundary-call", fixture.tool(), objectValue([])),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)), fixture)
            fixture.awaitObserved(1)
            let exactBody = accepted.field("service_result").getOrThrow().field("output").getOrThrow()
                .field("body").getOrThrow().text
            @Expect(exactBody.size, 65536)
            @Expect(exactBody, String.fromUtf8(Array<UInt8>(65536, repeat: 120u8)))
            @Expect(pluginHttpTransportChildren(fixture, "http-bound-exact", "completed"), 1)
            var count: Int64 = 1
            for (mode in ["oversize-length", "oversize-chunked", "escaped-output"]) {
                fixture.configure(mode, 3000)
                let thread = "http-bound-" + mode
                // A malicious endpoint reports success after a child error;
                // the actual child receipt still controls the terminal run.
                let _ = fixture.invoke(thread, arguments: objectValue([ValueField("wash_error", boolValue(true))]))
                count += 1
                fixture.awaitObserved(count)
                @Expect(pluginHttpTransportChildren(fixture, thread, "unknown"), 1)
                @Expect(pluginHttpTransportChildren(fixture, thread, "completed"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='" + thread +
                    "' AND state='recovery_required'"), 1)
            }
            @Expect(count, 4)
            @Expect(fixture.observed().size, 4)
            pluginHttpTestAssertNoSecrets(fixture, objectValue([]))
        } finally { fixture.close() }
    }

    @TestCase
    func stricterParentProcessLimitsFailBeforeAnyHttpEffect(): Unit {
        let fixture = PluginHttpProductFixture("parent-limits", "normal")
        try {
            var count: Int64 = 0
            for (limits in [ExecutionResourceLimits(maxOutputBytes: 4096), ExecutionResourceLimits(openFiles: 32)]) {
                count += 1
                let result = fixture.product.vnext.executeCanonicalTool(SessionId("http-strict-" + count.toString()),
                    pluginHttpTransportCapabilities(), ToolCall("strict-call", fixture.tool(), objectValue([])),
                    budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1, processLimits: limits))
                @Expect(pluginHttpTransportFailure(result), ":code=plugin.resource_limit_unavailable")
            }
            @Expect(count, 2)
            @Expect(fixture.observed().size, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.network.http'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func cancelledPreparationAndExpiredParentHaveNoHttpEffect(): Unit {
        let fixture = PluginHttpProductFixture("early-cancel", "normal")
        let cancellation = CancellationSource()
        try {
            let _ = cancellation.cancel()
            let host = fixture.product.vnext.javascriptPlugins
            // The installed package and configuration are real. This is the
            // same pure preparation entry used by canonical ToolPipeline.
            let prepared = host.prepareHttp(ToolInvocationContext(RunId("cancelled-before-prepare"),
                SessionId("cancelled-before-prepare"), pluginHttpTransportCapabilities(),
                epoch: 1, cancellation: cancellation.token), ToolCall("same-call", fixture.tool(), objectValue([])),
                productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "echo", host.instanceGeneration(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))))
            @Expect(match (prepared) {
                case Result.Err(error) => error.code == "extension.cancelled"
                case Result.Ok(_) => false
            })
            let expired = fixture.product.vnext.executeCanonicalTool(SessionId("http-expired"),
                pluginHttpTransportCapabilities(), ToolCall("expired-call", fixture.tool(), objectValue([])),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1, deadlineMillis: agentUtcMillis() - 1))
            let code = pluginHttpTransportFailure(expired)
            @Expect(code == ":code=run.deadline_exceeded" || code == ":code=budget.deadline_exceeded" ||
                code == ":code=extension.cancelled")
            @Expect(fixture.observed().size, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.network.http'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
        } finally { cancellation.close(); fixture.close() }
    }

    @TestCase
    func shorterParentDeadlineStopsAnActiveLongHttpRequest(): Unit {
        let fixture = PluginHttpProductFixture("parent-deadline", "hold", timeout: 60000)
        try {
            let started = agentUtcMillis()
            let pending = spawn {
                fixture.product.vnext.executeCanonicalTool(SessionId("http-parent-deadline"),
                    pluginHttpTransportCapabilities(), ToolCall("deadline-call", fixture.tool(), objectValue([])),
                    budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1, deadlineMillis: started + 6000))
            }
            fixture.awaitObserved(1)
            let _ = pending.get()
            @Expect(agentUtcMillis() - started < 12000)
            pluginHttpTransportAwaitFile(fixture.root + "/origin/closed-1")
            @Expect(fixture.observed().size, 1)
            @Expect(pluginHttpTransportChildren(fixture, "http-parent-deadline", "unknown"), 1)
            @Expect(pluginHttpTransportChildren(fixture, "http-parent-deadline", "completed"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='http-parent-deadline' AND state='completed'"), 0)
            pluginHttpTestAssertNoSecrets(fixture, objectValue([]))
        } finally { fixture.close() }
    }

    @TestCase
    func sameCallIdCancellationLeavesOtherThreadAndQueuedIntentIsolated(): Unit {
        let fixture = PluginHttpProductFixture("cancel-isolation", "controlled-hold", timeout: 15000)
        try {
            let sessionA = fixture.product.applicationSession(sessionId: Some(SessionId("http-cancel-a")))
            let sessionB = fixture.product.applicationSession(sessionId: Some(SessionId("http-cancel-b")))
            let doneB = AtomicBool(false)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("same-call", fixture.tool(),
                objectValue([ValueField("queue_second", boolValue(true))]))
            let pendingA = spawn { sessionA.submit("Run A with two prepared HTTP intents.") }
            try {
                fixture.awaitObserved(1)
                let parents = fixture.database.query("SELECT o.normalized_plan FROM operations o JOIN runs r ON r.id=o.run_id " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id='http-cancel-a' " +
                    "AND e.tool_id='" + fixture.tool() + "'")
                @Expect(parents.size, 1)
                let intents = decodeStoredValue(parents[0].required(0)).field("arguments").getOrThrow()
                    .field("host_plan").getOrThrow().field("intents").getOrThrow().items
                @Expect(intents.size, 2)
                @Expect(intents[0].field("id").getOrThrow().text, "native-service-1")
                @Expect(intents[1].field("id").getOrThrow().text, "native-service-2")
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("same-call", fixture.tool(), objectValue([]))
                let pendingB = spawn {
                    try { sessionB.submit("Run B with the same call id in a separate Thread.") }
                    finally { doneB.store(true) }
                }
                try {
                    fixture.awaitObserved(2)
                    let started = agentUtcMillis()
                    @Expect(sessionA.cancel().isOk())
                    let _ = pendingA.get()
                    @Expect(agentUtcMillis() - started < 5000)
                    pluginHttpTransportAwaitFile(fixture.root + "/origin/closed-1")
                    @Expect(!doneB.load())
                    @Expect(!exists(Path(fixture.root + "/origin/closed-2")))
                    @Expect(fixture.observed().size, 2)
                    @Expect(pluginHttpTransportChildren(fixture, "http-cancel-a", "unknown"), 1)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='http-cancel-a' AND state='cancelled'"), 1)
                    // The prepared second intent must exist, but cannot gain a
                    // child admission or executor handoff after A is cancelled.
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id " +
                        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id='http-cancel-a' " +
                        "AND e.tool_id='host.network.http'"), 1)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events a JOIN operation_effect_records e " +
                        "ON e.operation_id=a.operation_id JOIN operations o ON o.id=e.operation_id JOIN runs r ON r.id=o.run_id " +
                        "WHERE r.thread_id='http-cancel-a' AND e.tool_id='host.network.http' AND a.kind='operation_execution_handoff'"), 1)
                    File.writeTo(fixture.root + "/origin/release-2", "release".toArray())
                    @Expect(pendingB.get().isOk())
                    @Expect(doneB.load())
                    @Expect(pluginHttpTransportChildren(fixture, "http-cancel-b", "completed"), 1)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='http-cancel-b' AND state='completed'"), 1)
                    let output = pluginHttpTestThreadOutput(fixture.database, "http-cancel-b", "same-call")
                    @Expect(output.field("service_result").getOrThrow().field("output").getOrThrow()
                        .field("status").getOrThrow().asNumberText(), "200")
                    @Expect(fixture.observed().size, 2)
                    pluginHttpTestAssertNoSecrets(fixture, output)
                } finally {
                    try { File.writeTo(fixture.root + "/origin/release-2", "cleanup".toArray()) } finally {
                        try { let _ = sessionB.cancel() } finally { let _ = pendingB.get() }
                    }
                }
            } finally {
                try { File.writeTo(fixture.root + "/origin/release-1", "cleanup".toArray()) } finally {
                    try { let _ = sessionA.cancel() } finally { let _ = pendingA.get() }
                }
            }
        } finally { fixture.close() }
    }
}
