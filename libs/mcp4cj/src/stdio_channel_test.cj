package mcp4cj

import jsonrpc4cj.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Observes an actual OS process; every response/notification crosses real pipes.
class ObservedMcpStdioChannel <: McpStdioChannel {
    let child: ManagedProcess
    private let delegate: ManagedProcessMcpStdioChannel
    let writeEntered = AtomicBool(false)
    let didAbort = AtomicBool(false)
    let didStop = AtomicBool(false)
    let didClose = AtomicBool(false)
    let failWrite: Bool
    let failStop: Bool
    let failAttach: Bool

    init(script: String, failWrite!: Bool = false, failStop!: Bool = false, failAttach!: Bool = false) {
        child = startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", script]))
        delegate = ManagedProcessMcpStdioChannel(child)
        this.failWrite = failWrite
        this.failStop = failStop
        this.failAttach = failAttach
    }
    public prop stdout: InputStream { get() { delegate.stdout } }
    public prop stderr: InputStream {
        get() {
            if (failAttach) { throw IllegalStateException("private-fixture-attach-secret") }
            delegate.stderr
        }
    }
    public func write(bytes: Array<Byte>): Unit {
        writeEntered.store(true)
        if (failWrite) { throw IllegalStateException("private-fixture-write-secret") }
        delegate.write(bytes)
    }
    public func flush(): Unit { delegate.flush() }
    public func stop(gracefulShutdownMillis: Int64): Unit {
        didStop.store(true)
        delegate.stop(gracefulShutdownMillis)
        if (failStop) { throw IllegalStateException("private-fixture-stop-secret") }
    }
    public func abort(): Unit { didAbort.store(true); delegate.abort() }
    public func close(): Unit { didClose.store(true); delegate.close() }
}

func attachObservedStdio(channel: ObservedMcpStdioChannel, timeout!: Int64 = 2000): StdioMcpTransport {
    match (attachStdioMcpTransport(channel, framing: McpFramingConfig(
        maxFrameBytes: 2097152, requestTimeoutMillis: timeout, gracefulShutdownMillis: 20
    ))) {
        case McpResult.Ok(value) => value
        case McpResult.Err(error) => throw error
    }
}

func expectStdioError<T>(result: McpResult<T>, code: String): Unit {
    match (result) {
        case McpResult.Err(error) =>
            @Expect(error.code, code)
            @Expect(error.retryable, false)
            @Expect(error.retrySafe, false)
            @Expect(error.message.indexOf("private-fixture").isNone(), true)
        case McpResult.Ok(_) => @Fail("injected stdio transport unexpectedly returned success: " + code)
    }
}

func awaitStdioFlag(flag: AtomicBool): Unit {
    let deadline = MonoTime.now() + Duration.millisecond * 2000
    while (!flag.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
    if (!flag.load()) { throw IllegalStateException("injected stdio fixture did not enter write") }
}

func stdioFixtureProcessIsRunning(pid: Int64): Bool {
    try {
        let text = String.fromUtf8(File.readFrom("/proc/" + pid.toString() + "/stat"))
        // The executable's comm is python3, with no spaces or parentheses.
        let fields = text.split(" ")
        fields.size > 2 && fields[2] != "Z" && fields[2] != "X"
    } catch (_: Exception) { false }
}

@Test
class McpInjectedStdioTests {
    @TestCase
    func closeForcesDescendantsThatKeepPipesOpenAfterCommandExit() {
        let channel = ObservedMcpStdioChannel(
            "import sys,os,time,signal\n" +
            "child=os.fork()\n" +
            "if child==0:\n" +
            " os.setsid()\n" +
            " signal.signal(signal.SIGTERM,signal.SIG_IGN)\n" +
            " sys.stderr.write('descendant:'+str(os.getpid())+'\\n');sys.stderr.flush()\n" +
            " time.sleep(30)\n" +
            " os._exit(0)\n" +
            "while True: time.sleep(1)\n"
        )
        let unrelated = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]))
        let transport = attachObservedStdio(channel)
        try {
            let readyDeadline = MonoTime.now() + Duration.millisecond * 2000
            while (!transport.stderrSnapshot().endsWith("\n") && MonoTime.now() < readyDeadline) {
                sleep(Duration.millisecond * 5)
            }
            let marker = transport.stderrSnapshot()
            if (!marker.startsWith("descendant:") || !marker.endsWith("\n")) {
                throw IllegalStateException("descendant fixture did not become ready")
            }
            let descendant = Int64.parse(marker[11..].trimAscii())
            @Expect(stdioFixtureProcessIsRunning(descendant), true)
            // Reproduce the precise branch: command status is terminal before
            // close, while its escaped child still owns stdout/stderr.
            let _ = channel.child.terminate()
            let exitDeadline = MonoTime.now() + Duration.millisecond * 2000
            while (channel.child.tryExit().isNone() && MonoTime.now() < exitDeadline) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(channel.child.tryExit().isSome(), true)
            @Expect(stdioFixtureProcessIsRunning(descendant), true)
            let before = MonoTime.now()
            @Expect(transport.close().isOk(), true)
            @Expect(MonoTime.now() < before + Duration.millisecond * 2000, true)
            let deadDeadline = MonoTime.now() + Duration.millisecond * 1000
            while (stdioFixtureProcessIsRunning(descendant) && MonoTime.now() < deadDeadline) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(stdioFixtureProcessIsRunning(descendant), false)
            @Expect(unrelated.isAlive(), true)
        } finally {
            channel.abort()
            let _ = transport.close()
            let _ = unrelated.close()
        }
    }

    @TestCase
    func injectedPipesPreserveFramingCorrelationProgressAndBoundedStderr() {
        let channel = ObservedMcpStdioChannel(
            "import sys,json\n" +
            "q=json.loads(sys.stdin.readline())\n" +
            "sys.stderr.write('x'*70000);sys.stderr.flush()\n" +
            "print(json.dumps({'jsonrpc':'2.0','id':'unrelated','result':{'wrong':True}}),flush=True)\n" +
            "print(json.dumps({'jsonrpc':'2.0','method':'notifications/progress','params':{'progress':1}}),flush=True)\n" +
            "wire=json.dumps({'jsonrpc':'2.0','id':q['id'],'result':{'ok':True}})+'\\n'\n" +
            "sys.stdout.write(wire[:11]);sys.stdout.flush()\n" +
            "sys.stdout.write(wire[11:]);sys.stdout.flush()\n" +
            "sys.stdin.readline()\n"
        )
        let transport = attachObservedStdio(channel)
        let notifications = ArrayList<String>()
        try {
            let response = transport.requestWithNotifications(
                JsonRpcRequest(jsonRpcTextId("wanted"), MCP_METHOD_DISCOVER),
                { value => notifications.add(value.method) }
            )
            match (response) {
                case McpResult.Ok(value) =>
                    @Expect(sameJsonRpcId(value.id, jsonRpcTextId("wanted")), true)
                    match (value.payload) {
                        case JsonRpcResponsePayload.Success(result) => @Expect(result.field("ok").getOrThrow().asBool(), true)
                        case _ => @Fail("expected actual pipe response")
                    }
                case McpResult.Err(error) => @Fail(error.message)
            }
            @Expect(notifications.size, 1)
            @Expect(notifications[0], MCP_NOTIFICATION_PROGRESS)
        } finally { let _ = transport.close() }
        @Expect(transport.stderrSnapshot().toArray().size, 65536)
        @Expect(channel.didStop.load(), true)
        @Expect(channel.didClose.load(), true)
        @Expect(channel.child.isAlive(), false)
        @Expect(transport.close().isOk(), true)
    }

    @TestCase
    func injectedSubscriptionRetainsAcknowledgementNotificationAndCancellation() {
        let channel = ObservedMcpStdioChannel(
            "import sys,json\n" +
            "q=json.loads(sys.stdin.readline());sid=q['id']\n" +
            "meta={'io.modelcontextprotocol/subscriptionId':sid}\n" +
            "print(json.dumps({'jsonrpc':'2.0','method':'notifications/subscriptions/acknowledged','params':{'notifications':{'toolsListChanged':True},'_meta':meta}}),flush=True)\n" +
            "print(json.dumps({'jsonrpc':'2.0','method':'notifications/tools/list_changed','params':{'_meta':meta}}),flush=True)\n" +
            "cancel=json.loads(sys.stdin.readline())\n" +
            "assert cancel['method']=='notifications/cancelled' and cancel['params']['requestId']==sid\n" +
            "sys.stderr.write('cancel-observed');sys.stderr.flush()\n"
        )
        let transport = attachObservedStdio(channel)
        try {
            let handle = match (transport.openSubscription(JsonRpcRequest(
                jsonRpcTextId("subscription"),
                MCP_METHOD_SUBSCRIPTIONS_LISTEN,
                params: withMcpRequestMeta(McpSubscriptionFilter(toolsListChanged: true).toValue(), McpRequestMeta())
            ))) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => throw error
            }
            @Expect(handle.acknowledged().toolsListChanged, true)
            match (handle.next()) {
                case McpResult.Ok(Some(value)) => @Expect(value.method, MCP_NOTIFICATION_TOOLS_LIST_CHANGED)
                case _ => @Fail("injected subscription did not receive actual notification")
            }
            @Expect(handle.close().isOk(), true)
            let deadline = MonoTime.now() + Duration.millisecond * 2000
            while (transport.stderrSnapshot() != "cancel-observed" && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(transport.stderrSnapshot(), "cancel-observed")
            @Expect(transport.activeSubscriptionCount(), 0)
        } finally { let _ = transport.close() }
        @Expect(channel.child.isAlive(), false)
    }

    @TestCase
    func dispatchedToolTimeoutRemainsNonRetryableAndAbortsTheRealChannel() {
        let channel = ObservedMcpStdioChannel("import sys,time\nsys.stdin.readline()\ntime.sleep(30)\n")
        let transport = attachObservedStdio(channel, timeout: 100)
        try {
            expectStdioError(transport.request(JsonRpcRequest(jsonRpcNumberId(3), MCP_METHOD_TOOLS_CALL)), "mcp.stdio_timeout")
            @Expect(channel.writeEntered.load(), true)
            @Expect(channel.didAbort.load(), true)
        } finally { let _ = transport.close() }
        @Expect(channel.child.isAlive(), false)
    }

    @TestCase
    func dispatchedToolEofDoesNotBecomeASafeRetryOrSyntheticRemoteResult() {
        let channel = ObservedMcpStdioChannel("import sys\nsys.stdin.readline()\n")
        let transport = attachObservedStdio(channel)
        try {
            expectStdioError(transport.request(JsonRpcRequest(jsonRpcNumberId(4), MCP_METHOD_TOOLS_CALL)), "mcp.stdio_eof")
            @Expect(channel.writeEntered.load(), true)
        } finally { let _ = transport.close() }
    }

    @TestCase
    func callbackWriteExceptionIsTranslatedAndDoesNotLeakPrivateText() {
        let channel = ObservedMcpStdioChannel("import time\ntime.sleep(30)\n", failWrite: true)
        let transport = attachObservedStdio(channel)
        try {
            expectStdioError(transport.request(JsonRpcRequest(jsonRpcNumberId(5), MCP_METHOD_TOOLS_CALL)), "mcp.stdio_write_failed")
            @Expect(channel.didAbort.load(), true)
        } finally { let _ = transport.close() }
        @Expect(channel.child.isAlive(), false)
    }

    @TestCase
    func closeCallbackExceptionStillReleasesOwnershipAndIsTranslated() {
        let channel = ObservedMcpStdioChannel("import time\ntime.sleep(30)\n", failStop: true)
        let transport = attachObservedStdio(channel)
        expectStdioError(transport.close(), "mcp.stdio_close_failed")
        @Expect(channel.didAbort.load(), true)
        @Expect(channel.didClose.load(), true)
        @Expect(channel.child.isAlive(), false)
        @Expect(transport.state() == McpLifecycleState.Stopped, true)
        @Expect(transport.close().isOk(), true)
    }

    @TestCase
    func failedAttachCleansUpTransferredChannelAndDoesNotExposePrivateText() {
        let channel = ObservedMcpStdioChannel("import time\ntime.sleep(30)\n", failAttach: true)
        expectStdioError(attachStdioMcpTransport(channel), "mcp.stdio_start_failed")
        @Expect(channel.didAbort.load(), true)
        @Expect(channel.didClose.load(), true)
        @Expect(channel.child.isAlive(), false)
    }

    @TestCase
    func closeInterruptsAFullPipeWithoutTakingTheTransportWriterLock() {
        let channel = ObservedMcpStdioChannel(
            "import sys,time,signal\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n" +
            "sys.stderr.write('ready');sys.stderr.flush()\ntime.sleep(30)\n"
        )
        let transport = attachObservedStdio(channel)
        let finished = AtomicBool(false)
        let writing = spawn {
            try {
                let deadline = MonoTime.now() + Duration.millisecond * 2000
                while (transport.stderrSnapshot() != "ready" && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 5)
                }
                if (transport.stderrSnapshot() != "ready") {
                    throw IllegalStateException("full-pipe fixture did not install its TERM handler")
                }
                transport.notify(JsonRpcNotification("fixture/large", params: jsonObject([
                    JsonObjectEntry("data", jsonString(String.fromUtf8(Array<Byte>(1048576, repeat: 120))))
                ])))
            } finally { finished.store(true) }
        }
        try {
            awaitStdioFlag(channel.writeEntered)
            sleep(Duration.millisecond * 50)
            @Expect(finished.load(), false)
            let before = MonoTime.now()
            @Expect(transport.close().isOk(), true)
            let result = writing.get()
            @Expect(MonoTime.now() < before + Duration.millisecond * 2000, true)
            expectStdioError(result, "mcp.stdio_write_failed")
            @Expect(channel.child.isAlive(), false)
        } finally {
            channel.abort()
            let _ = transport.close()
            let _ = writing.get()
        }
    }
}
