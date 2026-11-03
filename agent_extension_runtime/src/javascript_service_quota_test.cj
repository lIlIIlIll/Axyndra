package agent_extension_runtime

import agent_sdk.*
import process4cj.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

class ServiceQuotaFixtureLauncher <: JavaScriptHostProcessLauncher {
    public func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess> {
        JavaScriptHostResult.Ok(startProcess(command))
    }
}
class ServiceQuotaObserver <: JavaScriptHostObserver {
    let requests = AtomicInt64(0)
    public func onProgress(invocation: String, value: String): JavaScriptHostResult<Unit> { JavaScriptHostResult.Ok(()) }
    public func onServiceRequest(invocation: String, request: String, service: String, arguments: String): JavaScriptHostResult<String> {
        let _ = requests.fetchAdd(1)
        JavaScriptHostResult.Ok("{}")
    }
}
func serviceQuotaFixtureSource(): String {
    "#!/usr/bin/python3\n" +
    "import sys,json\n" +
    "def emit(f): print(json.dumps(f,separators=(',',':')),flush=True)\n" +
    "for line in sys.stdin:\n" +
    " f=json.loads(line)\n" +
    " if f['type']=='hello':\n" +
    "  f.update(type='ready',tools=[dict(name='echo',description='',input_schema=dict(type='object'))],commands=[],hooks=[],services=[dict(name='session',description='')]); emit(f)\n" +
    " elif f['type']=='invoke':\n" +
    "  for n in range(f['arguments'].get('requests',1)):\n" +
    "   q=dict(f); q.update(type='service_request',request_id='poll-'+str(n),service='fixture.poll',arguments={}); emit(q)\n" +
    "   r=json.loads(sys.stdin.readline())\n" +
    "   assert r['type']=='service_response' and r['id']==f['id'] and r['request_id']==q['request_id']\n" +
    "  f.update(type='result',ok=True,result=dict(done=True)); emit(f)\n" +
    " elif f['type']=='close': break\n"
}
func serviceQuotaHost(root: String): JavaScriptExtensionHost {
    match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker",
        extensionId: "service-quota", extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable,
        contributions: [PluginContributionDefinition("echo", PluginContributionKind.Tool),
            PluginContributionDefinition("session", PluginContributionKind.Service)]), ServiceQuotaFixtureLauncher())) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
    }
}
func quotaIdentity(kind: String): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(threadId: "quota-thread", runId: "quota-run", epoch: 1,
        operationId: if (kind == "prepare" || kind == "service_prepare") { "" } else { "quota-operation" }, callId: "quota-call", kind: kind)
}
func quotaCode(value: JavaScriptHostResult<JavaScriptHostInvocationResult>): String {
    match (value) { case JavaScriptHostResult.Ok(_) => "ok"; case JavaScriptHostResult.Err(error) => error.code }
}

@Test
class NativeServiceRequestQuotaTests {
    @TestCase
    func onlyNativeServiceCanExceedThirtyTwoAndPreparationStillHasNoCallbacks(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        File.writeTo(root + "/worker", serviceQuotaFixtureSource().toArray())
        let _ = FileInfo(root + "/worker").setExecutable(true)
        let service = serviceQuotaHost(root)
        let tool = serviceQuotaHost(root)
        let prepare = serviceQuotaHost(root)
        try {
            let serviceObserver = ServiceQuotaObserver()
            @Expect(quotaCode(service.invoke("session", "{}", identity: quotaIdentity("service"),
                serviceRequestLimit: 8193, observer: Some(serviceObserver))), "extension.service_limit_invalid")
            @Expect(quotaCode(service.invoke("session", "{\"requests\":33}", identity: quotaIdentity("service"),
                serviceRequestLimit: 40, observer: Some(serviceObserver))), "ok")
            @Expect(serviceObserver.requests.load(), 33)
            let toolObserver = ServiceQuotaObserver()
            @Expect(quotaCode(tool.invoke("echo", "{}", identity: quotaIdentity("tool"),
                serviceRequestLimit: 40, observer: Some(toolObserver))), "extension.service_limit_invalid")
            @Expect(toolObserver.requests.load(), 0)
            @Expect(quotaCode(tool.invoke("echo", "{\"requests\":33}", identity: quotaIdentity("tool"),
                observer: Some(toolObserver))), "extension.protocol_service_limit")
            @Expect(toolObserver.requests.load(), 32)
            let prepareObserver = ServiceQuotaObserver()
            @Expect(quotaCode(prepare.invoke("session", "{}", identity: quotaIdentity("service_prepare"),
                serviceRequestLimit: 40, observer: Some(prepareObserver))), "extension.service_limit_invalid")
            @Expect(quotaCode(prepare.invoke("session", "{}", identity: quotaIdentity("service_prepare"),
                serviceRequestLimit: 0, observer: Some(prepareObserver))), "extension.prepare_effect_forbidden")
            @Expect(prepareObserver.requests.load(), 0)
        } finally {
            for (host in [service, tool, prepare]) { let _ = host.awaitCleanup(timeoutMillis: 2000) }
            remove(root, recursive: true)
        }
    }
}
