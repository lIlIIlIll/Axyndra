package lsp4cj

import process4cj.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func lspPreparedRequire<T>(result: LspResult<T>): T {
    match (result) { case LspResult.Ok(value) => value; case LspResult.Err(error) => throw error }
}
func lspPreparedCode<T>(result: LspResult<T>): String {
    match (result) { case LspResult.Ok(_) => "unexpected-success"; case LspResult.Err(error) => error.code }
}
func preparedLspScript(): String {
    "import sys,json\n" +
    "r=sys.stdin.buffer; w=sys.stdout.buffer; docs={}\n" +
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
    " method=m.get('method',''); p=m.get('params',{})\n" +
    " if method=='textDocument/didOpen':\n" +
    "  d=p['textDocument']; docs[d['uri']]={'text':d['text'],'version':d['version']}; send({'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':d['uri'],'diagnostics':[]}})\n" +
    " elif method=='textDocument/didChange':\n" +
    "  d=p['textDocument']; docs[d['uri']]={'text':p['contentChanges'][0]['text'],'version':d['version']}\n" +
    " elif method=='hang': pass\n" +
    " elif 'id' in m: send({'jsonrpc':'2.0','id':m['id'],'result':{'params':p,'documents':docs}})\n"
}

@Test
class LspPreparedChannelTests {
    @TestCase
    func leaderOnlyFactoryRejectsBeforeAttemptingSpawn(): Unit {
        let result = LspClient.`spawn`(ProcessCommand("/definitely-not-a-protocol-executable",
            terminateProcessTree: false))
        @Expect(lspPreparedCode(result), "lsp.channel_tree_required")
    }

    @TestCase
    func pureBatchFreezesDocumentChangesAndUsesOneActualWrite(): Unit {
        let channel = PreparedObservedChannel(preparedLspScript())
        let notice = AtomicBool(false)
        let client = LspClient(channel, maxFrameBytes: 1048576,
            notificationHandler: { method, _ => if (method == "textDocument/publishDiagnostics") { notice.store(true) } })
        try {
            let document = jsonObject([JsonObjectEntry("uri", jsonString("file:///workspace/a.py")),
                JsonObjectEntry("languageId", jsonString("python")), JsonObjectEntry("version", jsonNumber("1")),
                JsonObjectEntry("text", jsonString("before"))])
            let parameters = jsonObject([JsonObjectEntry("value", jsonString("frozen"))])
            let notifications = [LspNotification("textDocument/didOpen", jsonObject([JsonObjectEntry("textDocument", document)])),
                LspNotification("textDocument/didChange", parseUnifiedJson("{\"textDocument\":{\"uri\":\"file:///workspace/a.py\",\"version\":2},\"contentChanges\":[{\"text\":\"after\"}]}"))]
            let prepared = lspPreparedRequire(client.prepareRequest("host-call-1", "echo", parameters, notifications: notifications))
            let same = lspPreparedRequire(client.prepareRequest("host-call-1", "echo", parameters, notifications: notifications))
            @Expect(String.fromUtf8(prepared.framedBytes()), String.fromUtf8(same.framedBytes()))
            @Expect(channel.writes.load(), 0)
            @Expect(client.pendingCount(), 0)
            parameters.put("value", jsonString("mutated")); document.put("text", jsonString("mutated"))
            let bytes = prepared.framedBytes(); bytes[0] = 0
            let response = lspPreparedRequire(client.dispatchPrepared(prepared, timeoutMillis: 1000))
            @Expect(channel.writes.load(), 1)
            @Expect(channel.lastWrite(), String.fromUtf8(prepared.framedBytes()))
            @Expect(response.field("params").getOrThrow().field("value").getOrThrow().text, "frozen")
            let actual = response.field("documents").getOrThrow().field("file:///workspace/a.py").getOrThrow()
            @Expect(actual.field("text").getOrThrow().text, "after")
            @Expect(actual.field("version").getOrThrow().asNumberText(), "2")
            @Expect(notice.load(), true)
            // Numeric legacy IDs and opaque prepared IDs share one correlation list.
            @Expect(client.request("echo", jsonObject([]), timeoutMillis: 1000).isOk(), true)
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func foreignReusedAndFailedPreparedDispatchCannotWriteAgain(): Unit {
        let channel = PreparedObservedChannel(preparedLspScript())
        let foreignChannel = PreparedObservedChannel(preparedLspScript())
        let client = LspClient(channel); let foreignClient = LspClient(foreignChannel)
        try {
            let prepared = lspPreparedRequire(client.prepareRequest("bound-key", "echo", jsonObject([])))
            @Expect(lspPreparedCode(foreignClient.dispatchPrepared(prepared)), "lsp.prepared_foreign")
            @Expect(foreignChannel.writes.load(), 0)
            channel.reject.store(true)
            @Expect(lspPreparedCode(client.dispatchPrepared(prepared)), "lsp.write_failed")
            channel.reject.store(false)
            @Expect(lspPreparedCode(client.dispatchPrepared(prepared)), "lsp.prepared_reused")
            @Expect(channel.writes.load(), 1)
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close(); let _ = foreignClient.close() }
    }

    @TestCase
    func preparedDeadlineAbortsWithoutUndeclaredCancelBytes(): Unit {
        let channel = PreparedObservedChannel(preparedLspScript()); let client = LspClient(channel)
        try {
            let prepared = lspPreparedRequire(client.prepareRequest("deadline-key", "hang", jsonObject([])))
            @Expect(lspPreparedCode(client.dispatchPrepared(prepared, timeoutMillis: 30)), "lsp.prepared_deadline")
            @Expect(channel.writes.load(), 1)
            @Expect(channel.lastWrite(), String.fromUtf8(prepared.framedBytes()))
            @Expect(client.pendingCount(), 0)
            @Expect(client.dispatchPrepared(prepared).isOk(), false)
        } finally { let _ = client.close() }
    }

    @TestCase
    func failedCleanupRetainsOwnershipAndRetriesTheActualChannel(): Unit {
        let channel = PreparedObservedChannel(preparedLspScript(), rejectFirstStop: true); let client = LspClient(channel)
        try {
            @Expect(lspPreparedCode(client.close()), "lsp.cleanup_pending")
            @Expect(channel.stops.load(), 1)
            @Expect(client.close().isOk(), true)
            @Expect(channel.stops.load(), 2)
            @Expect(client.close().isOk(), true)
            @Expect(channel.stops.load(), 2)
        } finally { let _ = client.close() }
    }

    @TestCase
    func exactNotificationDispatchIsPureUntilItsOwnHandoff(): Unit {
        let channel = PreparedObservedChannel(preparedLspScript()); let client = LspClient(channel)
        try {
            let notification = LspNotification("$/cancelRequest", jsonObject([JsonObjectEntry("id", jsonString("opaque-original"))]))
            let frozen = lspPreparedRequire(client.prepareNotification("explicit-cancel-key", notification))
            @Expect(channel.writes.load(), 0)
            @Expect(client.dispatchPrepared(frozen).isOk(), true)
            @Expect(channel.writes.load(), 1)
            @Expect(channel.lastWrite(), String.fromUtf8(frozen.framedBytes()))
            @Expect(lspPreparedCode(client.dispatchPrepared(frozen)), "lsp.prepared_reused")
            @Expect(client.prepareRequest("", "echo", jsonObject([])).isOk(), false)
            @Expect(channel.writes.load(), 1)
        } finally { let _ = client.close() }
    }
}

class PreparedObservedChannel <: ProcessDuplexChannel {
    private let delegate: ManagedProcessDuplexChannel
    private let lock = Mutex()
    private var last = ""
    let writes = AtomicInt64(0)
    let stops = AtomicInt64(0)
    let reject = AtomicBool(false)
    let rejectFirstStop: Bool
    init(script: String, rejectFirstStop!: Bool = false) {
        delegate = ManagedProcessDuplexChannel(startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", script])))
        this.rejectFirstStop = rejectFirstStop
    }
    public prop stdout: InputStream { get() { delegate.stdout } }
    public prop stderr: InputStream { get() { delegate.stderr } }
    public func write(bytes: Array<Byte>): Unit {
        writes.fetchAdd(1)
        lock.lock(); try { last = String.fromUtf8(bytes) } finally { lock.unlock() }
        if (reject.load()) { throw ProcessError(ProcessErrorKind.BrokenPipe, "callback-private-secret") }
        delegate.write(bytes)
    }
    func lastWrite(): String { lock.lock(); try { last } finally { lock.unlock() } }
    public func flush(): Unit { delegate.flush() }
    public func abort(): Unit { delegate.abort() }
    public func stop(gracefulShutdownMillis: Int64): Unit {
        let previous = stops.fetchAdd(1)
        if (rejectFirstStop && previous == 0) { throw IllegalStateException("callback-private-secret") }
        delegate.stop(gracefulShutdownMillis)
    }
    public func close(): Unit { delegate.close() }
}
