package compaction_plugin

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*

func compactionEventInput(value: AgentValue,phase:String,fields:Array<ValueField>):AgentValue {
    let values=ArrayList<ValueField>([ValueField("schema",value.field("schema").getOrThrow()),
        ValueField("phase",textValue(phase)),ValueField("snapshot_digest",value.field("snapshot_digest").getOrThrow()),
        ValueField("state",value.field("state").getOrThrow()),ValueField("event",value.field("event").getOrThrow())])
    values.add(all:fields);objectValue(values.toArray())
}

// Runs the existing pure algorithms against the same immutable event. It
// never invents Host intern identities. Hashline ranges and non-inline text
// remain explicit Host observation boundaries, even when another task fits.
func compactionReferenceEvent(value:AgentValue):AgentValue {
    policyFields(value,["schema","phase","snapshot_digest","state","event"])
    let plan=compactionReferencePlan(compactionEventInput(value,"reference_plan",[]))
    let pending=ArrayList<AgentValue>();let reduced=ArrayList<ValueField>()
    for(task in plan.field("tasks").getOrThrow().items){
        let source=task.field("source").getOrThrow();let bytes=compactionReferenceBytes(source)
        let mode=policyText(task,"mode")
        if(bytes>2048 || !["compact","excerpt"].contains(mode)){pending.add(task);continue}
        let result=compactionTextFragment(objectValue([
            ValueField("schema",value.field("schema").getOrThrow()),ValueField("phase",textValue("text_fragment")),
            ValueField("snapshot_digest",value.field("snapshot_digest").getOrThrow()),ValueField("source",source),
            ValueField("sequence",integerValue(1)),ValueField("mode",textValue(mode)),ValueField("limit",task.field("limit").getOrThrow()),
            ValueField("offset",integerValue(0)),ValueField("total",integerValue(bytes)),
            ValueField("text",source.field("inline").getOrThrow()),ValueField("carry",nullValue())]))
        if(!compactionFragmentBool(result,"complete") || structuredInteger(result,"next_offset")!=bytes){compactionFragmentError()}
        reduced.add(ValueField(policyText(task,"key"),objectValue([
            ValueField("result",result.field("result").getOrThrow()),ValueField("prior",result.field("prior").getOrThrow())])))
    }
    let values=objectValue(reduced.toArray())
    if(!pending.isEmpty()){return objectValue([ValueField("kind",textValue("reduce")),
        ValueField("tasks",listValue(pending.toArray())),ValueField("reduced",values)])}
    compactionReferenceEventFold(compactionEventInput(value,"reference_event_fold",[ValueField("reduced",values)]))
}

func compactionReferenceEventFold(value:AgentValue):AgentValue {
    policyFields(value,["schema","phase","snapshot_digest","state","event","reduced"])
    let folded=compactionReferenceFold(compactionEventInput(value,"reference_fold",[ValueField("reduced",value.field("reduced").getOrThrow())]))
    let commands=folded.field("commands").getOrThrow()
    if(commands.items.isEmpty()){
        let state=compactionReferenceMerge(compactionEventInput(value,"reference_merge",[ValueField("commands",commands)]))
        return objectValue([ValueField("kind",textValue("state")),ValueField("state",state)])
    }
    objectValue([ValueField("kind",textValue("commands")),ValueField("commands",commands)])
}
