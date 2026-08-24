package dap4cj

import json4cj.*
import process4cj.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Dap4CjTests {
    @TestCase
    func framesAndValidatesEnvelope() {
        let request = JsonValue.objectValue([
            JsonField("seq", JsonValue.numberValue("1")),
            JsonField("type", JsonValue.stringValue("request")),
            JsonField("command", JsonValue.stringValue("initialize"))
        ])
        let stream = ByteBuffer()
        stream.write(encodeDapMessage(request))
        @Expect(readDapMessage(stream).isOk(), true)

        let invalid = ByteBuffer()
        invalid.write(encodeDapMessage(JsonValue.objectValue([])))
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
            eventHandler: { event: String, _: JsonValue => if (event == "initialized") { eventSeen.store(true) } },
            reverseRequestHandler: { command: String, _: JsonValue =>
                if (command == "runInTerminal") { reverseSeen.store(true); DapResult.Ok(JsonValue.objectValue([])) }
                else { DapResult.Err(DapError(DapErrorKind.Protocol, "unsupported", "unsupported")) }
            },
            maxFrameBytes: 65536
        )) { case DapResult.Ok(value) => value; case DapResult.Err(error) => throw error }
        @Expect(client.initialize(JsonValue.objectValue([])).isOk(), true)
        let first = spawn { client.request("echo", JsonValue.objectValue([JsonField("value", JsonValue.stringValue("one"))])) }
        let second = spawn { client.request("echo", JsonValue.objectValue([JsonField("value", JsonValue.stringValue("two"))])) }
        @Expect(first.get().isOk(), true)
        @Expect(second.get().isOk(), true)
        var waited: Int64 = 0
        while ((!eventSeen.load() || !reverseSeen.load()) && waited < 1000) { sleep(Duration.millisecond * 5); waited += 5 }
        @Expect(eventSeen.load(), true)
        @Expect(reverseSeen.load(), true)
        let pending = client.beginRequest("hang", JsonValue.objectValue([]))
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
        match (client.request("hang", JsonValue.objectValue([]), timeoutMillis: 20)) {
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
