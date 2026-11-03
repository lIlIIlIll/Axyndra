package agent_product

import agent_domain.*
import agent_ports.*
import model_provider_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func modelLifetimeRequest(root: String, owner: ProcessResourceOwner, timeout: Int64): ProcessRequest {
    ProcessRequest("/usr/bin/python3", resourceOwner: Some(owner), arguments: [root + "/resource.py"],
        workingDirectory: root, filesystemRoot: root, sandboxMode: ProcessSandboxMode.IsolatedReadOnly,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), timeoutMillis: timeout,
        processLimits: ExecutionResourceLimits(maxOutputBytes: 4096))
}

@Test
class ModelChannelLifetimeTests {
    @TestCase
    func zeroAndLongTimeoutNeedActualModelGateAndKeepRawLimits(): Unit {
        for (timeout in [0, 3600001]) {
            let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
            let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
            let ordinary = CancellationSource(); let checked = AtomicBool(false)
            try {
                let raw = ProcessResourceOwner.Operation(OperationId("raw-limits"))
                if (timeout == 0) {
                    var rejected = false
                    try { let _ = modelLifetimeRequest(root, raw, timeout) }
                    catch (_: IllegalArgumentException) { rejected = true }
                    @Expect(rejected)
                } else {
                    @Expect(port.openChannel(modelLifetimeRequest(root, raw, timeout), ordinary.token, 4096).error().getOrThrow().code,
                        "process.channel_limits_invalid")
                }
                let guessed = ProcessResourceOwner.ModelAttempt(ModelAttemptId("guessed-lifetime"), "worker")
                @Expect(port.openChannel(modelLifetimeRequest(root, guessed, timeout), ordinary.token, 4096).error().getOrThrow().code,
                    "model.process_admission_denied")
                @Expect(!port.hasActiveResource(guessed))
                @Expect(port.openChannel(modelLifetimeRequest(root, raw, 5000), ordinary.token, 67108864).error().getOrThrow().code,
                    "process.channel_limits_invalid")
                @Expect(!port.hasActiveResource(raw))
                fixture.factory.beforeOpen = { actual =>
                    let owner = ProcessResourceOwner.ModelAttempt(actual.attemptId, "lifetime-probe")
                    let channel = lifecycleTestRequire(port.openModelChannel(modelLifetimeRequest(root, owner, timeout), actual, fixture.gate.actual, 67108864))
                    try {
                        @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
                        lifecycleTestRequire(channel.write("ping\n".toArray()))
                        @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 5)), "PONG\n")
                        @Expect(port.hasActiveResource(owner))
                        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE dispatch_state='dispatch_claimed'"), 1)
                        checked.store(true)
                    } finally { modelResourceClose(port, owner) }
                }
                @Expect(fixture.run().isOk() && checked.load())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            } finally { try { let _ = port.close() } finally { ordinary.close(); fixture.close(); remove(root, recursive: true) } }
        }
    }

    @TestCase
    func zeroTimeoutActualRunCancellationStillReapsItsProcess(): Unit {
        let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true); let checked = AtomicBool(false)
        let cancellation = ModelExternalCancellationProbe()
        try {
            fixture.factory.beforeOpen = { actual =>
                let owner = ProcessResourceOwner.ModelAttempt(actual.attemptId, "zero-deadline-probe")
                let channel = lifecycleTestRequire(port.openModelChannel(modelLifetimeRequest(root, owner, 0), actual, fixture.gate.actual, 67108864))
                try {
                    @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
                    println("MODEL_ZERO_CANCEL_STAGE ready")
                    cancellation.awaitCancellation(actual)
                    println("MODEL_ZERO_CANCEL_STAGE cancelled")
                    modelResourceClose(port, owner)
                    @Expect(!port.hasActiveResource(owner))
                    lifecycleTestRequire(channel.close())
                    @Expect(channel.write("late\n".toArray()).isError())
                    checked.store(true)
                } finally { modelResourceClose(port, owner) }
            }
            let runResult = cancellation.run(fixture)
            println("MODEL_ZERO_CANCEL_DIAGNOSTIC result_ok=" + runResult.isOk().toString() + " checked=" + checked.load().toString() + " factory_count=" + fixture.factory.count().toString())
            match (runResult.error()) { case Some(error) => println("MODEL_ZERO_CANCEL_ERROR " + error.describe()); case None => () }
            for (row in fixture.database.query("SELECT state FROM runs WHERE id='provider-run'")) { println("MODEL_ZERO_CANCEL_RUN state=" + row.required(0)) }
            @Expect(runResult.isError() && checked.load())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
    }

    @TestCase
    func actualModelInputAboveRawCeilingStillHasAnExactCumulativeBound(): Unit {
        let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true); let checked = AtomicBool(false)
        let total: Int64 = 17825792
        File.writeTo(root + "/resource.py", ("import sys\nprint('READY',flush=True)\nremaining=17825792\n" +
            "while remaining:\n data=sys.stdin.buffer.read(min(65536,remaining))\n if not data: raise SystemExit(2)\n" +
            " if data != b'x'*len(data): raise SystemExit(3)\n remaining-=len(data)\n" +
            "print('EXACT',flush=True)\nsys.stdin.buffer.read()\n").toArray())
        try {
            fixture.factory.beforeOpen = { actual =>
                let owner = ProcessResourceOwner.ModelAttempt(actual.attemptId, "large-input-probe")
                let channel = lifecycleTestRequire(port.openModelChannel(modelLifetimeRequest(root, owner, 0), actual, fixture.gate.actual, total))
                try {
                    @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
                    let chunk = Array<Byte>(65536, repeat: b'x')
                    for (_ in 0..(total / 65536)) { lifecycleTestRequire(channel.write(chunk)) }
                    @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "EXACT\n")
                    @Expect(channel.write("x".toArray()).error().getOrThrow().code, "process.channel_input_limit")
                    checked.store(true)
                } finally { modelResourceClose(port, owner) }
            }
            @Expect(fixture.run().isOk() && checked.load())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
    }

    @TestCase
    func installedFrameBetween64And256KiBUsesBoundedPhysicalWrites(): Unit {
        let fixture = InstalledModelProductFixture("chat", contextWindow: 1048576, timeoutMillis: 0)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("mid-physical-model")))
            session.setThinking(ThinkingLevel.Off)
            lifecycleTestRequire(session.submit(String.fromUtf8(Array<Byte>(90000, repeat: b'p'))))
            @Expect(fixture.observed().size, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }
}
