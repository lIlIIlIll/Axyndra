package agent_domain

import std.convert.*

import yjson.*
import yjson_support.*

// Structural DATA contract only; the installed Native owns all business
// grammar/defaults. Neither this validator nor a frozen target grants effects.
func pluginHubProcessInputValid180(input:AgentValue):Bool{
    if(!httpIntentExactFields(input,["schema","request","facts"]) || httpIntentText(input,"schema")!="axyndra.hub-process-request/v1"){
        return false}
    let facts=input.field("facts").getOrThrow()
    if(!httpIntentExactFields(facts,["shell_mode","broker_available"]) || facts.field("broker_available").getOrThrow().unifiedKind!=ValueKind.Boolean ||
        (httpIntentText(facts,"shell_mode")!="restricted" && httpIntentText(facts,"shell_mode")!="proxy" && httpIntentText(facts,"shell_mode")!="trusted_host")){
        return false}
    let request=input.field("request").getOrThrow();let op=httpIntentText(request,"op")
    if(op=="start"){
        if(!httpIntentExactFields(request,["op","spec","actual_target"]) || request.field("actual_target").getOrThrow().unifiedKind!=ValueKind.Null){return false}
        let spec=request.field("spec").getOrThrow()
        if(!httpIntentExactFields(spec,["name","application","args","cwd","pty","env","env_from","secret_env","network","ready","restart","persist","detached"])){return false}
        for(name in ["name","application","cwd","restart"]){if(spec.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
        for(name in ["pty","persist","detached"]){if(spec.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean){return false}}
        if(spec.field("args").getOrThrow().unifiedKind!=ValueKind.List){return false}
        for(value in spec.field("args").getOrThrow().items){if(value.unifiedKind!=ValueKind.Text){return false}}
        for(name in ["env","env_from","secret_env"]){let object=spec.field(name).getOrThrow();if(object.unifiedKind!=ValueKind.Object){return false}
            let fields=object.asObject();for(index in 0..fields.size()){if(fields.valueAt(index).unifiedKind!=ValueKind.Text){return false}}}
        if(parseNetworkPolicy(spec.field("network").getOrThrow()).isError()){return false}
        let ready=spec.field("ready").getOrThrow()
        if(ready.unifiedKind!=ValueKind.Null && !httpIntentExactFields(ready,["log","port","host","timeoutMs"])){return false}
        return true
    }
    if(op=="ps"){return httpIntentExactFields(request,["op","actual_target"]) && request.field("actual_target").getOrThrow().unifiedKind==ValueKind.Null}
    if(op=="describe"){if(!httpIntentExactFields(request,["op","name","actual_target"])){return false}}
    else if(op=="stop"){if(!httpIntentExactFields(request,["op","name","timeout_ms","actual_target"])){return false}}
    else if(op=="restart"){if(!httpIntentExactFields(request,["op","name","network","actual_target"]) || parseNetworkPolicy(request.field("network").getOrThrow()).isError()){return false}}
    else if(op=="logs"){if(!httpIntentExactFields(request,["op","name","lines","head","follow","cursor","cursor_present","timeout_ms","grep","actual_target"])){return false}
        for(name in ["head","follow","cursor_present"]){if(request.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean){return false}}
        for(name in ["lines","cursor"]){if(!pluginProcessInt180(request,name)){return false}}}
    else if(op=="send"){if(!httpIntentExactFields(request,["op","name","signal","stdin","stdin_error","actual_target"])){return false}
        for(name in ["signal","stdin"]){if(request.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
        let failure=request.field("stdin_error").getOrThrow()
        if(failure.unifiedKind!=ValueKind.Null && (!httpIntentExactFields(failure,["code","message"]) ||
            failure.field("code").getOrThrow().unifiedKind!=ValueKind.Text || failure.field("message").getOrThrow().unifiedKind!=ValueKind.Text)){return false}}
    else if(op=="wait"){if(!httpIntentExactFields(request,["op","name","condition","pattern","timeout_ms","actual_target"])){return false}
        for(name in ["condition","pattern"]){if(request.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}}
    else{return false}
    if(request.field("name").getOrThrow().unifiedKind!=ValueKind.Text){return false}
    if(request.field("timeout_ms").isSome() && (!pluginProcessInt180(request,"timeout_ms") || Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText())<0)){return false}
    let target=request.field("actual_target").getOrThrow()
    if(target.unifiedKind==ValueKind.Null){return true}
    httpIntentExactFields(target,["id","generation","pid","start_identity","spec"]) &&
        target.field("spec").getOrThrow().unifiedKind==ValueKind.Object &&
        target.field("id").getOrThrow().unifiedKind==ValueKind.Text && target.field("start_identity").getOrThrow().unifiedKind==ValueKind.Text &&
        pluginProcessInt180(target,"generation") && pluginProcessInt180(target,"pid")
}
func pluginProcessInt180(value:AgentValue,name:String):Bool{
    let data=value.field(name).getOrThrow()
    if(data.unifiedKind!=ValueKind.Number){return false}
    try{let _=Int64.parse(data.asNumberText());true}catch(_:Exception){false}
}
