package agent_host_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Opt-in operator metadata, not a Native contribution or a Source. None keeps
// the former one fixed executable path; malformed selection never falls back.
func hostManagedConfiguredProcessIds(configuration:AgentValue):?Array<String>{
    let configured=configuration.field("managed_process_services")
    if(configured.isNone()){return None<Array<String>>}
    let ids=configured.getOrThrow()
    if(ids.unifiedKind!=ValueKind.List || ids.items.isEmpty() || ids.items.size>16){
        throw IllegalArgumentException("finite operator process services required")}
    let values=ArrayList<String>();let seen=HashSet<String>()
    for(item in ids.items){
        if(item.unifiedKind!=ValueKind.Text || !hostLifecycleIdentifier(item.text,128) || seen.contains(item.text)){
            throw IllegalArgumentException("unique operator process service identities required")}
        seen.add(item.text);values.add(item.text)
    }
    Some(values.toArray())
}

// Selecting another fixed program cannot change an already frozen parent
// filesystem/network permission domain. Different profiles need a separately
// prepared parent binding; they are rejected rather than silently widened.
func hostManagedConfiguredScopeEqual(base:HostPluginLifecycleLaunchGrant,
    selected:HostPluginLifecycleLaunchGrant):Bool{
    if(!base.managedSameConfiguredOwner(selected)){return false}
    let original=base.launchPlan;let actual=selected.launchPlan
    for(key in ["namespace","package_digest","configuration_digest","thread_id","instance_identity",
        "permission_domain","package_root","workspace_root","workspace_mode","network","read_only_mounts"]){
        if(canonicalAgentValue(original.field(key).getOrThrow())!=canonicalAgentValue(actual.field(key).getOrThrow())){return false}}
    true
}

// The original lifecycle lease retains its original identity/binding while
// the actual process and stream windows obey both fixed operator ceilings.
// Called under the same paid private grant; no independent allocator exists.
func hostManagedConfiguredLeasePlan(base:HostPluginLifecycleLaunchGrant,
    selected:HostPluginLifecycleLaunchGrant):AgentValue{
    let original=base.launchPlan;let actual=selected.launchPlan
    let fields=ArrayList<ValueField>()
    for(field in actual.fields where !["lifetime_ms","max_input_bytes","max_output_bytes","max_instances","startup"].contains(field.name)){fields.add(field)}
    for(key in ["lifetime_ms","max_input_bytes","max_output_bytes","max_instances"]){
        fields.add(ValueField(key,integerValue(min(hostLifecycleInt(original,key,1),hostLifecycleInt(actual,key,1)))))}
    let left=original.field("startup").getOrThrow();let right=actual.field("startup").getOrThrow()
    let startup=ArrayList<ValueField>()
    for(key in ["timeout_ms","max_input_bytes","max_output_bytes","max_writes"]){
        startup.add(ValueField(key,integerValue(min(hostLifecycleInt(left,key,1),hostLifecycleInt(right,key,1)))))}
    fields.add(ValueField("startup",objectValue(startup.toArray())))
    objectValue(fields.toArray())
}
