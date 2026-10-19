package agent_extension_runtime

import agent_domain.*
import agent_sdk.*
import process4cj.*
import process4cj as content_process
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func contentPayloadIdentity(): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(threadId: "content-thread", runId: "", epoch: 0,
        operationId: "", callId: "content-query", kind: "context_provider")
}
func contentPayloadHost(root: String): JavaScriptHostResult<JavaScriptExtensionHost> {
    startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker", extensionId: "content-payload",
        extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable, contentPayload: true,
        contributions: [PluginContributionDefinition("context", PluginContributionKind.ContextProvider),
            PluginContributionDefinition("echo", PluginContributionKind.Tool)]), ServiceQuotaFixtureLauncher())
}
func contentPayloadRoot(mode: String): String {
    let root = Directory.createTemp("/tmp").toString()
    File.writeTo(root + "/worker", contentPayloadWorker().toArray())
    File.writeTo(root + "/mode", mode.toArray())
    let _ = FileInfo(root + "/worker").setExecutable(true)
    root
}
func contentPayloadOpen(root: String): JavaScriptExtensionHost {
    match (contentPayloadHost(root)) { case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
}

@Test
class NativeContentLogicalPayloadTests {
    @TestCase
    func realPureQueryPreservesLargeInputOutputAndOnlyConsumerReleaseReturnsBudget(): Unit {
        let root = contentPayloadRoot("echo"); let host = contentPayloadOpen(root)
        let baseline = nativePayloadOwnerBudget.usage()
        try {
            let content = String.fromUtf8(Array<Byte>(1048576, repeat: b'x'))
            for (_ in 0..3) {
                let result = match (host.invoke("context", stringifyUnifiedJson(objectValue([ValueField("text", textValue(content))])),
                    identity: contentPayloadIdentity(), serviceRequestLimit: 0)) {
                    case JavaScriptHostResult.Ok(value) => value
                    case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
                try {
                    @Expect(parseUnifiedJson(result.resultJson, maxBytes: CONTENT_PAYLOAD_RESULT_BYTES).field("text").getOrThrow().text, content)
                    @Expect(nativePayloadOwnerBudget.usage()[0] > baseline[0])
                } finally { result.releasePayload() }
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), baseline))
            }
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
    }

    @TestCase
    func missingNegotiationKeepsOldBoundsAndContentOfferNeverRaisesToolPrepareBounds(): Unit {
        let root = contentPayloadRoot("legacy"); let host = contentPayloadOpen(root)
        try {
            let large = stringifyUnifiedJson(objectValue([ValueField("text", textValue(String.fromUtf8(Array<Byte>(262144, repeat: b'x'))))]))
            @Expect(quotaCode(host.invoke("context", large, identity: contentPayloadIdentity(), serviceRequestLimit: 0)), "extension.prepare_input_too_large")
            @Expect(!exists(Path(root + "/invoked")))
            let prepare = JavaScriptHostInvocationIdentity(threadId: "content-thread", runId: "real-prepare-run",
                epoch: 1, operationId: "", callId: "tool-prepare", kind: "prepare")
            @Expect(quotaCode(host.invoke("echo", large, identity: prepare, serviceRequestLimit: 0)), "extension.prepare_input_too_large")
            @Expect(!exists(Path(root + "/invoked")))
            let result = host.invoke("context", "{}", identity: contentPayloadIdentity(), serviceRequestLimit: 0)
            @Expect(result.isOk())
            match (result) { case JavaScriptHostResult.Ok(value) => value.releasePayload(); case _ => () }
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
        let invalid = contentPayloadRoot("bad_profile")
        try {
            let response = contentPayloadHost(invalid)
            @Expect(!response.isOk())
            match (response) {
                case JavaScriptHostResult.Err(error) => match (error.cleanupHost) {
                    case Some(value) => let _ = value.awaitCleanup(timeoutMillis: 2000)
                    case None => () }
                case JavaScriptHostResult.Ok(value) => let _ = value.awaitCleanup(timeoutMillis: 2000)
            }
        } finally { remove(invalid, recursive: true) }
    }

    @TestCase
    func pureLargeQueriesStillRejectServicesProgressDenseFramesAndForeignWindows(): Unit {
        for (mode in ["service", "progress", "dense", "wrong_window"]) {
            let root = contentPayloadRoot(mode); let host = contentPayloadOpen(root)
            try {
                let result = host.invoke("context", "{}", identity: contentPayloadIdentity(), serviceRequestLimit: 0)
                @Expect(!result.isOk()); @Expect(host.isClosed)
                if (mode == "service" || mode == "progress") { @Expect(quotaCode(result), "extension.prepare_effect_forbidden") }
            } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
        }
    }

    @TestCase
    func cancelledPartialContentTransferClosesItsOwnerWithoutResultOrLeakedCharge(): Unit {
        let before = nativePayloadOwnerBudget.usage()
        let root = contentPayloadRoot("partial"); let host = contentPayloadOpen(root)
        let cancellation = content_process.CancellationSource()
        let cancel = spawn { sleep(Duration.millisecond * 50); let _ = cancellation.cancel() }
        try {
            let result = host.invoke("context", "{}", identity: contentPayloadIdentity(),
                serviceRequestLimit: 0, cancellation: cancellation.token)
            @Expect(!result.isOk())
            @Expect(cancellation.token.isCancelled())
            let cause = cancellation.token.cause().getOrThrow()
            @Expect(match (cause.kind) { case CancellationKind.Explicit => true; case _ => false })
            @Expect(cause.code, "process.cancelled")
            @Expect(quotaCode(result), cause.code)
            @Expect(host.isClosed)
        } finally { cancel.get(); cancellation.close(); @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); remove(root, recursive: true) }
        @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), before))
    }
}

func contentPayloadWorker(): String {
    "#!/usr/bin/python3\n" +
    "import sys,json,hashlib,pathlib,time\n" +
    "root=pathlib.Path(__file__).parent; mode=(root/'mode').read_text()\n" +
    "identity=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')\n" +
    "def emit(f): print(json.dumps(f,separators=(',',':')),flush=True)\n" +
    "def env(f,t): return dict(type=t,**{k:f[k] for k in identity})\n" +
    "def part(f,t,**x): return dict(env(f,t),payload=dict(schema='axyndra.logical-json/v1',window=f['payload_window'],transfer_sequence=1,**x))\n" +
    "pending=None\n" +
    "for line in sys.stdin:\n" +
    " f=json.loads(line)\n" +
    " if f['type']=='hello':\n" +
    "  r=dict(type='ready',**{k:f[k] for k in ('protocol','extension_id','extension_version','generation','capabilities')},tools=[dict(name='echo',description='',input_schema={})],commands=[],hooks=[],context_providers=[dict(name='context',description='',protocol='axyndra.context-provider/v1')])\n" +
    "  if mode!='legacy': r['content_payload_limits']=dict(f['content_payload_limits'])\n" +
    "  if mode=='bad_profile': r['content_payload_limits']['max_result_bytes']+=1\n" +
    "  emit(r);continue\n" +
    " if f['type']=='payload_begin': pending=(f,bytearray());continue\n" +
    " if f['type']=='payload_chunk':\n" +
    "  before,raw=pending;assert f['payload']['offset']==len(raw);raw.extend(bytes.fromhex(f['payload']['bytes_hex']));continue\n" +
    " if f['type']=='payload_end':\n" +
    "  before,raw=pending;assert len(raw)==before['payload']['bytes'] and hashlib.sha256(raw).hexdigest()==before['payload']['sha256'];f=json.loads(raw);pending=None\n" +
    " if f['type']=='cancel': emit(env(f,'cancelled'));continue\n" +
    " if f['type']!='invoke': break\n" +
    " (root/'invoked').write_text('actual invoke')\n" +
    " if mode=='service': emit(dict(env(f,'service_request'),request_id='forbidden',service='fixture.forbidden',arguments={}));continue\n" +
    " if mode=='progress': emit(dict(env(f,'progress'),progress={}));continue\n" +
    " result=dict(env(f,'result'),ok=True,result=f['arguments'])\n" +
    " if 'payload_window' in f: result['payload_window']=f['payload_window']\n" +
    " if mode=='dense': result['result']={'items':[0]*65537}\n" +
    " if mode=='wrong_window': result['payload_window']='foreign-window'\n" +
    " raw=json.dumps(result,separators=(',',':')).encode()\n" +
    " if mode=='partial': emit(part(f,'payload_begin',message_type='result',bytes=1048576,sha256='0'*64));continue\n" +
    " if len(raw)<262144: emit(result);continue\n" +
    " emit(part(f,'payload_begin',message_type='result',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))\n" +
    " for offset in range(0,len(raw),16384): emit(part(f,'payload_chunk',offset=offset,bytes_hex=raw[offset:offset+16384].hex()))\n" +
    " emit(part(f,'payload_end'))\n"
}
