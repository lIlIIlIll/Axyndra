package agent_extension_runtime

import agent_domain.*
import agent_sdk.*
import process4cj.*
import process4cj as tool_payload_process
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class OrdinaryPayloadObserver <: JavaScriptHostObserver {
    let requests = AtomicInt64(0)
    private let bytes: Int64
    init(bytes!: Int64 = 900000) { this.bytes = bytes }
    public func onProgress(invocation: String, value: String): JavaScriptHostResult<Unit> { JavaScriptHostResult.Ok(()) }
    public func onServiceRequest(invocation: String, request: String, service: String, arguments: String): JavaScriptHostResult<String> {
        requests.fetchAdd(1)
        JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([ValueField("text", textValue(String.fromUtf8(Array<Byte>(bytes, repeat: 120))))])))
    }
}
func ordinaryPayloadHost(root: String): JavaScriptExtensionHost {
    match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker", extensionId: "ordinary-payload",
        extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable, ordinaryToolPayload: true,
        contributions: [PluginContributionDefinition("run", PluginContributionKind.Tool)]), ServiceQuotaFixtureLauncher())) {
        case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
    }
}
func ordinaryPayloadRoot(): String {
    let root = Directory.createTemp("/tmp").toString()
    File.writeTo(root + "/worker", ordinaryPayloadFixtureSource().toArray())
    let _ = FileInfo(root + "/worker").setExecutable(true)
    root
}

private func ordinaryPayloadCancellationCause213(): CancellationCause {
    CancellationCause(CancellationKind.Explicit, "extension.cancelled", "ordinary Tool invocation was cancelled")
}

@Test
class OrdinaryToolNativePayloadTests {
    @TestCase
    func actualLargeInputAndServiceResponsesRetainGlobalBytesAcrossNextSameWorkerCall(): Unit {
        let before = nativePayloadOwnerBudget.usage(); let root = ordinaryPayloadRoot(); let host = ordinaryPayloadHost(root)
        let baseline = nativePayloadOwnerBudget.usage(); let observer = OrdinaryPayloadObserver()
        try {
            let input = stringifyUnifiedJson(objectValue([ValueField("text", textValue(String.fromUtf8(Array<Byte>(1500000, repeat: 120))))]))
            let first = match (host.invoke("run", input, identity: quotaIdentity("tool"), timeoutMillis: 10000,
                toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")), observer: Some(observer))) {
                case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
            try {
                let retained = nativePayloadOwnerBudget.usage()
                @Expect(retained[0], baseline[0] + 2)
                let second = match (host.invoke("run", "{}", identity: quotaIdentity("tool"), timeoutMillis: 10000,
                    toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")), observer: Some(observer))) {
                    case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
                try {
                    @Expect(nativePayloadOwnerBudget.usage()[0], baseline[0] + 4)
                    @Expect(parseUnifiedJson(first.resultJson, maxBytes: 1114112).field("text").getOrThrow().text.size, 900000)
                    @Expect(parseUnifiedJson(second.resultJson, maxBytes: 1114112).field("text").getOrThrow().text.size, 900000)
                    let third = match (host.invoke("run", "{}", identity: quotaIdentity("tool"), timeoutMillis: 10000,
                        toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")), observer: Some(observer))) {
                        case JavaScriptHostResult.Ok(value) => value; case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
                    try {
                        @Expect(nativePayloadOwnerBudget.usage()[0], baseline[0] + 6)
                        @Expect(parseUnifiedJson(third.resultJson, maxBytes: 1114112).field("text").getOrThrow().text.size, 900000)
                        @Expect(observer.requests.load(), 3)
                    } finally { third.releasePayload() }
                } finally { second.releasePayload() }
                @Expect(nativePayloadOwnerBudget.usage()[0], retained[0])
            } finally { first.releasePayload() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), baseline))
        } finally { @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); remove(root, recursive: true) }
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
    }
    @TestCase
    func noPluginFrameOrPrepareKindCanSelectOrExpandTheOrdinaryProfile(): Unit {
        let root = ordinaryPayloadRoot(); let host = ordinaryPayloadHost(root); let observer = OrdinaryPayloadObserver()
        try {
            @Expect(quotaCode(host.invoke("run", "{}", identity: quotaIdentity("prepare"), serviceRequestLimit: 0,
                toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")))), "extension.tool_payload_unsupported")
            @Expect(quotaCode(host.invoke("run", "{}", identity: quotaIdentity("tool"),
                toolPayloadLimits: Some(OrdinaryToolPayloadLimits("other")))), "extension.tool_payload_unsupported")
            @Expect(quotaCode(host.invoke("run", "{}", identity: quotaIdentity("tool"), serviceRequestLimit: 33,
                toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")))), "extension.service_limit_invalid")
            @Expect(!exists(Path(root + "/worker.invocations"))); @Expect(observer.requests.load(), 0)
        } finally { @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); remove(root, recursive: true) }
    }
    @TestCase
    func oversizedActualServiceReplyClosesTransportAndRefundsOnlyAfterFailureCleanup(): Unit {
        let before = nativePayloadOwnerBudget.usage(); let root = ordinaryPayloadRoot(); let host = ordinaryPayloadHost(root)
        let observer = OrdinaryPayloadObserver(bytes: 1114113)
        try {
            let result = host.invoke("run", "{}", identity: quotaIdentity("tool"), timeoutMillis: 5000,
                toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")), observer: Some(observer))
            @Expect(quotaCode(result), "extension.service_result_too_large"); @Expect(observer.requests.load(), 1)
            @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk())
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
    }

    @TestCase
    func legacyAndNonToolWorkersSeeNoOrdinaryPayloadMember(): Unit {
        for (kind in ["tool", "service", "model", "legacy"]) {
            let root = Directory.createTemp("/tmp").toString()
            File.writeTo(root + "/worker.js", ordinaryHandshakeFixtureSource(kind, false).toArray())
            let _ = FileInfo(root + "/worker.js").setExecutable(true)
            let contribution = PluginContributionDefinition(if (kind == "service") { "session" } else { "run" },
                if (kind == "service") { PluginContributionKind.Service } else if (kind == "model") { PluginContributionKind.ModelProvider }
                else { PluginContributionKind.Tool })
            let outcome = startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker.js",
                extensionId: "ordinary-compat", extensionVersion: "1.0.0",
                profile: if (kind == "legacy") { JavaScriptHostLaunchProfile.ProtocolWorker } else { JavaScriptHostLaunchProfile.NativeExecutable },
                enforceNodePermissions: false, contributions: [contribution]), OrdinaryHandshakeLauncher(root))
            try {
                match (outcome) {
                    case JavaScriptHostResult.Ok(host) => @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk())
                    case JavaScriptHostResult.Err(error) =>
                        match (error.cleanupHost) { case Some(host) => let _ = host.awaitCleanup(timeoutMillis: 2000); case None => () }
                        throw IllegalStateException(error.code)
                }
                @Expect(exists(Path(root + "/worker.js.absent")))
            } finally { remove(root, recursive: true) }
        }
    }
    @TestCase
    func unsolicitedReadyMemberAndNonToolLaunchSelectionAreRejected(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        try {
            for (kind in [PluginContributionKind.Service, PluginContributionKind.ModelProvider]) {
                var rejected = false
                try { let _ = JavaScriptHostLaunchRequest(root, "worker", profile: JavaScriptHostLaunchProfile.NativeExecutable,
                    extensionId: "ordinary-compat", extensionVersion: "1.0.0", ordinaryToolPayload: true, contributions: [PluginContributionDefinition("run", kind)]) }
                catch (_: IllegalArgumentException) { rejected = true }
                @Expect(rejected)
            }
            File.writeTo(root + "/worker", ordinaryHandshakeFixtureSource("tool", true).toArray())
            let _ = FileInfo(root + "/worker").setExecutable(true)
            match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker",
                extensionId: "ordinary-compat", extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable,
                contributions: [PluginContributionDefinition("run", PluginContributionKind.Tool)]), ServiceQuotaFixtureLauncher())) {
                case JavaScriptHostResult.Ok(host) => let _ = host.awaitCleanup(timeoutMillis: 2000); @Expect(false)
                case JavaScriptHostResult.Err(error) =>
                    @Expect(error.code, "extension.tool_payload_invalid")
                    match (error.cleanupHost) { case Some(host) => @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); case None => () }
            }
            @Expect(exists(Path(root + "/worker.absent")))
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func actualCancellationDuringLogicalOutputReapsAndReleasesEveryReservation(): Unit {
        let before = nativePayloadOwnerBudget.usage(); let root = ordinaryPayloadRoot(); let host = ordinaryPayloadHost(root)
        let cancel = tool_payload_process.CancellationSource()
        let watcher = spawn {
            let until = MonoTime.now() + Duration.second * 3
            while (!exists(Path(root + "/worker.partial")) && MonoTime.now() < until) { sleep(Duration.millisecond) }
            let _ = cancel.cancel(cause: Some(ordinaryPayloadCancellationCause213()))
        }
        try {
            let result = host.invoke("run", "{\"mode\":\"partial\"}", identity: quotaIdentity("tool"), cancellation: cancel.token,
                timeoutMillis: 5000, toolPayloadLimits: Some(OrdinaryToolPayloadLimits("run")))
            @Expect(quotaCode(result), "extension.cancelled")
            @Expect(exists(Path(root + "/worker.partial")))
            @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk())
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
        } finally { watcher.get(); cancel.close(); let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
    }
}
func ordinaryPayloadFixtureSource(): String {
    "#!/usr/bin/python3\n" +
    "import hashlib,json,sys,pathlib\n" +
    "KEYS=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')\n" +
    "def emit(value): print(json.dumps(value,separators=(',',':')),flush=True)\n" +
    "def env(value,kind): return dict({k:value[k] for k in KEYS},type=kind)\n" +
    "def receive():\n" +
    "    line=sys.stdin.readline()\n" +
    "    if not line: return None\n" +
    "    first=json.loads(line)\n" +
    "    if first['type']!='payload_begin': return first\n" +
    "    header=first['payload'];body=bytearray()\n" +
    "    while True:\n" +
    "        value=json.loads(sys.stdin.readline());assert all(value[k]==first[k] for k in KEYS)\n" +
    "        part=value['payload'];assert part['window']==header['window'] and part['transfer_sequence']==header['transfer_sequence']\n" +
    "        if value['type']=='payload_end': break\n" +
    "        assert part['offset']==len(body);body.extend(bytes.fromhex(part['bytes_hex']))\n" +
    "    assert len(body)==header['bytes'] and hashlib.sha256(body).hexdigest()==header['sha256']\n" +
    "    decoded=json.loads(body);assert all(decoded[k]==first[k] for k in KEYS);return decoded\n" +
    "def logical(frame,window,partial=False):\n" +
    "    body=json.dumps(frame,separators=(',',':')).encode();common=dict(schema='axyndra.logical-json/v1',window=window,transfer_sequence=1)\n" +
    "    emit(dict(env(frame,'payload_begin'),payload=dict(common,message_type='result',bytes=len(body),sha256=hashlib.sha256(body).hexdigest())))\n" +
    "    if partial: return\n" +
    "    for offset in range(0,len(body),16384): emit(dict(env(frame,'payload_chunk'),payload=dict(common,offset=offset,bytes_hex=body[offset:offset+16384].hex())))\n" +
    "    emit(dict(env(frame,'payload_end'),payload=common))\n" +
    "hello=receive();ready=dict(hello,type='ready',tools=[dict(name='run',description='',input_schema=dict(type='object'))],commands=[],hooks=[])\n" +
    "emit(ready)\n" +
    "while True:\n" +
    "    invocation=receive()\n" +
    "    if invocation is None or invocation['type']=='close': break\n" +
    "    assert invocation['type']=='invoke'\n" +
    "    pathlib.Path(__file__+'.invocations').write_text('invoked')\n" +
    "    window=invocation.get('payload_window','')\n" +
    "    if invocation['arguments'].get('mode')=='partial':\n" +
    "        result=dict(env(invocation,'result'),ok=True,result=dict(text='x'*300000),payload_window=window)\n" +
    "        logical(result,window,partial=True);pathlib.Path(__file__+'.partial').write_text('begun')\n" +
    "        cancelled=receive();assert cancelled['type']=='cancel';emit(env(invocation,'cancelled'));break\n" +
    "    question=dict(env(invocation,'service_request'),request_id='child',service='fixture.echo',arguments={});emit(question)\n" +
    "    response=receive();assert response['type']=='service_response' and response['request_id']=='child'\n" +
    "    result=dict(env(invocation,'result'),ok=True,result=response['result'])\n" +
    "    if window:result['payload_window']=window\n" +
    "    if len(json.dumps(result))>262144:logical(result,window)\n" +
    "    else:emit(result)\n"
}

// The legacy profile is exercised through an injected real Python peer, not a
// Node compatibility claim. The host still constructs its legacy hello.
class OrdinaryHandshakeLauncher <: JavaScriptHostProcessLauncher {
    private let root: String
    init(root: String) { this.root = root }
    public func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess> {
        JavaScriptHostResult.Ok(startProcess(ProcessCommand("/usr/bin/python3", arguments: [root + "/worker.js"],
            workingDirectory: root, terminateProcessTree: true)))
    }
}
func ordinaryHandshakeFixtureSource(kind: String, unsolicited: Bool): String {
    "#!/usr/bin/python3\n" +
    "import json,sys,pathlib\n" +
    "h=json.loads(sys.stdin.readline());assert 'ordinary_tool_payload' not in h\n" +
    "pathlib.Path(__file__+'.absent').write_text('absent')\n" +
    "h.update(type='ready',tools=[],commands=[],hooks=[])\n" +
    (if (kind == "service") { "h['services']=[dict(name='session',description='')]\n" }
    else if (kind == "model") { "h['model_providers']=[dict(name='run',description='',protocol='axyndra.model-provider/v1')]\n" }
    else { "h['tools']=[dict(name='run',description='',input_schema=dict(type='object'))]\n" }) +
    (if (unsolicited) { "h['ordinary_tool_payload']=None\n" } else { "" }) +
    "print(json.dumps(h),flush=True)\n" +
    "for line in sys.stdin:\n" +
    " if json.loads(line)['type']=='close':break\n"
}
