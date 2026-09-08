package lsp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import process4cj.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Lsp4CjTests {
    @TestCase
    func failedWritesAndFlushesReleasePendingRequests() {
        for (flushFailure in [false, true]) {
            let process = FailedWriteProcess(!flushFailure, flushFailure: flushFailure)
            let client = LspClient(startProcess(ProcessCommand("fixture"), backend: FailedWriteBackend(process)))
            try {
                for (_ in 0..3) {
                    @Expect(client.request("echo", jsonObject([])).isOk(), false)
                    @Expect(client.pendingCount(), 0)
                }
                @Expect(process.writes.load(), 3)
            } finally { let _ = client.close() }
        }
    }

    @TestCase
    func framesAndDecodesMessages() {
        let source = jsonObject([
            JsonObjectEntry("jsonrpc", jsonString("2.0")),
            JsonObjectEntry("method", jsonString("initialized"))
        ])
        let stream = ByteBuffer()
        stream.write(encodeLspMessage(source))
        match (readLspMessage(stream)) {
            case LspResult.Ok(value) => @Expect(value.field("method").getOrThrow().text, "initialized")
            case LspResult.Err(error) => @Fail(error.message)
        }
    }

    @TestCase
    func correlatesAndRejectsMalformedFrames() {
        let correlation = LspCorrelation()
        let id = jsonRpcNumberId(1)
        @Expect(correlation.reserve(id).isOk(), true)
        @Expect(correlation.reserve(id).isOk(), false)
        @Expect(correlation.cancel(id).isOk(), true)
        @Expect(correlation.complete(id).isOk(), false)

        let malformed = ByteBuffer()
        malformed.write("Content-Length: nope\r\n\r\n{}".toArray())
        @Expect(readLspMessage(malformed).isOk(), false)
    }

    @TestCase
    func processClientHandlesLifecycleConcurrencyAndServerRequests() {
        let notified = AtomicBool(false)
        let serverRequested = AtomicBool(false)
        let client = match (LspClient.`spawn`(
            ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", lspFixtureScript()]),
            notificationHandler: { method: String, _: JsonNode => if (method == "window/logMessage") { notified.store(true) } },
            requestHandler: { method: String, _: JsonNode =>
                if (method == "workspace/configuration") { serverRequested.store(true); LspResult.Ok(jsonArray([])) }
                else { LspResult.Err(LspError(LspErrorKind.Protocol, "unsupported", "unsupported")) }
            },
            maxFrameBytes: 65536
        )) { case LspResult.Ok(value) => value; case LspResult.Err(error) => throw error }

        match (client.initialize(jsonObject([]))) {
            case LspResult.Ok(value) => @Expect(value.field("capabilities").isSome(), true)
            case LspResult.Err(error) => @Fail(error.message)
        }
        let first = spawn { client.request("echo", jsonObject([JsonObjectEntry("value", jsonString("one"))])) }
        let second = spawn { client.request("echo", jsonObject([JsonObjectEntry("value", jsonString("two"))])) }
        @Expect(first.get().isOk(), true)
        @Expect(second.get().isOk(), true)
        var waited: Int64 = 0
        while ((!notified.load() || !serverRequested.load()) && waited < 1000) { sleep(Duration.millisecond * 5); waited += 5 }
        @Expect(notified.load(), true)
        @Expect(serverRequested.load(), true)
        match (client.request("hang", jsonObject([]), timeoutMillis: 20)) {
            case LspResult.Err(error) => match (error.kind) {
                case LspErrorKind.Deadline => ()
                case _ => @Fail("expected deadline error")
            }
            case _ => @Fail("deadline must fail")
        }
        @Expect(client.shutdown().isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(client.request("echo", jsonObject([])).isOk(), false)
    }
}

func lspFixtureScript(): String {
    "import sys,json\n" +
    "r=sys.stdin.buffer; w=sys.stdout.buffer\n" +
    "def recv():\n" +
    " h={}\n" +
    " while True:\n" +
    "  line=r.readline()\n" +
    "  if not line: return None\n" +
    "  if line in (b'\\r\\n',b'\\n'): break\n" +
    "  k,v=line.decode().split(':',1); h[k.lower()]=v.strip()\n" +
    " return json.loads(r.read(int(h['content-length'])))\n" +
    "def send(v):\n" +
    " b=json.dumps(v,separators=(',',':')).encode(); w.write(('Content-Length: %d\\r\\n\\r\\n'%len(b)).encode()+b); w.flush()\n" +
    "while True:\n" +
    " m=recv()\n" +
    " if m is None: break\n" +
    " method=m.get('method','')\n" +
    " if method=='initialize': send({'jsonrpc':'2.0','id':m['id'],'result':{'capabilities':{}}})\n" +
    " elif method=='initialized': send({'jsonrpc':'2.0','method':'window/logMessage','params':{}}); send({'jsonrpc':'2.0','id':99,'method':'workspace/configuration','params':{}})\n" +
    " elif method=='hang': pass\n" +
    " elif method=='shutdown': send({'jsonrpc':'2.0','id':m['id'],'result':None})\n" +
    " elif method=='exit': break\n" +
    " elif 'id' in m: send({'jsonrpc':'2.0','id':m['id'],'result':m.get('params',{})})\n"
}

class FailedWriteInput <: InputStream {
    let stopped: AtomicBool
    init(stopped: AtomicBool) { this.stopped = stopped }
    public func read(buffer: Array<Byte>): Int64 {
        while (!stopped.load()) { sleep(Duration.millisecond * 1) }
        0
    }
}
class FailedWriteProcess <: ProcessPlatformProcess {
    let stopped = AtomicBool(false)
    let writes = AtomicInt64(0)
    let reject: Bool
    let flushFailure: Bool
    init(reject: Bool, flushFailure!: Bool = false) { this.reject = reject; this.flushFailure = flushFailure }
    public prop pid: Int64 { get() { 7 } }
    public prop stdout: InputStream { get() { FailedWriteInput(stopped) } }
    public prop stderr: InputStream { get() { FailedWriteInput(stopped) } }
    public func writeInput(data: Array<Byte>): Unit {
        writes.fetchAdd(1)
        if (reject) { throw ProcessError(ProcessErrorKind.BrokenPipe, "injected write failure") }
    }
    public func flushInput(): Unit { if (flushFailure) { throw ProcessError(ProcessErrorKind.BrokenPipe, "injected flush failure") } }
    public func closeInput(): Unit {}
    public func inputCloseSupported(): Bool { true }
    public func wait(): Int64 { while (!stopped.load()) { sleep(Duration.millisecond * 1) }; 0 }
    public func terminate(force: Bool, processTree: Bool): Bool { stopped.store(true); true }
    public func isAlive(): Bool { !stopped.load() }
    public func close(): Unit { stopped.store(true) }
}
class FailedWriteBackend <: ProcessBackend {
    let process: FailedWriteProcess
    init(process: FailedWriteProcess) { this.process = process }
    public func launchProcess(command: ProcessCommand): ProcessPlatformProcess { process }
}
