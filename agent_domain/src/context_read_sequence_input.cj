package agent_domain

import yjson.*
import yjson_support.*

public let CONTEXT_READ_SEQUENCE_INPUT_SCHEMA="axyndra.context-read-input/v2"
// No Source is created here. Store separately rereads all Completed facts and
// proves their original canonical parent, order, current Run and projection.
public func validateContextReadSequenceInputProjection(input:AgentValue,links:Array<ContextReadFactLink>):Result<Unit>{
    try{
        let envelope=input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
        if(!httpIntentExactFields(envelope,["schema","data","facts"]) ||
            httpIntentText(envelope,"schema")!=CONTEXT_READ_SEQUENCE_INPUT_SCHEMA || links.size<1 || links.size>8 ||
            canonicalAgentValue(envelope.field("facts").getOrThrow())!=canonicalAgentValue(contextReadFactLinksValue(links))){
            throw IllegalArgumentException("sequence envelope differs from its actual fact references")}
        let data=envelope.field("data").getOrThrow()
        if(data.unifiedKind!=ValueKind.List || data.items.size!=links.size){throw IllegalArgumentException("one output per exact fact required")}
        let first=links[0].origin
        for(index in 0..links.size){let link=links[index];let origin=link.origin
            if(link.runId.value!=links[0].runId.value || origin.ownerNamespace!=first.ownerNamespace ||
                origin.packageDigest!=first.packageDigest || origin.configurationDigest!=first.configurationDigest ||
                origin.projectionDigest!=first.projectionDigest || origin.parentCallItemId!=first.parentCallItemId ||
                origin.parentKind!=first.parentKind || origin.parentOperationId!=first.parentOperationId ||
                origin.parentDecisionId!=first.parentDecisionId || origin.parentScopedCallId!=first.parentScopedCallId ||
                modelPolicySha256Text(stringifyUnifiedJson(data.items[index]))!=link.outputDigest ||
                stringifyUnifiedJson(data.items[index]).size!=link.outputBytes){
                throw IllegalArgumentException("sequence output or frozen canonical owner changed")}}
        Result.Ok(())
    }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.PermissionDenied,"context.read_input_unattested",
        "sequence data requires every exact completed canonical fact"))}
}
public func contextReadSequenceInput(input:AgentValue,facts:Array<ContextReadFact>):AgentValue{
    if(input.unifiedKind!=ValueKind.Object || input.field(CONTEXT_READ_INPUT_FIELD).isSome() || facts.size<1 || facts.size>8){
        throw IllegalArgumentException("sequence projection requires original business input and bounded facts")}
    let envelope=objectValue([ValueField("schema",textValue(CONTEXT_READ_SEQUENCE_INPUT_SCHEMA)),
        ValueField("data",listValue(facts.map{fact=>fact.output()})),ValueField("facts",contextReadFactLinksValue(facts.map{fact=>fact.link()}))])
    let fields=input.fields.toArray();let result=objectValue(fields)
    result.put(CONTEXT_READ_INPUT_FIELD,envelope)
    let _=parseUnifiedJson(stringifyUnifiedJson(result),maxBytes:8388608)
    if(validateContextReadSequenceInputProjection(result,facts.map{fact=>fact.link()}).isError()){
        throw IllegalArgumentException("sequence projection is not exact")};result
}
