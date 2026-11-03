package dap_plugin

import std.collection.*
import yjson.*
import yjson_support.*

// Business selection only. configured_processes is descriptive Host metadata;
// its service ID never supplies permission or a Source. Host independently
// matches the actual frozen operator ceiling after ordinary Derived handoff.
func dapOwnedSelectAdapter(input:JsonNode,configuration:JsonNode):JsonNode{
    let choices=field(configuration,"adapters")
    if(choices.unifiedKind==UnifiedJsonKind.Null){
        let requested=debugText(input,"adapter")
        require(requested=="" || requested==text(configuration,"adapter"),"tool.debug_adapter_unavailable")
        return configuration}
    require(choices.unifiedKind==UnifiedJsonKind.Object && !choices.fields.isEmpty() && choices.fields.size<=16,
        "dap_plugin.configuration_invalid")
    var selected="";let requested=debugText(input,"adapter")
    let program=debugText(input,"program")
    for(entry in choices.fields){
        require(entry.name!="" && entry.name.size<=128 && !entry.name.contains("\u{0}"),"dap_plugin.configuration_invalid")
        let item=entry.value
        exact(item,["service_id","fileTypes","launchDefaults","attachDefaults"])
        require(text(item,"service_id")!="" && field(item,"fileTypes").unifiedKind==UnifiedJsonKind.List &&
            field(item,"launchDefaults").unifiedKind==UnifiedJsonKind.Object &&
            field(item,"attachDefaults").unifiedKind==UnifiedJsonKind.Object,"dap_plugin.configuration_invalid")
        for(suffix in field(item,"fileTypes").items){require(suffix.unifiedKind==UnifiedJsonKind.Text && suffix.text!="","dap_plugin.configuration_invalid")}
        if(requested!="" && entry.name==requested){selected=entry.name}
    }
    if(requested!=""){require(selected!="","tool.debug_adapter_unavailable")}
    else{
        for(entry in choices.fields where selected==""){
            for(suffix in field(entry.value,"fileTypes").items where selected=="" && program!="" && program.endsWith(suffix.text)){
                selected=entry.name}}
        if(selected==""){selected=choices.fields[0].name}}
    let item=choices.field(selected).getOrThrow();let service=text(item,"service_id")
    let ceilings=field(configuration,"configured_processes")
    require(ceilings.unifiedKind==UnifiedJsonKind.List,"dap_plugin.configured_process_required")
    var actual:?JsonNode=None<JsonNode>
    for(ceiling in ceilings.items where text(ceiling,"service_id")==service){
        require(actual.isNone(),"dap_plugin.configured_process_ambiguous");actual=Some(ceiling)}
    require(actual.isSome(),"tool.debug_adapter_unavailable")
    let ceiling=actual.getOrThrow()
    exact(ceiling,["service_id","executable","args","environment","compatible_scope"])
    require(boolean(ceiling,"compatible_scope"),"dap_plugin.configured_process_scope_changed")
    let fields=ArrayList<JsonObjectEntry>()
    for(entry in configuration.fields where !["adapter","executable","args","environment","launch","attach","configured_process"].contains(entry.name)){fields.add(entry)}
    fields.add(JsonObjectEntry("adapter",jsonString(selected)))
    for(key in ["executable","args","environment"]){fields.add(JsonObjectEntry(key,field(ceiling,key)))}
    fields.add(JsonObjectEntry("launch",field(item,"launchDefaults")))
    fields.add(JsonObjectEntry("attach",field(item,"attachDefaults")))
    fields.add(JsonObjectEntry("configured_process",jsonString(service)))
    jsonObject(fields.toArray())
}
