package lsp4cj

import json4cj.*
import jsonrpc4cj.*
import process4cj.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Lsp4CjTests {
    @TestCase
    func framesAndDecodesMessages() {
        let source = JsonValue.objectValue([
            JsonField("jsonrpc", JsonValue.stringValue("2.0")),
            JsonField("method", JsonValue.stringValue("initialized"))
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
            notificationHandler: { method: String, _: JsonValue => if (method == "window/logMessage") { notified.store(true) } },
            requestHandler: { method: String, _: JsonValue =>
                if (method == "workspace/configuration") { serverRequested.store(true); LspResult.Ok(JsonValue.arrayValue([])) }
                else { LspResult.Err(LspError(LspErrorKind.Protocol, "unsupported", "unsupported")) }
            },
            maxFrameBytes: 65536
        )) { case LspResult.Ok(value) => value; case LspResult.Err(error) => throw error }

        match (client.initialize(JsonValue.objectValue([]))) {
            case LspResult.Ok(value) => @Expect(value.field("capabilities").isSome(), true)
            case LspResult.Err(error) => @Fail(error.message)
        }
        let first = spawn { client.request("echo", JsonValue.objectValue([JsonField("value", JsonValue.stringValue("one"))])) }
        let second = spawn { client.request("echo", JsonValue.objectValue([JsonField("value", JsonValue.stringValue("two"))])) }
        @Expect(first.get().isOk(), true)
        @Expect(second.get().isOk(), true)
        var waited: Int64 = 0
        while ((!notified.load() || !serverRequested.load()) && waited < 1000) { sleep(Duration.millisecond * 5); waited += 5 }
        @Expect(notified.load(), true)
        @Expect(serverRequested.load(), true)
        match (client.request("hang", JsonValue.objectValue([]), timeoutMillis: 20)) {
            case LspResult.Err(error) => match (error.kind) {
                case LspErrorKind.Deadline => ()
                case _ => @Fail("expected deadline error")
            }
            case _ => @Fail("deadline must fail")
        }
        @Expect(client.shutdown().isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(client.request("echo", JsonValue.objectValue([])).isOk(), false)
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
