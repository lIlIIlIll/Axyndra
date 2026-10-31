package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.regex.*
import yjson.*
import yjson_support.*

// Pure original Hub process grammar and projection only. Facts must come
// from the actual paid constructor-selected resource read, then be included
// in its exact frozen canonical input. They are DATA, never launch authority.
// In particular an authored cwd is NOT resolved here, and no process/Source,
// current PID, environment value, namespace, receipt or host handle is made.
func workflowHubProcessText(value: AgentValue, name: String): String {
    match(value.field(name)){case Some(item)=>
        if(item.unifiedKind==ValueKind.Text){item.text.trimAscii()}else{""}
        case None=>""}
}
func workflowHubProcessInteger(value: AgentValue, name: String, fallback: Int64): Int64 {
    match(value.field(name)){case Some(item)=>
        try{Int64.parse(item.asNumberText())}catch(_:Exception){fallback}
        case None=>fallback}
}
func workflowHubProcessBool(value: AgentValue, name: String, fallback: Bool): Bool {
    match(value.field(name)){case Some(item)=>
        if(item.unifiedKind==ValueKind.Boolean){item.asBool()}else{fallback}
        case None=>fallback}
}
func workflowHubProcessSeconds(value: Int64, fallback: Int64): Int64 {
    min(3600,if(value<=0){fallback}else{value})*1000
}
func workflowHubProcessName(value: AgentValue): String {
    let name=workflowHubProcessText(value,"name")
    let bytes=unsafe{name.rawData()}
    if(bytes.size<1 || bytes.size>48){
        throw PureProviderError("hub.process_name_invalid","process name must contain 1-48 letters, digits, '-', '_' or '.'")}
    for(index in 0..bytes.size){
        let byte=bytes[index]
        let alphanumeric=(byte>=b'a' && byte<=b'z') || (byte>=b'A' && byte<=b'Z') || (byte>=b'0' && byte<=b'9')
        if((index==0 && !alphanumeric) || (!alphanumeric && byte!=b'-' && byte!=b'_' && byte!=b'.')){
            throw PureProviderError("hub.process_name_invalid","process name must contain 1-48 letters, digits, '-', '_' or '.'")}}
    name
}
func workflowHubProcessStringList(value: AgentValue, name: String): Array<String> {
    let source=match(value.field(name)){case None=>return [];case Some(item)=>item}
    if(source.unifiedKind!=ValueKind.List){
        throw PureProviderError("hub.process_string_list_invalid",name+" must be a string array")}
    let values=ArrayList<String>()
    for(item in source.items){
        if(item.unifiedKind!=ValueKind.Text){
            throw PureProviderError("hub.process_string_list_invalid",name+" must be a string array")}
        values.add(item.text)}
    values.toArray()
}
func workflowHubProcessStrings(values: Array<String>): AgentValue {
    let items=ArrayList<AgentValue>()
    for(value in values){items.add(textValue(value))}
    listValue(items.toArray())
}
func workflowHubProcessEnvironmentName(name: String): Bool {
    let bytes=unsafe{name.rawData()}
    if(bytes.size<1){return false}
    for(index in 0..bytes.size){
        let byte=bytes[index]
        if(!((byte>=b'a' && byte<=b'z') || (byte>=b'A' && byte<=b'Z') || byte==b'_' ||
            (index>0 && byte>=b'0' && byte<=b'9'))){return false}}
    true
}
func workflowHubProcessSecretName(name: String): Bool {
    let normalized=name.toAsciiUpper().replace("-","_")
    normalized.contains("SECRET") || normalized.contains("TOKEN") || normalized.contains("PASSWORD") ||
        normalized.contains("PASSWD") || normalized.contains("CREDENTIAL") || normalized.endsWith("_KEY") ||
        normalized.contains("API_KEY") || normalized=="SSH_AUTH_SOCK" || normalized.contains("COOKIE")
}
func workflowHubProcessEnvironment(arguments: AgentValue): AgentValue {
    let literal=match(arguments.field("env")){case None=>objectValue([]);case Some(value)=>value}
    if(literal.unifiedKind!=ValueKind.Object){
        throw PureProviderError("hub.process_env_invalid","env must be an object of string values")}
    let targets=ArrayList<String>()
    for(field in literal.fields){
        if(field.value.unifiedKind!=ValueKind.Text || !workflowHubProcessEnvironmentName(field.name) ||
            workflowHubProcessSecretName(field.name) || field.value.text.contains("\u{0000}")){
            throw PureProviderError("hub.process_env_invalid","env accepts only non-secret literal values; use secret_env for credentials")}
        // Original HashMap assignment has last-value behavior. Copying into
        // the canonical object below retains that exact literal semantics.
        if(!targets.contains(field.name)){targets.add(field.name)}}
    let literals=objectValue([])
    for(field in literal.fields){literals.put(field.name,field.value)}
    let mappings=ArrayList<ValueField>()
    let mapped=ArrayList<String>()
    for(section in ["env_from","secret_env"]){
        let value=match(arguments.field(section)){case None=>objectValue([]);case Some(item)=>item}
        if(value.unifiedKind!=ValueKind.Object){
            throw PureProviderError("hub.process_env_binding_invalid",section+" must map target names to host source names")}
        let output=ArrayList<ValueField>()
        for(field in value.fields){
            if(field.value.unifiedKind!=ValueKind.Text || mapped.contains(field.name)){
                throw PureProviderError("hub.process_env_binding_invalid","environment targets must be unique string mappings")}
            if(!workflowHubProcessEnvironmentName(field.name) || !workflowHubProcessEnvironmentName(field.value.text)){
                throw PureProviderError("hub.process_env_binding_invalid","environment mappings require valid variable names")}
            if(section!="secret_env" && (workflowHubProcessSecretName(field.name) || workflowHubProcessSecretName(field.value.text))){
                throw PureProviderError("hub.process_env_binding_invalid","secret-like environment mappings must be declared in secret_env")}
            mapped.add(field.name);output.add(ValueField(field.name,field.value))}
        mappings.add(ValueField(section,objectValue(output.toArray())))}
    for(name in targets){if(mapped.contains(name)){
        throw PureProviderError("hub.process_env_binding_invalid","environment target is declared more than once")}}
    mappings.add(ValueField("env",literals))
    objectValue(mappings.toArray())
}
func workflowHubProcessNetwork(arguments: AgentValue, shellMode: String): NetworkPolicy {
    let defaultMode=match(shellMode){case "restricted"=>NetworkPolicyMode.Denied
        case "proxy"=>NetworkPolicyMode.Mediated;case "trusted_host"=>NetworkPolicyMode.HostNetwork
        case _=>throw PureProviderError("workflow.process_fact_invalid","unknown actual shell network mode")}
    let policy=match(arguments.field("network")){
        case None=>NetworkPolicy(defaultMode)
        case Some(raw)=>match(parseNetworkPolicy(raw)){
            case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}}
    if(shellMode=="proxy" && networkPolicyModeIsHost(policy.mode)){
        throw PureProviderError("network.mode_denied","proxy shell mode forbids HostNetwork")}
    if(networkPolicyModeIsMediated(policy.mode) && !policy.publish.isEmpty()){
        throw PureProviderError("network.publish_not_supported","the mediated network gateway does not support published ports")}
    policy
}
func workflowHubProcessReady(arguments: AgentValue, network: NetworkPolicy): AgentValue {
    let value=match(arguments.field("ready")){case None=>return nullValue();case Some(item)=>item}
    if(value.unifiedKind!=ValueKind.Object){throw PureProviderError("hub.process_ready_invalid","ready must be an object")}
    let pattern=workflowHubProcessText(value,"log")
    let port=workflowHubProcessInteger(value,"port",0)
    let authoredHost=workflowHubProcessText(value,"host")
    let host=if(authoredHost==""){"127.0.0.1"}else{authoredHost}
    if(pattern=="" && port==0){throw PureProviderError("hub.process_ready_empty","ready requires log or port")}
    if(value.field("host").isSome() && host!="127.0.0.1"){
        throw PureProviderError("hub.process_ready_host_invalid","ready.host must be 127.0.0.1")}
    if(value.field("port").isSome() && (port<1 || port>65535)){
        throw PureProviderError("hub.process_ready_port_invalid","ready.port must be an integer from 1 to 65535")}
    if(port!=0 && networkPolicyModeIsDenied(network.mode)){
        throw PureProviderError("hub.process_ready_network_required","ready.port requires a non-denied network policy")}
    if(pattern!=""){try{let _=Regex(pattern,[])}catch(error:Exception){
        throw PureProviderError("hub.process_ready_log_invalid",error.message)}}
    objectValue([ValueField("log",if(pattern==""){nullValue()}else{textValue(pattern)}),
        ValueField("port",if(port==0){nullValue()}else{integerValue(port)}),ValueField("host",textValue(host)),
        ValueField("timeoutMs",integerValue(workflowHubProcessSeconds(workflowHubProcessInteger(value,"timeout",30),30)))])
}
func workflowHubProcessStart(arguments: AgentValue, shellMode: String): AgentValue {
    let name=workflowHubProcessName(arguments)
    let application=workflowHubProcessText(arguments,"application")
    if(application==""){throw PureProviderError("hub.process_application_required","start requires application")}
    let detached=workflowHubProcessBool(arguments,"detached",false)
    let persistent=workflowHubProcessBool(arguments,"persist",false) || detached
    let args=workflowHubProcessStringList(arguments,"args")
    let environment=workflowHubProcessEnvironment(arguments)
    let network=workflowHubProcessNetwork(arguments,shellMode)
    let ready=workflowHubProcessReady(arguments,network)
    let authoredRestart=workflowHubProcessText(arguments,"restart")
    let restart=if(authoredRestart==""){"no"}else{authoredRestart}
    if(restart!="no" && restart!="on-failure" && restart!="always"){
        throw PureProviderError("hub.process_restart_invalid","restart must be no, on-failure, or always")}
    objectValue([ValueField("name",textValue(name)),ValueField("application",textValue(application)),
        ValueField("args",workflowHubProcessStrings(args)),ValueField("cwd",textValue(workflowHubProcessText(arguments,"cwd"))),
        ValueField("pty",boolValue(!detached && workflowHubProcessBool(arguments,"pty",true))),
        ValueField("env",environment.field("env").getOrThrow()),ValueField("env_from",environment.field("env_from").getOrThrow()),
        ValueField("secret_env",environment.field("secret_env").getOrThrow()),ValueField("network",networkPolicyCanonicalValue(network)),
        ValueField("ready",ready),ValueField("restart",textValue(restart)),
        ValueField("persist",boolValue(persistent)),ValueField("detached",boolValue(detached))])
}
func workflowHubProcessKey(key: String): String {
    match(key.trimAscii()){
        case "ENTER"|"enter"=>"\r";case "TAB"|"tab"=>"\t";case "ESCAPE"|"escape"=>"\u{1b}"
        case "CTRL_C"|"ctrl_c"=>"\u{3}";case "CTRL_D"|"ctrl_d"=>"\u{4}"
        case "UP"|"up"=>"\u{1b}[A";case "DOWN"|"down"=>"\u{1b}[B"
        case "RIGHT"|"right"=>"\u{1b}[C";case "LEFT"|"left"=>"\u{1b}[D"
        case _=>throw PureProviderError("hub.process_key_invalid","Unsupported launch key "+key)}
}
func workflowHubProcessRequest(arguments: AgentValue, shellMode: String): AgentValue {
    if(arguments.unifiedKind!=ValueKind.Object){throw PureProviderError("workflow.input_invalid","Hub arguments must be an object")}
    let op=match(workflowTaskText(ToolCall("data","hub",arguments),"op",true)){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
    if(op=="ps"){return objectValue([ValueField("op",textValue(op))])}
    if(!["start","logs","stop","restart","send","wait","describe"].contains(op)){
        throw PureProviderError("hub.process_op_invalid","unsupported process operation: "+op)}
    if(op=="start"){return objectValue([ValueField("op",textValue(op)),ValueField("spec",workflowHubProcessStart(arguments,shellMode))])}
    let name=workflowHubProcessName(arguments)
    let fields=ArrayList<ValueField>([ValueField("op",textValue(op)),ValueField("name",textValue(name))])
    if(op=="describe"){return objectValue(fields.toArray())}
    if(op=="stop"){fields.add(ValueField("timeout_ms",integerValue(workflowHubProcessSeconds(workflowHubProcessInteger(arguments,"timeout",5),5))))}
    if(op=="restart"){
        if(arguments.field("network").isNone()){
            throw PureProviderError("network.restart_policy_required","hub.restart must restate the persisted network policy")}
        fields.add(ValueField("network",networkPolicyCanonicalValue(workflowHubProcessNetwork(arguments,shellMode))))}
    if(op=="logs"){
        fields.add(ValueField("lines",integerValue(min(1000,max(1,workflowHubProcessInteger(arguments,"lines",100))))))
        fields.add(ValueField("head",boolValue(workflowHubProcessBool(arguments,"head",false))))
        fields.add(ValueField("follow",boolValue(workflowHubProcessBool(arguments,"follow",false))))
        fields.add(ValueField("cursor",integerValue(workflowHubProcessInteger(arguments,"cursor",-1))))
        fields.add(ValueField("cursor_present",boolValue(arguments.field("cursor").isSome())))
        fields.add(ValueField("timeout_ms",integerValue(workflowHubProcessSeconds(workflowHubProcessInteger(arguments,"timeout",30),30))))
        fields.add(ValueField("grep",textValue(workflowHubProcessText(arguments,"grep"))))}
    if(op=="send"){
        let signal=workflowHubProcessText(arguments,"signal")
        var data=""
        var failure=nullValue()
        try{
            let keys=workflowHubProcessStringList(arguments,"keys")
            data=workflowHubProcessText(arguments,"text")
            if(data!="" && workflowHubProcessBool(arguments,"enter",true)){data+="\r"}
            for(key in keys){data+=workflowHubProcessKey(key)}
            if(signal=="" && data==""){throw PureProviderError("hub.process_send_empty","send requires text, keys, or signal")}
        }catch(error:PureProviderError){
            if(signal==""){throw error}
            failure=objectValue([ValueField("code",textValue(error.code)),ValueField("message",textValue(error.message))])
        }
        fields.add(ValueField("signal",textValue(signal)));fields.add(ValueField("stdin",textValue(data)))
        fields.add(ValueField("stdin_error",failure))}
    if(op=="wait"){
        let pattern=workflowHubProcessText(arguments,"pattern")
        if(pattern!=""){try{let _=Regex(pattern,[])}catch(error:Exception){
            throw PureProviderError("hub.process_pattern_invalid",error.message)}}
        fields.add(ValueField("condition",textValue(workflowHubProcessText(arguments,"for"))))
        fields.add(ValueField("pattern",textValue(pattern)))
        fields.add(ValueField("timeout_ms",integerValue(workflowHubProcessSeconds(workflowHubProcessInteger(arguments,"timeout",30),30))))}
    objectValue(fields.toArray())
}

// This action is a paid pure proposal surface. Native execution is admitted
// separately by the installed canonical resource executor. A returned proposal
// must never be copied into a claimed process grant.
func workflowHubProcessPolicy(input: AgentValue): AgentValue {
    workflowFields(input,["schema","action","source_digest","arguments","facts"])
    let facts=input.field("facts").getOrThrow()
    workflowFields(facts,["shell_mode"])
    let shellMode=workflowText(facts,"shell_mode")
    objectValue([ValueField("source_digest",input.field("source_digest").getOrThrow()),
        ValueField("request",workflowHubProcessRequest(input.field("arguments").getOrThrow(),shellMode))])
}
func workflowHubProcessProjectionPolicy(input: AgentValue): AgentValue {
    workflowFields(input,["schema","action","source_digest","request","observation"])
    let request=input.field("request").getOrThrow()
    let output=workflowHubProcessOutput(request,input.field("observation").getOrThrow())
    // This flag is the original start application outcome. It is not a
    // physical completion, Source, cancellation or ownership ACK.
    let failed=workflowText(request,"op")=="start" &&
        workflowText(output.field("daemon").getOrThrow(),"state")=="failed"
    objectValue([ValueField("source_digest",input.field("source_digest").getOrThrow()),
        ValueField("output",output),ValueField("is_error",boolValue(failed))])
}

func workflowHubProcessIntFact(value: AgentValue, name: String, nullable!: Bool = false): Unit {
    let field=value.field(name).getOrThrow()
    if(nullable && field.unifiedKind==ValueKind.Null){return}
    if(field.unifiedKind!=ValueKind.Number){throw PureProviderError("workflow.process_observation_invalid","integer process fact required")}
    try{let _=Int64.parse(field.asNumberText())}catch(_:Exception){
        throw PureProviderError("workflow.process_observation_invalid","process fact exceeds original Int64")}
}
func workflowHubProcessDaemonFact(value: AgentValue): AgentValue {
    let fields=["name","id","state","pid","exitCode","exitReason","createdAt","startedAt","exitedAt","readyAt",
        "readyMatch","restartCount","outputBytes","owner","readyPending","persist","detached","recoveryRequired","stale","startIdentity"]
    if(value.field("persistenceWarning").isSome()){
        let full=ArrayList<String>(fields);full.add("persistenceWarning");workflowFields(value,full.toArray())
        let _=workflowText(value,"persistenceWarning")
    }else{workflowFields(value,fields)}
    for(name in ["name","id","state","exitReason","readyMatch","owner","startIdentity"]){let _=workflowText(value,name)}
    for(name in ["createdAt","startedAt","restartCount","outputBytes"]){workflowHubProcessIntFact(value,name)}
    for(name in ["pid","exitCode","exitedAt","readyAt"]){workflowHubProcessIntFact(value,name,nullable:true)}
    for(name in ["persist","detached","recoveryRequired","stale"]){
        if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean){
            throw PureProviderError("workflow.process_observation_invalid","boolean process fact required")}}
    let pending=value.field("readyPending").getOrThrow()
    if(pending.unifiedKind!=ValueKind.List){throw PureProviderError("workflow.process_observation_invalid","readiness fact must be an array")}
    for(item in pending.items){if(item.unifiedKind!=ValueKind.Text){
        throw PureProviderError("workflow.process_observation_invalid","complete readiness text required")}}
    // All fields remain immutable borrowed DATA in the paid Provider frame.
    // A PID, terminal state, empty pending array or bool grants no retirement.
    value
}
func workflowHubProcessSpecFact(value: AgentValue): AgentValue {
    workflowFields(value,["name","application","args","cwd","pty","env","env_from","secret_env","network","ready","restart","persist","detached"])
    for(name in ["name","application","cwd","restart"]){let _=workflowText(value,name)}
    for(name in ["pty","persist","detached"]){if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean){
        throw PureProviderError("workflow.process_observation_invalid","boolean process specification required")}}
    let _=workflowHubProcessStringList(value,"args")
    let _=workflowHubProcessEnvironment(value)
    match(parseNetworkPolicy(value.field("network").getOrThrow())){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(_)=>()}
    let ready=value.field("ready").getOrThrow()
    if(ready.unifiedKind!=ValueKind.Null){
        workflowFields(ready,["log","port","host","timeoutMs"])
        for(name in ["log","port"]){let field=ready.field(name).getOrThrow()
            if(field.unifiedKind==ValueKind.Null){continue}
            if(name=="log"){let _=workflowText(ready,name)}else{workflowHubProcessIntFact(ready,name)}}
        let _=workflowText(ready,"host");workflowHubProcessIntFact(ready,"timeoutMs")}
    value
}
func workflowHubProcessJoinLines(lines: Array<String>): String {
    var output=""
    // Preserve the old joinDaemonLines behavior, including empty edge lines.
    for(line in lines){if(output!=""){output+="\n"};output+=line}
    output
}
func workflowHubProcessLogText(text: String, grep: String, limit: Int64, head: Bool): String {
    var source=text
    if(grep!=""){
        let expression=try{Regex(grep,[])}catch(error:Exception){
            throw PureProviderError("hub.process_grep_invalid",error.message)}
        let selected=ArrayList<String>()
        for(line in source.split("\n")){if(expression.find(line).isSome()){selected.add(line)}}
        source=workflowHubProcessJoinLines(selected.toArray())}
    let lines=source.split("\n")
    if(lines.size<=limit){return source}
    workflowHubProcessJoinLines(if(head){lines[0..limit]}else{lines[lines.size-limit..lines.size]})
}
func workflowHubProcessOutput(request: AgentValue, observation: AgentValue): AgentValue {
    workflowFields(observation,["schema","op","facts"])
    let op=workflowText(request,"op")
    if(workflowText(observation,"schema")!="axyndra.hub-process-observation/v1" || workflowText(observation,"op")!=op){
        throw PureProviderError("workflow.process_observation_invalid","actual process operation differs from the exact frozen request")}
    let facts=observation.field("facts").getOrThrow()
    let fields=ArrayList<ValueField>([ValueField("op",textValue(op))])
    if(op=="ps"){
        workflowFields(facts,["daemons","recovery_warnings"])
        let daemons=facts.field("daemons").getOrThrow();let warnings=facts.field("recovery_warnings").getOrThrow()
        if(daemons.unifiedKind!=ValueKind.List || warnings.unifiedKind!=ValueKind.List){
            throw PureProviderError("hub.process_list_invalid","process supervisor returned an invalid daemon list")}
        for(daemon in daemons.items){let _=workflowHubProcessDaemonFact(daemon)}
        for(warning in warnings.items){if(warning.unifiedKind!=ValueKind.Text){
            throw PureProviderError("workflow.process_observation_invalid","complete process recovery warning required")}}
        fields.add(ValueField("daemons",daemons))
        if(!warnings.items.isEmpty()){fields.add(ValueField("recoveryWarnings",warnings))}
    }else if(op=="logs"){
        // The generic owner must lend a prepaid, secret-redacted UTF8 window
        // chosen by this EXACT byte cursor. Native owns grep/head/tail policy.
        workflowFields(facts,["name","window_text","cursor","timed_out","state","reset"])
        if(workflowText(facts,"name")!=workflowText(request,"name")){
            throw PureProviderError("workflow.process_observation_invalid","log window belongs to another actual process")}
        workflowHubProcessIntFact(facts,"cursor")
        for(name in ["timed_out","reset"]){if(facts.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean){
            throw PureProviderError("workflow.process_observation_invalid","log status must be boolean")}}
        fields.add(ValueField("name",facts.field("name").getOrThrow()))
        fields.add(ValueField("text",textValue(workflowHubProcessLogText(workflowText(facts,"window_text"),
            workflowText(request,"grep"),workflowHubProcessInteger(request,"lines",100),request.field("head").getOrThrow().asBool()))))
        fields.add(ValueField("cursor",facts.field("cursor").getOrThrow()))
        fields.add(ValueField("timedOut",facts.field("timed_out").getOrThrow()))
        fields.add(ValueField("state",textValue(workflowText(facts,"state"))))
        fields.add(ValueField("reset",facts.field("reset").getOrThrow()))
    }else{
        if(op=="start"){workflowFields(facts,["daemon","ready_timed_out"])}
        else if(op=="describe"){workflowFields(facts,["daemon","spec"])}
        else if(op=="wait"){workflowFields(facts,["daemon","timed_out","matched"])}
        else if(op=="stop" || op=="restart" || op=="send"){workflowFields(facts,["daemon"])}
        else{throw PureProviderError("hub.process_op_invalid","unsupported process operation: "+op)}
        let daemon=workflowHubProcessDaemonFact(facts.field("daemon").getOrThrow())
        let name=if(op=="start"){workflowText(request.field("spec").getOrThrow(),"name")}else{workflowText(request,"name")}
        if(workflowText(daemon,"name")!=name){throw PureProviderError("workflow.process_observation_invalid","process snapshot differs from the actual requested process")}
        fields.add(ValueField("daemon",daemon))
        if(op=="start"){
            if(facts.field("ready_timed_out").getOrThrow().unifiedKind!=ValueKind.Boolean){throw PureProviderError("workflow.process_observation_invalid","readiness timeout must be boolean")}
            fields.add(ValueField("readyTimedOut",facts.field("ready_timed_out").getOrThrow()))}
        if(op=="describe"){fields.add(ValueField("spec",workflowHubProcessSpecFact(facts.field("spec").getOrThrow())))}
        if(op=="wait"){
            if(facts.field("timed_out").getOrThrow().unifiedKind!=ValueKind.Boolean){throw PureProviderError("workflow.process_observation_invalid","wait timeout must be boolean")}
            let matched=facts.field("matched").getOrThrow()
            if(matched.unifiedKind!=ValueKind.Null && matched.unifiedKind!=ValueKind.Text){throw PureProviderError("workflow.process_observation_invalid","complete wait match required")}
            fields.add(ValueField("timedOut",facts.field("timed_out").getOrThrow()));fields.add(ValueField("matched",matched))}}
    objectValue(fields.toArray())
}

func workflowHubProcessOperation180(value:AgentValue):Bool{
    let route=match(workflowHubRoute111(ToolCall("frozen-data","hub",value))){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message)
        case Result.Ok(selected)=>selected}
    httpIntentText(route,"route")=="process"
}
func workflowHubProcessIntents180(arguments:AgentValue,options:AgentValue):AgentValue{
    if(options.field("process_facts").isNone()){
        workflowFields(options,["background_enabled"])
        throw PureProviderError("workflow.peer_primitive_unavailable","this peer primitive is not installed")}
    workflowFields(options,["background_enabled","process_facts"])
    let facts=options.field("process_facts").getOrThrow()
    workflowFields(facts,["shell_mode","broker_available"])
    if(facts.field("broker_available").getOrThrow().unifiedKind!=ValueKind.Boolean){
        throw PureProviderError("workflow.process_configuration_invalid","expected actual broker availability")}
    let request=workflowHubProcessRequest(arguments,workflowText(facts,"shell_mode"))
    if(workflowText(request,"op")=="start" && request.field("spec").getOrThrow().field("persist").getOrThrow().asBool() &&
        !facts.field("broker_available").getOrThrow().asBool()){
        throw PureProviderError("hub.process_broker_required","persistent process services require the process broker")}
    listValue([objectValue([ValueField("id",textValue("hub-process-"+workflowText(request,"op"))),
        ValueField("service",textValue("process.service")),ValueField("input",objectValue([
            ValueField("schema",textValue("axyndra.hub-process-request/v1")),ValueField("request",request),ValueField("facts",facts)]))])])
}
func workflowExecuteHubProcess180(arguments:AgentValue,broker:FrozenPrimitiveBroker111):DocumentPolicyToolResult{
    let plan=arguments.field("host_plan").getOrThrow();let supplied=plan.field("intents").getOrThrow()
    if(supplied.unifiedKind!=ValueKind.List || supplied.items.size!=1 || workflowText(supplied.items[0],"service")!="process.service"){
        throw PureProviderError("workflow.process_plan_changed","expected one exact admitted process service")}
    let expected=workflowHubProcessIntents180(arguments.field("input").getOrThrow(),arguments.field("configuration").getOrThrow())
    let actualInput=supplied.items[0].field("input").getOrThrow();let frozen=actualInput.field("request").getOrThrow()
    // This is immutable DATA inserted by the actual resource preparation, not
    // a PID/name or plugin-authored Source claim. Host validates it again at
    // the effect boundary against its actual private incarnation record.
    expected.items[0].field("input").getOrThrow().field("request").getOrThrow().put("actual_target",frozen.field("actual_target").getOrThrow())
    if(workflowText(plan,"version")!=PLUGIN_PRIMITIVE_PARENT111 || canonicalAgentValue(expected)!=canonicalAgentValue(supplied)){
        throw PureProviderError("workflow.process_plan_changed","complete process input differs from canonical preparation")}
    let response=broker.consume(workflowText(expected.items[0],"id"))
    let request=expected.items[0].field("input").getOrThrow().field("request").getOrThrow()
    let output=workflowHubProcessOutput(request,response.field("output").getOrThrow())
    DocumentPolicyToolResult(output,isError:workflowText(request,"op")=="start" && workflowText(output.field("daemon").getOrThrow(),"state")=="failed")
}
