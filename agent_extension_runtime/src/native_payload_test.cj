package agent_extension_runtime

import agent_domain.*
import agent_sdk.*
import process4cj.*
import process4cj as payload_process
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func nativePayloadUsageEqual(actual: (Int64, Int64), expected: (Int64, Int64)): Bool {
    actual[0] == expected[0] && actual[1] == expected[1]
}

func nativePayloadTestLimits(): ServicePayloadLimits {
    parseServicePayloadLimits(parseUnifiedJson("{\"version\":1,\"max_message_bytes\":16777216,\"max_input_bytes\":4194304,\"max_prepare_bytes\":8388608,\"max_result_bytes\":8388608,\"max_write_bytes\":4128768}")).value().getOrThrow()
}
func nativePayloadTestHost(root: String): JavaScriptExtensionHost {
    let limits = parseServiceProtocolLimits(parseUnifiedJson("{\"max_frame_bytes\":4194304,\"max_input_bytes\":1048576,\"max_prepare_bytes\":2097152,\"max_result_bytes\":4128768,\"max_directory_bytes\":2097152,\"max_tools\":8192,\"call_timeout_ms\":120000}")).value().getOrThrow()
    match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker", extensionId: "payload-fixture",
        extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable,
        maxFrameBytes: limits.maxFrameBytes, serviceLimits: Some(limits), payloadLimits: Some(nativePayloadTestLimits()),
        contributions: [PluginContributionDefinition("session", PluginContributionKind.Service)]), ServiceQuotaFixtureLauncher())) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
    }
}
func nativePayloadTestRoot(): String {
    let root = Directory.createTemp("/tmp").toString()
    File.writeTo(root + "/worker", nativePayloadFixtureSource().toArray())
    let _ = FileInfo(root + "/worker").setExecutable(true)
    root
}

@Test
class NativeLogicalPayloadTests {
    @TestCase
    func denseProfileInputIsRejectedBeforeTheEndpointReceivesAnyInvocation(): Unit {
        let before = nativePayloadOwnerBudget.usage(); let root = nativePayloadTestRoot(); let host = nativePayloadTestHost(root)
        try {
            let entries = Array<Byte>(200000, { index => if (index % 2 == 0) { b'0' } else { b',' } })
            let input = "{\"items\":[" + String.fromUtf8(entries) + "0]}"
            @Expect(!host.invoke("session", input, identity: quotaIdentity("service")).isOk())
            @Expect(!exists(Path(root + "/worker.invocations")))
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
    }

    @TestCase
    func actualBidirectionalLogicalFramesKeepTheirPoolChargeUntilConsumerRelease(): Unit {
        let before = nativePayloadOwnerBudget.usage()
        let root = nativePayloadTestRoot(); let host = nativePayloadTestHost(root)
        let baseline = nativePayloadOwnerBudget.usage()
        try {
            let content = String.fromUtf8(Array<Byte>(4194304, repeat: b'x'))
            let arguments = stringifyUnifiedJson(objectValue([ValueField("text", textValue(content))]))
            let result = host.invoke("session", arguments, identity: quotaIdentity("service"), timeoutMillis: 5000)
            let received = match (result) { case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
            try {
                let value = parseUnifiedJson(received.resultJson)
                @Expect(textField(value, "sha256"), modelPolicySha256Text(content))
                @Expect(nativePayloadOwnerBudget.usage()[0] > baseline[0])
            } finally { received.releasePayload() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), baseline))
            let large = match (host.invoke("session", "{\"mode\":\"large\"}", identity: quotaIdentity("service"), timeoutMillis: 5000)) {
                case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
            }
            try { @Expect(parseUnifiedJson(large.resultJson, maxBytes: 8388608).field("text").getOrThrow().text.size, 6291456) }
            finally { large.releasePayload() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), baseline))
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
    }

    @TestCase
    func malformedDeclarationsIdentityOffsetsAndDensePhysicalJsonReleaseAllCharges(): Unit {
        for (mode in ["oversized", "identity", "offset", "overlap", "dense"]) {
            let before = nativePayloadOwnerBudget.usage(); let root = nativePayloadTestRoot(); let host = nativePayloadTestHost(root)
            try {
                let result = host.invoke("session", "{\"mode\":\"" + mode + "\"}", identity: quotaIdentity("service"), timeoutMillis: 2000)
                @Expect(!result.isOk()); @Expect(host.isClosed)
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
            } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
        }
    }

    @TestCase
    func cancellationDuringAssemblyUsesOriginalIdentityAndReleasesOwnerBudget(): Unit {
        let before = nativePayloadOwnerBudget.usage(); let root = nativePayloadTestRoot(); let host = nativePayloadTestHost(root)
        let cancel = payload_process.CancellationSource()
        let worker = spawn { sleep(Duration.millisecond * 50); let _ = cancel.cancel() }
        try {
            let result = host.invoke("session", "{\"mode\":\"partial\"}", identity: quotaIdentity("service"), cancellation: cancel.token, timeoutMillis: 2000)
            @Expect(!result.isOk()); @Expect(host.isClosed); @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
        } finally { worker.get(); cancel.close(); let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
    }

    @TestCase
    func physicalAndLogicalProfileInputWritesRemainCancellableWhenPeerStopsReading(): Unit {
        for (size in [1048576, 4194304]) {
            let before = nativePayloadOwnerBudget.usage(); let root = nativePayloadTestRoot()
            File.writeTo(root + "/worker.noread", "stop after ready".toArray())
            let host = nativePayloadTestHost(root)
            try {
                let input = stringifyUnifiedJson(objectValue([ValueField("text", textValue(String.fromUtf8(Array<Byte>(size, repeat: b'x'))))]))
                let begun = MonoTime.now()
                let result = host.invoke("session", input, identity: quotaIdentity("service"), timeoutMillis: 250)
                @Expect(!result.isOk()); @Expect(host.isClosed)
                @Expect((MonoTime.now() - begun).toMilliseconds() < 2500)
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
            } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
        }
    }

    @TestCase
    func retainedResultExhaustsAggregateBeforeAnotherOwnerCanParseOrWrite(): Unit {
        let before = nativePayloadOwnerBudget.usage(); let root = nativePayloadTestRoot()
        let first = nativePayloadTestHost(root); let second = nativePayloadTestHost(root)
        try {
            let retained = match (first.invoke("session", "{}", identity: quotaIdentity("service"))) {
                case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
            }
            try {
                @Expect(!second.invoke("session", "{}", identity: quotaIdentity("service")).isOk())
                let _ = second.awaitCleanup(timeoutMillis: 2000)
                @Expect(nativePayloadOwnerBudget.usage()[0], before[0] + 3)
            } finally { retained.releasePayload() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), (before[0] + 1, before[1] + 8192)))
        } finally { for (host in [first, second]) { let _ = host.awaitCleanup(timeoutMillis: 2000) }; remove(root, recursive: true) }
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
    }
}

func nativePayloadFixtureSource(): String {
    "#!/usr/bin/python3\n" +
    "import hashlib,json,sys,time,os\n" +
    "\n" +
    "IDENTITY=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')\n" +
    "def emit(value):\n" +
    "    print(json.dumps(value,separators=(',',':')),flush=True)\n" +
    "def payload(frame,kind,**values):\n" +
    "    return dict({key:frame[key] for key in IDENTITY},type=kind,payload=dict(schema='axyndra.logical-json/v1',\n" +
    "        window=frame['payload_window'],transfer_sequence=1,**values))\n" +
    "def read():\n" +
    "    raw=sys.stdin.buffer.readline(4194306)\n" +
    "    if not raw: return None\n" +
    "    if not raw.endswith(b'\\n') or len(raw)>4194305: raise ValueError('bounded frame required')\n" +
    "    return json.loads(raw)\n" +
    "pending=None\n" +
    "while True:\n" +
    "    f=read()\n" +
    "    if f is None: break\n" +
    "    if f['type']=='hello':\n" +
    "        emit(dict({key:f[key] for key in ('protocol','extension_id','extension_version','generation','capabilities')},\n" +
    "            type='ready',tools=[],commands=[],hooks=[],services=[dict(name='session',description='logical payload probe')]))\n" +
    "        if os.path.exists(sys.argv[0]+'.noread'):\n" +
    "            while True: time.sleep(1)\n" +
    "        continue\n" +
    "    if f['type']=='payload_begin':\n" +
    "        assert pending is None\n" +
    "        pending=(f,bytearray()); continue\n" +
    "    if f['type']=='payload_chunk':\n" +
    "        before,body=pending\n" +
    "        assert f['payload']['offset']==len(body)\n" +
    "        body.extend(bytes.fromhex(f['payload']['bytes_hex']));continue\n" +
    "    if f['type']=='payload_end':\n" +
    "        before,body=pending;pending=None\n" +
    "        assert len(body)==before['payload']['bytes'] and hashlib.sha256(body).hexdigest()==before['payload']['sha256']\n" +
    "        f=json.loads(body)\n" +
    "    if f['type']=='cancel':\n" +
    "        emit(dict({key:f[key] for key in IDENTITY},type='cancelled'));continue\n" +
    "    if f['type']!='invoke':break\n" +
    "    with open(sys.argv[0]+'.invocations','a') as seen: seen.write('invoke\\n')\n" +
    "    args=f['arguments'];mode=args.get('mode','echo')\n" +
    "    result=dict({key:f[key] for key in IDENTITY},type='result',payload_window=f['payload_window'],ok=True,\n" +
    "                result={'bytes':len(args.get('text','').encode()),'sha256':hashlib.sha256(args.get('text','').encode()).hexdigest()})\n" +
    "    if mode=='dense':\n" +
    "        result['result']={'items':[0]*100000};emit(result);continue\n" +
    "    if mode=='large':result['result']={'text':'x'*6291456}\n" +
    "    source=json.dumps(result,separators=(',',':')).encode()\n" +
    "    begin=payload(f,'payload_begin',message_type='result',bytes=len(source),sha256=hashlib.sha256(source).hexdigest())\n" +
    "    if mode=='oversized':begin['payload']['bytes']=16777217\n" +
    "    if mode=='identity':begin['run_id']='foreign'\n" +
    "    emit(begin)\n" +
    "    if mode in ('oversized','identity'):continue\n" +
    "    if mode=='overlap':emit(begin);continue\n" +
    "    for offset in range(0,len(source),16384):\n" +
    "        emit(payload(f,'payload_chunk',offset=offset+(1 if mode=='offset' else 0),bytes_hex=source[offset:offset+16384].hex()))\n" +
    "        if mode in ('partial','offset'):break\n" +
    "    if mode=='partial':continue\n" +
    "    emit(payload(f,'payload_end'))\n"
}
