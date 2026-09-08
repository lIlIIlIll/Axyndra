package dap4cj

import yjson.*
import yjson_support.*
import process4cj.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Dap4CjTests {
    @TestCase
    func failedWritesAndFlushesReleasePendingRequests() {
        for (flushFailure in [false, true]) {
            let process = FailedWriteProcess(!flushFailure, flushFailure: flushFailure)
            let client = DapClient(startProcess(ProcessCommand("fixture"), backend: FailedWriteBackend(process)))
            try {
                for (_ in 0..3) {
                    @Expect(client.beginRequest("echo", jsonObject([])).isOk(), false)
                    @Expect(client.pendingCount(), 0)
                }
                @Expect(process.writes.load(), 3)
            } finally { let _ = client.close() }
        }
    }

    @TestCase
    func invalidRequestTimeoutDoesNotSendOrReserve() {
        let process = FailedWriteProcess(false)
        let client = DapClient(startProcess(ProcessCommand("fixture"), backend: FailedWriteBackend(process)))
        try {
            for (timeout in [0, -1]) {
                @Expect(client.request("launch", jsonObject([]), timeoutMillis: timeout).isOk(), false)
                @Expect(process.writes.load(), 0)
                @Expect(client.pendingCount(), 0)
            }
        } finally { let _ = client.close() }
    }

    @TestCase
    func framesAndValidatesEnvelope() {
        let request = jsonObject([
            JsonObjectEntry("seq", jsonNumber("1")),
            JsonObjectEntry("type", jsonString("request")),
            JsonObjectEntry("command", jsonString("initialize"))
        ])
        let stream = ByteBuffer()
        stream.write(encodeDapMessage(request))
        @Expect(readDapMessage(stream).isOk(), true)

        let invalid = ByteBuffer()
        invalid.write(encodeDapMessage(jsonObject([])))
        @Expect(readDapMessage(invalid).isOk(), false)
    }

    @TestCase
    func correlatesResponsesExactlyOnce() {
        let correlation = DapCorrelation()
        @Expect(correlation.reserve(7).isOk(), true)
        @Expect(correlation.reserve(7).isOk(), false)
        @Expect(correlation.complete(8).isOk(), false)
        @Expect(correlation.complete(7).isOk(), true)
        @Expect(correlation.complete(7).isOk(), false)
    }

    @TestCase
    func processClientHandlesLifecycleEventsReverseRequestsAndDeadlines() {
        let eventSeen = AtomicBool(false)
        let reverseSeen = AtomicBool(false)
        let client = match (DapClient.`spawn`(
            ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", dapFixtureScript()]),
            eventHandler: { event: String, _: JsonNode => if (event == "initialized") { eventSeen.store(true) } },
            reverseRequestHandler: { command: String, _: JsonNode =>
                if (command == "runInTerminal") { reverseSeen.store(true); DapResult.Ok(jsonObject([])) }
                else { DapResult.Err(DapError(DapErrorKind.Protocol, "unsupported", "unsupported")) }
            },
            maxFrameBytes: 65536
        )) { case DapResult.Ok(value) => value; case DapResult.Err(error) => throw error }
        @Expect(client.initialize(jsonObject([])).isOk(), true)
        let first = spawn { client.request("echo", jsonObject([JsonObjectEntry("value", jsonString("one"))])) }
        let second = spawn { client.request("echo", jsonObject([JsonObjectEntry("value", jsonString("two"))])) }
        @Expect(first.get().isOk(), true)
        @Expect(second.get().isOk(), true)
        var waited: Int64 = 0
        while ((!eventSeen.load() || !reverseSeen.load()) && waited < 1000) { sleep(Duration.millisecond * 5); waited += 5 }
        @Expect(eventSeen.load(), true)
        @Expect(reverseSeen.load(), true)
        let pending = client.beginRequest("hang", jsonObject([]))
        let sequence = match (pending) { case DapResult.Ok(value) => value; case DapResult.Err(error) => throw error }
        @Expect(client.cancel(sequence).isOk(), true)
        @Expect(client.pendingCount(), 1)
        match (client.waitResponse(sequence)) {
            case DapResult.Err(error) => match (error.kind) {
                case DapErrorKind.Cancelled => ()
                case _ => @Fail("expected cancellation")
            }
            case _ => @Fail("cancelled request must fail")
        }
        @Expect(client.pendingCount(), 0)
        match (client.request("hang", jsonObject([]), timeoutMillis: 20)) {
            case DapResult.Err(error) => match (error.kind) {
                case DapErrorKind.Deadline => ()
                case _ => @Fail("expected deadline")
            }
            case _ => @Fail("deadline must fail")
        }
        @Expect(client.terminate().isOk(), true)
        @Expect(client.disconnect().isOk(), true)
        @Expect(client.close().isOk(), true)
    }
}

func dapFixtureScript(): String {
    "import sys,json\n" +
    "r=sys.stdin.buffer; w=sys.stdout.buffer; seq=100\n" +
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
    " cmd=m.get('command','')\n" +
    " if cmd=='initialize': send({'seq':seq,'type':'response','request_seq':m['seq'],'success':True,'command':cmd,'body':{}}); seq+=1; send({'seq':seq,'type':'event','event':'initialized','body':{}}); seq+=1; send({'seq':seq,'type':'request','command':'runInTerminal','arguments':{}}); seq+=1\n" +
    " elif cmd=='hang': pass\n" +
    " elif m.get('type')=='request': send({'seq':seq,'type':'response','request_seq':m['seq'],'success':True,'command':cmd,'body':m.get('arguments',{})}); seq+=1\n" +
    " if cmd=='disconnect': break\n"
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
