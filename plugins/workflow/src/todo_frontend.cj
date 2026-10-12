package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// UI commands propose data after the same actual document ContextRead. They
// cannot construct a Root, permission, Receipt or write an import/export file.
func workflowTodoFrontend(previous: AgentValue, snapshot: AgentValue, input: AgentValue): AgentValue {
    let action=workflowText(input,"frontend_action")
    let current=match(decodeTodoPhases(previous)){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message)
        case Result.Ok(value)=>value}
    let digest=workflowText(snapshot,"sha256")
    var after=current
    if(action=="view"){
        workflowFields(input,["frontend_action"])
    }else if(action=="replace_markdown"){
        workflowFields(input,["frontend_action","text","expected_digest"])
        let expected=workflowText(input,"expected_digest")
        if(expected!=digest){throw PureProviderError("workflow.todo_editor_conflict","the actual Todo document changed after the displayed read")}
        after=match(todoPhasesFromMarkdown(workflowText(input,"text"))){
            case Result.Err(error)=>throw PureProviderError(error.code,error.message)
            case Result.Ok(value)=>value}
    }else if(action=="replace_phases"){
        workflowFields(input,["frontend_action","phases","expected_digest"])
        if(workflowText(input,"expected_digest")!=digest){throw PureProviderError("workflow.todo_editor_conflict","the actual Todo document changed after the displayed read")}
        after=match(decodeTodoPhases(input.field("phases").getOrThrow())){
            case Result.Err(error)=>throw PureProviderError(error.code,error.message)
            case Result.Ok(value)=>value}
    }else if(action=="migrate"){
        workflowFields(input,["frontend_action","legacy_json","legacy_digest"])
        if(workflowText(snapshot,"json")!="null"){
            throw PureProviderError("workflow.todo_migration_exists","an existing current document cannot be replaced by legacy metadata")}
        let raw=workflowText(input,"legacy_json")
        if(raw.size>8388608 || modelPolicySha256Text(raw)!=workflowText(input,"legacy_digest")){
            throw PureProviderError("workflow.todo_migration_invalid","legacy data differs from its explicitly displayed input")}
        after=match(decodeTodoPhases(parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32))){
            case Result.Err(error)=>throw PureProviderError(error.code,error.message)
            case Result.Ok(value)=>value}
    }else if(action=="import"){
        workflowFields(input,["frontend_action","reference"])
        let reference=workflowText(input,"reference")
        if(reference=="" || reference.contains("\u{0000}") || reference.size>4096){
            throw PureProviderError("workflow.todo_file_reference","an explicit bounded source is required")}
    }else if(action=="export"){
        workflowFields(input,["frontend_action","destination"])
        let destination=workflowText(input,"destination")
        if(destination=="" || destination.contains("\u{0000}") || destination.size>4096){
            throw PureProviderError("workflow.todo_file_reference","an explicit bounded destination is required")}
    }else{
        throw PureProviderError("workflow.todo_frontend_unknown","this installed Todo contribution has no such frontend action")}
    let encoded=encodeTodoPhases(after)
    let result=objectValue([ValueField("schema",textValue("axyndra.todo-frontend/v1")),
        ValueField("action",textValue(action)),ValueField("phases",encoded),
        ValueField("markdown",textValue(todoPhasesToMarkdown(after))),
        ValueField("document_digest",textValue(if(canonicalAgentValue(previous)==canonicalAgentValue(encoded)){digest}else{modelPolicySha256Text(stringifyUnifiedJson(encoded))}))])
    if(action=="export"){result.put("destination",input.field("destination").getOrThrow())}
    if(action=="import"){result.put("reference",input.field("reference").getOrThrow())}
    objectValue([ValueField("changed",boolValue(canonicalAgentValue(previous)!=canonicalAgentValue(encoded))),
        ValueField("document",encoded),ValueField("output",result),ValueField("is_error",boolValue(false))])
}
