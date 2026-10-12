package agent_host_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

foreign func axyndra_read_view_copy(source: CString, witness: CString, destination: CString, maximum: Int64): Int64

public func hostReadResourceCopy(source: String, witness: String, destination: String, maximum: Int64): Result<Int64> {
    unsafe {
        let src = LibC.mallocCString(source); let expected = LibC.mallocCString(witness); let dst = LibC.mallocCString(destination)
        try {
            let count = axyndra_read_view_copy(src, expected, dst, maximum)
            if (count < 0) { return hostPluginResourceError("read_view.resource_changed", "read resource changed or cannot be copied through verified handles") }
            Result.Ok(count)
        } finally { LibC.free(dst); LibC.free(expected); LibC.free(src) }
    }
}

public func hostValidReadonlyDelegationGrants(value: AgentValue): Bool {
    if (value.unifiedKind != ValueKind.List || value.items.size > 32 || stringifyUnifiedJson(value).size > 65536) { return false }
    let contributions = HashSet<String>()
    for (grant in value.items) {
        let fields=ArrayList<String>(["contribution","tools","max_calls","max_depth"])
        match(grant.field("file_plan_proposals")){
            case Some(value)=>
                if(value.unifiedKind!=ValueKind.Boolean){return false}
                fields.add("file_plan_proposals")
            case None=>()}
        if (!httpIntentExactFields(grant, fields.toArray()) ||
            !channelIntentIdentifier(httpIntentText(grant, "contribution")) || contributions.contains(httpIntentText(grant, "contribution")) ||
            readonlyDelegationInteger(grant, "max_calls") < 1 || readonlyDelegationInteger(grant, "max_calls") > HOST_DERIVED_MAX_WIDTH ||
            readonlyDelegationInteger(grant, "max_depth") < 2 || readonlyDelegationInteger(grant, "max_depth") > HOST_DERIVED_MAX_DEPTH) { return false }
        contributions.add(httpIntentText(grant, "contribution"))
        let tools = grant.field("tools").getOrThrow()
        if (tools.unifiedKind != ValueKind.List || tools.items.size > 32) { return false }
        let aliases = HashSet<String>(); let names = HashSet<String>()
        for (tool in tools.items) {
            if (!httpIntentExactFields(tool, ["alias", "plugin", "contribution"]) ||
                !channelIntentIdentifier(httpIntentText(tool, "alias")) || !httpServicePluginNamespace(httpIntentText(tool, "plugin")) ||
                !channelIntentIdentifier(httpIntentText(tool, "contribution"))) { return false }
            let name = httpIntentText(tool, "plugin") + "." + httpIntentText(tool, "contribution")
            if (aliases.contains(httpIntentText(tool, "alias")) || names.contains(name)) { return false }
            aliases.add(httpIntentText(tool, "alias")); names.add(name)
        }
    }
    true
}

