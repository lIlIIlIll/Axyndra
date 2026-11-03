package mcp4cj

import jsonrpc4cj.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func requirePrepared<T>(result: McpResult<T>): T {
    match (result) { case McpResult.Ok(value) => value; case McpResult.Err(error) => throw error }
}

func expectPreparedError<T>(result: McpResult<T>, code: String): Unit {
    match (result) {
        case McpResult.Err(error) => @Expect(error.code, code)
        case McpResult.Ok(_) => @Fail("prepared request unexpectedly succeeded: " + code)
    }
}

func preparedResultText(result: McpResult<McpCallToolOutcome>): String {
    match (result) {
        case McpResult.Ok(McpCallToolOutcome.Complete(value)) =>
            if (value.content.size != 1) { throw IllegalStateException("expected one real response content block") }
            value.content[0].field("text").getOrThrow().text
        case McpResult.Err(error) => throw error
        case _ => throw IllegalStateException("expected complete real tool response")
    }
}

func preparedEchoScript(): String {
    "import sys,json\n" +
    "for line in sys.stdin:\n" +
    " q=json.loads(line)\n" +
    " if 'id' not in q: continue\n" +
    " result={'resultType':'complete','content':[{'type':'text','text':line[:-1]}]}\n" +
    " if q['method']=='server/discover': result={'resultType':'complete','supportedVersions':['2026-07-28'],'capabilities':{},'ttlMs':0,'cacheScope':'private'}\n" +
    " sys.stderr.write(str(q['id'])+'\\n');sys.stderr.flush()\n" +
    " print(json.dumps({'jsonrpc':'2.0','method':'notifications/progress','params':{'progress':1}}),flush=True)\n" +
    " print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':result}),flush=True)\n"
}

@Test
class McpPreparedToolCallTests {
    @TestCase
    func preparationFreezesBytesAndMetadataWithoutConsumingSequenceOrWriting() {
        let channel = ObservedMcpStdioChannel(preparedEchoScript())
        let transport = attachObservedStdio(channel)
        let notices = ArrayList<String>()
        let experimental = jsonObject([JsonObjectEntry("frozen", jsonBool(true))])
        let client = McpClient(transport, McpRequestMeta(
            clientInfo: Some(McpImplementationInfo("prepared-client", "1")),
            clientCapabilities: McpClientCapabilities(experimental: experimental)
        ), notificationSink: { value => notices.add(value.method) })
        try {
            let arguments = jsonObject([JsonObjectEntry("text", jsonString("雪\n\\\" exact"))])
            let responses = jsonObject([JsonObjectEntry("answer", jsonObject([JsonObjectEntry("ok", jsonBool(true))]))])
            let continuation = McpToolCallContinuation(inputResponses: responses,
                requestState: "state-1", progressToken: jsonString("progress-1"))
            let prepared = requirePrepared(client.prepareToolCall("host:run:call", "echo", arguments,
                continuation: continuation, owner: "owner"))
            let same = requirePrepared(client.prepareToolCall("host:run:call", "echo", arguments,
                continuation: continuation, owner: "owner"))
            @Expect(prepared.rpcJson, same.rpcJson)
            @Expect(channel.writeEntered.load(), false)
            @Expect(client.pendingCount(), 0)
            arguments.put("text", jsonString("mutated"))
            responses.put("answer", jsonObject([JsonObjectEntry("ok", jsonBool(false))]))
            experimental.put("frozen", jsonBool(false))
            let exported = prepared.stdioFrame(); exported[0] = 0
            @Expect(String.fromUtf8(prepared.stdioFrame()), prepared.rpcJson + "\n")
            let wire = requirePrepared(client.dispatchPreparedToolCall(prepared))
            match (wire) {
                case McpCallToolOutcome.Complete(value) => @Expect(value.content[0].field("text").getOrThrow().text, prepared.rpcJson)
                case _ => @Fail("expected prepared exact-byte result")
            }
            let frozen = prepared.request().params
            @Expect(mcpText(mcpObject(frozen, "arguments"), "text"), "雪\n\\\" exact")
            @Expect(mcpText(frozen, "requestState"), "state-1")
            @Expect(mcpText(mcpObject(frozen, "_meta"), "progressToken"), "progress-1")
            @Expect(mcpObject(mcpObject(mcpObject(frozen, "_meta"), MCP_META_CLIENT_CAPABILITIES),
                "experimental").field("frozen").getOrThrow().asBool(), true)
            @Expect(mcpObject(mcpObject(frozen, "inputResponses"), "answer").field("ok").getOrThrow().asBool(), true)
            @Expect(client.discover().isOk(), true)
            let deadline = MonoTime.now() + Duration.millisecond * 1000
            while (!transport.stderrSnapshot().endsWith("1\n") && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(transport.stderrSnapshot(), "host:run:call\n1\n")
            @Expect(notices.size, 2)
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func duplicateIdentityAndForeignSessionCannotProduceAnotherPipeRequest() {
        let channel = ObservedMcpStdioChannel(preparedEchoScript())
        let transport = attachObservedStdio(channel)
        let client = McpClient(transport, McpRequestMeta())
        let otherChannel = ObservedMcpStdioChannel(preparedEchoScript())
        let other = McpClient(attachObservedStdio(otherChannel), McpRequestMeta())
        try {
            let first = requirePrepared(client.prepareToolCall("stable", "echo", jsonObject([])))
            let changed = requirePrepared(client.prepareToolCall("stable", "echo",
                jsonObject([JsonObjectEntry("changed", jsonBool(true))])))
            expectPreparedError(other.dispatchPreparedToolCall(first), "mcp.prepared_session_mismatch")
            @Expect(otherChannel.writeEntered.load(), false)
            @Expect(preparedResultText(client.dispatchPreparedToolCall(first)), first.rpcJson)
            expectPreparedError(client.dispatchPreparedToolCall(first), "mcp.prepared_already_dispatched")
            expectPreparedError(client.dispatchPreparedToolCall(changed), "mcp.prepared_already_dispatched")
            @Expect(client.callTool("echo", jsonObject([])).isOk(), true)
            let deadline = MonoTime.now() + Duration.millisecond * 1000
            while (!transport.stderrSnapshot().endsWith("1\n") && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(transport.stderrSnapshot(), "stable\n1\n")
        } finally { try { let _ = client.close() } finally { let _ = other.close() } }
    }

    @TestCase
    func cancelKeepsActualStringCorrelationAndNeverMakesPreparedIdReusable() {
        let channel = ObservedMcpStdioChannel(
            "import sys,json\nq=json.loads(sys.stdin.readline())\n" +
            "sys.stderr.write('ready\\n');sys.stderr.flush()\n" +
            "c=json.loads(sys.stdin.readline())\n" +
            "assert c['method']=='notifications/cancelled' and c['params']['requestId']==q['id']\n" +
            "sys.stderr.write('cancel:'+c['params']['requestId']+'\\n');sys.stderr.flush()\n" +
            "print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':{'resultType':'complete','content':[]}}),flush=True)\n" +
            "sys.stdin.readline()\n"
        )
        let transport = attachObservedStdio(channel)
        let client = McpClient(transport, McpRequestMeta())
        let prepared = requirePrepared(client.prepareToolCall("cancel-stable", "echo", jsonObject([]), owner: "owned"))
        let running = spawn { client.dispatchPreparedToolCall(prepared) }
        try {
            let deadline = MonoTime.now() + Duration.millisecond * 2000
            while (!transport.stderrSnapshot().startsWith("ready\n") && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(transport.stderrSnapshot().startsWith("ready\n"), true)
            @Expect(sameJsonRpcId(client.activeRequestId("owned").getOrThrow(), jsonRpcTextId("cancel-stable")), true)
            @Expect(client.cancel("owned").isOk(), true)
            expectPreparedError(running.get(), "mcp.request_cancelled")
            @Expect(transport.stderrSnapshot(), "ready\ncancel:cancel-stable\n")
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.prepared_already_dispatched")
            @Expect(client.pendingCount(), 0)
            @Expect(client.activeRequestId("owned").isNone(), true)
        } finally { let _ = client.close(); let _ = running.get() }
    }

    @TestCase
    func postDispatchTimeoutRemainsUnsafeAndCannotBeReplayed() {
        let channel = ObservedMcpStdioChannel("import sys,time\nsys.stdin.readline()\ntime.sleep(30)\n")
        let client = McpClient(attachObservedStdio(channel, timeout: 100), McpRequestMeta())
        try {
            let prepared = requirePrepared(client.prepareToolCall("timeout", "effect", jsonObject([])))
            expectStdioError(client.dispatchPreparedToolCall(prepared), "mcp.stdio_timeout")
            @Expect(channel.writeEntered.load(), true)
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.prepared_already_dispatched")
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func postDispatchDisconnectRemainsUnsafeAndCannotBeReplayed() {
        let channel = ObservedMcpStdioChannel("import sys\nsys.stdin.readline()\n")
        let client = McpClient(attachObservedStdio(channel), McpRequestMeta())
        try {
            let prepared = requirePrepared(client.prepareToolCall("eof", "effect", jsonObject([])))
            expectStdioError(client.dispatchPreparedToolCall(prepared), "mcp.stdio_eof")
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.prepared_already_dispatched")
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func frozenKnownToolKeepsOutcomeValidationAfterDirectoryInvalidation() {
        let channel = ObservedMcpStdioChannel(
            "import sys,json\n" +
            "for line in sys.stdin:\n" +
            " q=json.loads(line)\n" +
            " result={'resultType':'complete','content':[]}\n" +
            " if q['method']=='tools/list': result={'resultType':'complete','tools':[{'name':'strict','description':'strict','inputSchema':{'type':'object'},'outputSchema':{'type':'object'}}],'ttlMs':0,'cacheScope':'private'}\n" +
            " print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':result}),flush=True)\n"
        )
        let client = McpClient(attachObservedStdio(channel), McpRequestMeta())
        try {
            let page = requirePrepared(client.listTools())
            let prepared = requirePrepared(client.prepareToolCall("schema", "strict", jsonObject([])))
            page.tools[0].outputSchema.put("mutated", jsonBool(true))
            client.invalidateToolDirectory()
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.structured_content_missing")
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.prepared_already_dispatched")
        } finally { let _ = client.close() }
    }

    @TestCase
    func invalidOrOversizedPreparationDoesNotDispatchOrReserveIds() {
        let channel = ObservedMcpStdioChannel(preparedEchoScript())
        let transport = attachObservedStdio(channel)
        let client = McpClient(transport, McpRequestMeta())
        try {
            for (id in ["", "with space", "line\n", "雪", String.fromUtf8(Array<Byte>(257, repeat: 97))]) {
                expectPreparedError(client.prepareToolCall(id, "echo", jsonObject([])), "mcp.prepared_id_invalid")
            }
            expectPreparedError(client.prepareToolCall("valid", "", jsonObject([])), "mcp.call_invalid")
            expectPreparedError(client.prepareToolCall("valid", "echo", jsonArray([])), "mcp.call_invalid")
            expectPreparedError(client.prepareToolCall("valid", "echo", jsonObject([
                JsonObjectEntry("huge", jsonString(String.fromUtf8(Array<Byte>(8388608, repeat: 97))))
            ])), "mcp.prepared_request_too_large")
            @Expect(channel.writeEntered.load(), false)
            @Expect(client.pendingCount(), 0)
            let accepted = requirePrepared(client.prepareToolCall("valid", "echo", jsonObject([])))
            @Expect(preparedResultText(client.dispatchPreparedToolCall(accepted)), accepted.rpcJson)
        } finally { let _ = client.close() }
    }

    @TestCase
    func inputRequiredRemainsAnOutcomeAndNeedsANewExplicitPreparedContinuation() {
        let channel = ObservedMcpStdioChannel(
            "import sys,json\n" +
            "for line in sys.stdin:\n" +
            " q=json.loads(line);sys.stderr.write(q['id']+'\\n');sys.stderr.flush()\n" +
            " result={'resultType':'input_required','requestState':'opaque-state'}\n" +
            " if q['params'].get('requestState')=='opaque-state': result={'resultType':'complete','content':[{'type':'text','text':line[:-1]}]}\n" +
            " print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':result}),flush=True)\n"
        )
        let transport = attachObservedStdio(channel)
        let client = McpClient(transport, McpRequestMeta())
        try {
            let initial = requirePrepared(client.prepareToolCall("initial", "interactive", jsonObject([])))
            match (client.dispatchPreparedToolCall(initial)) {
                case McpResult.Ok(McpCallToolOutcome.InputRequired(value)) => @Expect(value.requestState, "opaque-state")
                case _ => @Fail("prepared request must return the real input-required outcome")
            }
            let deadline = MonoTime.now() + Duration.millisecond * 1000
            while (transport.stderrSnapshot() == "" && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(transport.stderrSnapshot(), "initial\n")
            expectPreparedError(client.dispatchPreparedToolCall(initial), "mcp.prepared_already_dispatched")
            let next = requirePrepared(client.prepareToolCall("continuation", "interactive", jsonObject([]),
                continuation: McpToolCallContinuation(requestState: "opaque-state")))
            @Expect(preparedResultText(client.dispatchPreparedToolCall(next)), next.rpcJson)
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func legacyTransportCannotSilentlyReserializeAndReplayHistoryNeverEvicts() {
        // This deliberately uses the existing transport which has not opted in
        // to exact bytes. Its regular callback must never be used as a fallback.
        let transport = InMemoryMcpTransport(McpServerBuilder().build())
        let client = McpClient(transport, McpRequestMeta())
        try {
            let first = requirePrepared(client.prepareToolCall("id-0", "echo", jsonObject([])))
            expectPreparedError(client.dispatchPreparedToolCall(first), "mcp.prepared_transport_unsupported")
            for (index in 1..4096) {
                let value = requirePrepared(client.prepareToolCall("id-" + index.toString(), "echo", jsonObject([])))
                expectPreparedError(client.dispatchPreparedToolCall(value), "mcp.prepared_transport_unsupported")
            }
            let overflow = requirePrepared(client.prepareToolCall("id-4096", "echo", jsonObject([])))
            expectPreparedError(client.dispatchPreparedToolCall(overflow), "mcp.prepared_dispatch_limit")
            expectPreparedError(client.dispatchPreparedToolCall(first), "mcp.prepared_already_dispatched")
            @Expect(transport.requests.size, 0)
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func preparedHttpBodyUsesRealExchangeAndSseWithoutBodyRewriting() {
        let calls = AtomicInt64(0)
        let host = MemoryMcpToolHost([
            McpTool("echo", "echo", jsonObject([JsonObjectEntry("type", jsonString("object"))]))
        ], { _: String, arguments: JsonNode, continuation: McpToolCallContinuation =>
            let _ = calls.fetchAdd(1)
            continuation.reportProgress(1.0)
            McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([
                jsonObject([JsonObjectEntry("type", jsonString("text")),
                    JsonObjectEntry("text", jsonString(mcpText(arguments, "text")))])
            ])))
        })
        let server = requirePrepared(openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0), McpServerBuilder().toolProvider(host).build()
        ))
        let serving = spawn { server.serve() }
        let ready = MonoTime.now() + Duration.millisecond * 3000
        while (server.state() != McpLifecycleState.Ready && MonoTime.now() < ready) { sleep(Duration.millisecond * 5) }
        let port = RecordingRealMcpHttpPort()
        let notices = ArrayList<String>()
        let client = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp", preferSse: true
        ), port), McpRequestMeta(), notificationSink: { value => notices.add(value.method) })
        try {
            @Expect(client.listTools().isOk(), true)
            let args = jsonObject([JsonObjectEntry("text", jsonString("雪 exact\n"))])
            let prepared = requirePrepared(client.prepareToolCall("http:run:call", "echo", args,
                continuation: McpToolCallContinuation(progressToken: jsonString("progress"))))
            @Expect(port.requests().size, 1)
            args.put("text", jsonString("changed"))
            @Expect(preparedResultText(client.dispatchPreparedToolCall(prepared)), "雪 exact\n")
            @Expect(port.requests().size, 2)
            @Expect(port.requests()[1].body, prepared.rpcJson)
            @Expect(calls.load(), 1)
            @Expect(notices.size, 1)
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.prepared_already_dispatched")
            @Expect(port.requests().size, 2)
            @Expect(calls.load(), 1)
        } finally {
            try { let _ = client.close() }
            finally { let _ = server.close(); let _ = serving.get() }
        }
    }
}
