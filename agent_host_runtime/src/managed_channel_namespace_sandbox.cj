package agent_host_runtime

import agent_domain.*
import std.collection.*

// Only the fixed trusted native launcher uses this projection after borrowing
// actual owned user/net/pid namespace descriptors. It retains all filesystem,
// environment, other namespace and resource arguments of the original plan.
// Payload arguments and option values are never treated as bwrap options.
func hostManagedNamespaceSandboxArguments(arguments: Array<String>, hostNetwork:Bool): Result<Array<String>> {
    try {
        let output=ArrayList<String>();let removed=HashSet<String>();var index: Int64=0
        var ended=false
        while(index<arguments.size){
            let option=arguments[index]
            if(option=="--"){
                output.add(all:arguments[index..]);ended=true;break
            }
            if(["--unshare-user","--unshare-pid","--unshare-net","--disable-userns"].contains(option)){
                if(removed.contains(option)){throw IllegalArgumentException("duplicate namespace option")}
                removed.add(option)
                if(option=="--disable-userns"){output.add("--assert-userns-disabled")}
                index+=1;continue
            }
            let arity=if(["--die-with-parent","--unshare-ipc","--unshare-uts","--unshare-cgroup-try","--clearenv"].contains(option)){0}
                else if(["--dir","--proc","--dev","--tmpfs","--chdir"].contains(option)){1}
                else if(["--ro-bind","--ro-bind-try","--bind","--setenv"].contains(option)){2}
                else{throw IllegalArgumentException("unknown sandbox option")}
            if(index+arity>=arguments.size){throw IllegalArgumentException("incomplete sandbox option")}
            output.add(all:arguments[index..index+arity+1]);index+=arity+1
        }
        if(!ended || !removed.contains("--unshare-user") || !removed.contains("--unshare-pid") ||
            !removed.contains("--disable-userns") || removed.contains("--unshare-net")==hostNetwork ||
            removed.size!=(if(hostNetwork){3}else{4}) || output.isEmpty()){throw IllegalArgumentException("missing isolated namespace profile")}
        Result.Ok(output.toArray())
    }catch(_: Exception){hostLifecycleLeaseError("managed_channel.actual_namespace_profile_invalid")}
}
