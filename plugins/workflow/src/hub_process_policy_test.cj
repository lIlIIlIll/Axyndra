package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func hubProcessPolicyInput(op: String, fields: Array<ValueField>): AgentValue {
    let input=objectValue(fields);input.put("op",textValue(op));input
}
func expectHubProcessPolicyFailure(code: String, run: ()->Unit): Unit {
    try{run();@Expect(false)}catch(error:PureProviderError){@Expect(error.code,code)}
}
@Test
class WorkflowHubProcessOriginalPolicyTests {
    @TestCase
    func detachedStartPreservesOriginalBrokerPtyDefaultsAndWholeArgsEnvironment(): Unit {
        let input=hubProcessPolicyInput("start",[
            ValueField("name",textValue("Original.9_-")),ValueField("application",textValue("  original-executable  ")),
            ValueField("args",listValue([textValue(" space "),textValue("雪\"\n\u{0000}")])),
            ValueField("detached",boolValue(true)),ValueField("pty",boolValue(true)),
            ValueField("env",objectValue([ValueField("ORIGINAL",textValue("  literal 雪  "))])),
            ValueField("env_from",objectValue([ValueField("BORROWED",textValue("HOST_SOURCE"))])),
            ValueField("secret_env",objectValue([ValueField("API_TOKEN",textValue("HOST_SECRET_TOKEN"))]))])
        let request=workflowHubProcessRequest(input,"restricted")
        let spec=request.field("spec").getOrThrow()
        @Expect(workflowText(request,"op"),"start");@Expect(workflowText(spec,"name"),"Original.9_-")
        @Expect(workflowText(spec,"application"),"original-executable")
        @Expect(spec.field("persist").getOrThrow().asBool());@Expect(spec.field("detached").getOrThrow().asBool())
        @Expect(!spec.field("pty").getOrThrow().asBool());@Expect(workflowText(spec,"restart"),"no")
        @Expect(workflowText(spec,"cwd"),"");@Expect(spec.field("ready").getOrThrow().unifiedKind,ValueKind.Null)
        @Expect(canonicalAgentValue(spec.field("args").getOrThrow()),canonicalAgentValue(input.field("args").getOrThrow()))
        for(name in ["env","env_from","secret_env"]){
            @Expect(canonicalAgentValue(spec.field(name).getOrThrow()),canonicalAgentValue(input.field(name).getOrThrow()))}
        @Expect(workflowText(spec.field("network").getOrThrow(),"mode"),"denied")
    }
    @TestCase
    func readyTimeoutNetworkAndBindingErrorsKeepOriginalLimitsAndMessages(): Unit {
        let input=hubProcessPolicyInput("start",[ValueField("name",textValue("ready")),
            ValueField("application",textValue("original")),ValueField("network",objectValue([ValueField("mode",textValue("host"))])),
            ValueField("ready",objectValue([ValueField("port",integerValue(65535)),ValueField("timeout",integerValue(Int64.Max))]))])
        let ready=workflowHubProcessRequest(input,"trusted_host").field("spec").getOrThrow().field("ready").getOrThrow()
        @Expect(ready.field("port").getOrThrow().asInt64(),65535)
        @Expect(ready.field("timeoutMs").getOrThrow().asInt64(),3600000)
        @Expect(workflowText(ready,"host"),"127.0.0.1")
        expectHubProcessPolicyFailure("network.mode_denied",{=>let _=workflowHubProcessRequest(input,"proxy")})
        input.put("network",objectValue([ValueField("mode",textValue("denied"))]))
        expectHubProcessPolicyFailure("hub.process_ready_network_required",{=>let _=workflowHubProcessRequest(input,"restricted")})
        input.put("ready",objectValue([ValueField("log",textValue("ready"))]))
        input.put("env",objectValue([ValueField("API_TOKEN",textValue("must not become a literal secret"))]))
        expectHubProcessPolicyFailure("hub.process_env_invalid",{=>let _=workflowHubProcessRequest(input,"restricted")})
        input.put("env",objectValue([ValueField("ORIGINAL",textValue("literal"))]))
        input.put("env_from",objectValue([ValueField("ORIGINAL",textValue("OTHER"))]))
        expectHubProcessPolicyFailure("hub.process_env_binding_invalid",{=>let _=workflowHubProcessRequest(input,"restricted")})
    }
    @TestCase
    func logsStopWaitAndRestartPreserveOriginalSecondsFallbackAndByteCursor(): Unit {
        let logs=workflowHubProcessRequest(hubProcessPolicyInput("logs",[ValueField("name",textValue("log")),
            ValueField("lines",integerValue(Int64.Max)),ValueField("cursor",integerValue(Int64.Min)),
            ValueField("timeout",integerValue(0)),ValueField("head",boolValue(true)),ValueField("follow",boolValue(true))]),"restricted")
        @Expect(logs.field("lines").getOrThrow().asInt64(),1000)
        @Expect(logs.field("cursor").getOrThrow().asInt64(),Int64.Min)
        @Expect(logs.field("cursor_present").getOrThrow().asBool());@Expect(logs.field("head").getOrThrow().asBool())
        @Expect(logs.field("follow").getOrThrow().asBool());@Expect(logs.field("timeout_ms").getOrThrow().asInt64(),30000)
        let stop=workflowHubProcessRequest(hubProcessPolicyInput("stop",[ValueField("name",textValue("log")),ValueField("timeout",integerValue(-1))]),"restricted")
        @Expect(stop.field("timeout_ms").getOrThrow().asInt64(),5000)
        let wait=workflowHubProcessRequest(hubProcessPolicyInput("wait",[ValueField("name",textValue("log")),ValueField("for",textValue("  ready  ")),ValueField("timeout",integerValue(Int64.Max))]),"restricted")
        @Expect(wait.field("timeout_ms").getOrThrow().asInt64(),3600000);@Expect(workflowText(wait,"condition"),"ready")
        expectHubProcessPolicyFailure("network.restart_policy_required",{=>let _=workflowHubProcessRequest(
            hubProcessPolicyInput("restart",[ValueField("name",textValue("log"))]),"restricted")})
    }
    @TestCase
    func sendUsesEveryOriginalLaunchKeyAndExactTrimEnterSemantics(): Unit {
        let keys=["ENTER","TAB","ESCAPE","CTRL_C","CTRL_D","UP","DOWN","RIGHT","LEFT"]
        let send=workflowHubProcessRequest(hubProcessPolicyInput("send",[ValueField("name",textValue("terminal")),
            ValueField("text",textValue("  command 雪  ")),ValueField("keys",workflowHubProcessStrings(keys)),
            ValueField("signal",textValue(" SIGINT "))]),"restricted")
        @Expect(workflowText(send,"signal"),"SIGINT")
        @Expect(send.field("stdin").getOrThrow().text,"command 雪\r\r\t\u{1b}\u{3}\u{4}\u{1b}[A\u{1b}[B\u{1b}[C\u{1b}[D")
        expectHubProcessPolicyFailure("hub.process_key_invalid",{=>let _=workflowHubProcessRequest(
            hubProcessPolicyInput("send",[ValueField("name",textValue("terminal")),ValueField("keys",listValue([textValue("HOME")]))]),"restricted")})
        expectHubProcessPolicyFailure("hub.process_send_empty",{=>let _=workflowHubProcessRequest(
            hubProcessPolicyInput("send",[ValueField("name",textValue("terminal")),ValueField("text",textValue("   "))]),"restricted")})
    }
    @TestCase
    func logOutputKeepsWholeOriginalGrepHeadTailResetAndUnicodeData(): Unit {
        let request=workflowHubProcessRequest(hubProcessPolicyInput("logs",[ValueField("name",textValue("original")),
            ValueField("lines",integerValue(2)),ValueField("grep",textValue("keep"))]),"restricted")
        let observation=objectValue([ValueField("schema",textValue("axyndra.hub-process-observation/v1")),ValueField("op",textValue("logs")),
            ValueField("facts",objectValue([ValueField("name",textValue("original")),ValueField("window_text",textValue("keep first\nskip\nkeep 雪\"\nkeep last\n")),
                ValueField("cursor",integerValue(Int64.Max)),ValueField("timed_out",boolValue(false)),ValueField("state",textValue("recovery_required")),ValueField("reset",boolValue(true))]))])
        let tail=workflowHubProcessOutput(request,observation)
        @Expect(workflowText(tail,"text"),"keep 雪\"\nkeep last")
        @Expect(tail.field("cursor").getOrThrow().asInt64(),Int64.Max)
        @Expect(tail.field("reset").getOrThrow().asBool());@Expect(!tail.field("timedOut").getOrThrow().asBool())
        @Expect(workflowText(tail,"state"),"recovery_required")
        request.put("head",boolValue(true))
        @Expect(workflowText(workflowHubProcessOutput(request,observation),"text"),"keep first\nkeep 雪\"")
        observation.put("op",textValue("wait"))
        expectHubProcessPolicyFailure("workflow.process_observation_invalid",{=>let _=workflowHubProcessOutput(request,observation)})
    }
}
