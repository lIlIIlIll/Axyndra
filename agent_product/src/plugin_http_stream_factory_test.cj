package agent_product

import agent_domain.*
import agent_ports.*
import process4cj as http_stream_process
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual curl, bwrap, gateway and HTTP bytes. These tests do not claim a
// canonical Operation, plugin IPC or MCP integration; that is the next layer.
class HttpStreamFactoryFixture {
    let root: String
    let packageRoot: String
    let port: LocalProcessPort
    let origin: http_stream_process.ManagedProcess
    let cancellation = CancellationSource()
    let policy: NetworkPolicy
    let url: String
    let operation = OperationId("http-stream-factory")
    init(label: String) {
        root = pluginContractTemp("http-stream-factory-" + label)
        packageRoot = root + "/package"
        Directory.create(packageRoot, recursive: true)
        let binary = Path(getVariable("AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE").getOrThrow())
        let script = binary.parent.parent.parent.join("http_stream_origin.py").toString()
        origin = http_stream_process.startProcess(http_stream_process.ProcessCommand("/usr/bin/python3",
            arguments: [script, root], terminateProcessTree: true, maxOutputBytes: 65536))
        try {
            rawChannelAwaitFile(root + "/ready.json")
            let ready = parseUnifiedJson(String.fromUtf8(File.readFrom(root + "/ready.json")))
            let number = UInt16.parse(ready.field("port").getOrThrow().asNumberText())
            url = "http://127.0.0.1:" + number.toString()
            policy = NetworkPolicy(NetworkPolicyMode.Mediated,
                egress: [NetworkEgressRule("127.0.0.1", number, privateAddresses: ["127.0.0.1"])])
            let ca = resolveProductSandboxCaBundle("").value().getOrThrow()
            port = LocalProcessPort(LocalWorkspace(packageRoot), sandboxEnabled: true,
                sandboxCaBundle: ca, networkGateway: Some(LocalNetworkGatewayPort()))
        } catch (error: Exception) {
            let _ = origin.close(); cancellation.close(); remove(root, recursive: true); throw error
        }
    }
    func request(path: String, body!: String = "00ff0d0a40", timeout!: Int64 = 10000): AgentValue {
        objectValue([ValueField("method", textValue("POST")), ValueField("url", textValue(url + "/" + path)),
            ValueField("headers", objectValue([ValueField("Content-Type", textValue("application/octet-stream")),
                ValueField("X-Empty", textValue(""))])),
            ValueField("body_hex", textValue(body)), ValueField("credential_refs", listValue([textValue("header")])),
            ValueField("timeout_ms", integerValue(timeout)), ValueField("max_response_bytes", integerValue(65536))])
    }
    func open(path: String): ProductHttpExchangeReader {
        match (port.openHttpExchange(operation, request(path), packageRoot, policy, cancellation.token,
            [ProductPluginHttpCredentialValue("header", "stream-secret-481d", "authorization", "")],
            ExecutionResourceLimits(maxOutputBytes: 131072))) {
            case Result.Err(error) => throw IllegalStateException(error.describe())
            case Result.Ok(value) => value
        }
    }
    func close(): Unit {
        let _ = cancellation.cancel()
        let deadline = agentUtcMillis() + 5000
        var released = false
        while (!released && agentUtcMillis() < deadline) {
            released = port.close().isOk()
            if (!released) { sleep(Duration.millisecond * 5) }
        }
        try { let _ = origin.close() } finally { cancellation.close() }
        if (!released) { throw IllegalStateException("HTTP factory resources did not acknowledge cleanup") }
        remove(root, recursive: true)
    }
}

func httpStreamFactoryHead(reader: ProductHttpExchangeReader): ProductHttpExchangeHead {
    let deadline = agentUtcMillis() + 5000
    while (agentUtcMillis() < deadline) {
        match (reader.pollHead()) {
            case Result.Err(error) => throw IllegalStateException(error.describe())
            case Result.Ok(Some(value)) => return value
            case Result.Ok(None) => ()
        }
    }
    throw IllegalStateException("HTTP response metadata did not arrive")
}

func httpStreamFactoryClose(reader: ProductHttpExchangeReader, fixture: HttpStreamFactoryFixture): Unit {
    let deadline = agentUtcMillis() + 5000
    while (agentUtcMillis() < deadline) {
        if (reader.close().isOk()) {
            if (!reader.closeAcknowledged() || fixture.port.hasActiveOperation(fixture.operation)) {
                throw IllegalStateException("HTTP cleanup ACK preceded actual resource release")
            }
            return
        }
        sleep(Duration.millisecond * 5)
    }
    throw IllegalStateException("HTTP reader cleanup did not acknowledge")
}

@Test
class ProductHttpStreamFactoryTests {
    @TestCase
    func actualIngressMeterIncludesUnreadQueuesAndRemainsStableAfterCloseAck() {
        let fixture = RawChannelFixture("ingress-meter",
            "sys.stdout.buffer.write(b'x' * 65536); sys.stdout.buffer.flush()\n" +
            "sys.stderr.buffer.write(b'y' * 8192); sys.stderr.buffer.flush()\n" +
            "sys.stdin.buffer.read()", maxOutputBytes: 131072)
        try {
            let deadline = agentUtcMillis() + 5000
            var count: Int64 = 0
            while (count < 73728 && agentUtcMillis() < deadline) {
                count = fixture.channel.receivedOutputBytes().value().getOrThrow()
                sleep(Duration.millisecond * 2)
            }
            // No read API has consumed any output. Both host queues count.
            @Expect(count, 73728)
            var closed = fixture.channel.close()
            while (closed.isError() && agentUtcMillis() < deadline) {
                sleep(Duration.millisecond * 2); closed = fixture.channel.close()
            }
            @Expect(closed.isOk())
            @Expect(fixture.releases.load(), 1)
            @Expect(fixture.channel.receivedOutputBytes().value().getOrThrow(), count)
        } finally { fixture.close() }
    }

    @TestCase
    func inputHalfClosePreservesOutputAndNeverAcceptsAnotherWrite() {
        let fixture = RawChannelFixture("half-close", "data = sys.stdin.buffer.read(); os.write(1, data)")
        try {
            let bytes: Array<Byte> = [0, 255, 13, 10, 64]
            @Expect(fixture.channel.write(bytes).isOk())
            @Expect(fixture.channel.closeInput().isOk())
            @Expect(fixture.channel.closeInput().isOk())
            @Expect(fixture.channel.write([1]).isError())
            @Expect(rawChannelSameBytes(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout), bytes))
            @Expect(fixture.releases.load(), 0)
            @Expect(fixture.channel.close().isOk())
            @Expect(fixture.releases.load(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func realSandboxCurlPreservesBinaryBodyQueryAndPrivateHeaders() {
        let fixture = HttpStreamFactoryFixture("binary")
        try {
            let reader = fixture.open("bytes?a=1&a=%2f&b=@exact")
            let head = httpStreamFactoryHead(reader)
            @Expect(head.status, 200)
            @Expect(head.contentType, "application/octet-stream")
            @Expect(head.bodySize.getOrThrow(), 4)
            let bytes = ArrayList<Byte>()
            var eof = false
            let deadline = agentUtcMillis() + 5000
            while (!eof && agentUtcMillis() < deadline) {
                let value = reader.readBody(2).value().getOrThrow()
                bytes.add(all: value.bytes); eof = value.eof
            }
            @Expect(eof)
            @Expect(rawChannelSameBytes(bytes.toArray(), [0, 1, 254, 255]))
            let observed = parseUnifiedJson(String.fromUtf8(File.readFrom(fixture.root + "/observed.json")))
            @Expect(httpIntentText(observed, "path"), "/bytes?a=1&a=%2f&b=@exact")
            @Expect(httpIntentText(observed, "body_hex"), "00ff0d0a40")
            @Expect(observed.field("header_ok").getOrThrow().asBool())
            @Expect(observed.field("empty_header_present").getOrThrow().asBool())
            @Expect(fixture.port.hasActiveOperation(fixture.operation))
            httpStreamFactoryClose(reader, fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func realOpenSseMakesProgressBeforeEofAndEarlyCloseInterruptsPeer() {
        let fixture = HttpStreamFactoryFixture("sse")
        try {
            let reader = fixture.open("sse")
            @Expect(httpStreamFactoryHead(reader).contentType, "text/event-stream")
            let bytes = ArrayList<Byte>()
            let expected = "data: {\"ok\":true}\n\n"
            let deadline = agentUtcMillis() + 3000
            while (bytes.size < expected.size && agentUtcMillis() < deadline) {
                let value = reader.readBody(16384).value().getOrThrow()
                @Expect(!value.eof)
                bytes.add(all: value.bytes)
            }
            @Expect(String.fromUtf8(bytes.toArray()), expected)
            @Expect(!exists(Path(fixture.root + "/closed")))
            httpStreamFactoryClose(reader, fixture)
            rawChannelAwaitFile(fixture.root + "/closed")
            @Expect(!exists(Path(fixture.root + "/timed-out")))
        } finally { fixture.close() }
    }

    @TestCase
    func realSecretEchoAndTruncatedChunkedBodyNeverBecomeCompleteEof() {
        for (mode in ["raw", "escaped", "truncated"]) {
            let fixture = HttpStreamFactoryFixture("reject-" + mode)
            try {
                let reader = fixture.open(mode)
                var rejected = false; var completed = false
                let bytes = ArrayList<Byte>()
                let deadline = agentUtcMillis() + 5000
                while (!rejected && !completed && agentUtcMillis() < deadline) {
                    match (reader.pollHead()) {
                        case Result.Err(error) => @Expect(error.kind == AgentErrorKind.RecoveryRequired); rejected = true
                        case Result.Ok(None) => ()
                        case Result.Ok(Some(_)) => match (reader.readBody(16384)) {
                            case Result.Err(error) => @Expect(error.kind == AgentErrorKind.RecoveryRequired); rejected = true
                            case Result.Ok(value) => bytes.add(all: value.bytes); completed = value.eof
                        }
                    }
                }
                @Expect(rejected && !completed)
                let exposed = String.fromUtf8(bytes.toArray())
                @Expect(!exposed.contains("stream-secret-481d"))
                @Expect(!exposed.contains("\\u0073"))
                httpStreamFactoryClose(reader, fixture)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func actualCancellationInterruptsHeaderWaitAndReturnsRealCleanupAck() {
        let fixture = HttpStreamFactoryFixture("cancel")
        try {
            let reader = fixture.open("hold")
            rawChannelAwaitFile(fixture.root + "/observed.json")
            @Expect(reader.pollHead().value().getOrThrow().isNone())
            let _ = fixture.cancellation.cancel()
            @Expect(match (reader.pollHead()) { case Result.Err(error) => error.kind == AgentErrorKind.Cancelled; case _ => false })
            httpStreamFactoryClose(reader, fixture)
            rawChannelAwaitFile(fixture.root + "/closed")
        } finally { fixture.close() }
    }
}
