package agent_host_runtime

import agent_domain.*
import sandbox4cj.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

func managedNamespaceControlPlan(root:String,hostNetwork:Bool):Array<String>{
    let sandbox=WorkspaceSandbox(WorkspaceSandboxPolicy(root,
        filesystem:FilesystemIsolationMode.WorkspaceReadOnly,process:ProcessIsolationMode.Isolated,
        network:if(hostNetwork){NetworkIsolationMode.Allowed}else{NetworkIsolationMode.Denied},
        environment:EnvironmentFilter(allowlist:["VISIBLE"]),
        resources:SandboxResourceLimits(openFiles:64,processes:8),
        bubblewrapExecutable:"/usr/bin/true",timeoutExecutable:"/usr/bin/true"))
    match(sandbox.plan(WorkspaceSandboxCommand("/usr/bin/true",workingDirectory:root,
        arguments:["literal","--unshare-user","--disable-userns"],
        environment:[SandboxEnvironmentEntry("VISIBLE","--unshare-net")]))){
        case SandboxResult.Ok(value)=>value.sandboxArguments
        case SandboxResult.Err(error)=>throw error}
}
func managedNamespaceControlPayload(arguments:Array<String>):Int64{
    for(index in 0..arguments.size where arguments[index]=="--"){return index+1}
    throw IllegalStateException("actual sandbox plan has no payload separator")
}
func managedNamespaceControlContains(arguments:Array<String>,value:String):Bool{
    for(entry in arguments where entry==value){return true}
    false
}

// Use actual WorkspaceSandbox.plan output. These tests cover only the
// namespace projection primitive; they do not mint an actual Host grant,
// Derived Source, approval, Store Known receipt or physical cleanup ACK.
@Test
class ManagedChannelNamespaceSandboxControls {
    @TestCase
    func deniedPlanKeepsActualFilesystemLimitsEnvironmentAndLiteralPayload():Unit{
        let directory=Directory.createTemp("/tmp").toString()
        try{
            let root=hostLifecycleDirectory(directory)
            let original=managedNamespaceControlPlan(root,false)
            let projected=hostManagedNamespaceSandboxArguments(original,false).value().getOrThrow()
            @Expect(managedNamespaceControlContains(projected,"--ro-bind"),true)
            @Expect(managedNamespaceControlContains(projected,"--clearenv"),true)
            @Expect(managedNamespaceControlContains(projected,"--assert-userns-disabled"),true)
            @Expect(managedNamespaceControlContains(projected,"--nofile=64"),true)
            @Expect(managedNamespaceControlContains(projected,root),true)
            for(index in 0..projected.size where projected[index]=="VISIBLE"){
                @Expect(projected[index+1],"--unshare-net")}
            let before=managedNamespaceControlPayload(original);let after=managedNamespaceControlPayload(projected)
            @Expect(projected.size-after,original.size-before)
            for(index in 0..original.size-before){@Expect(projected[after+index],original[before+index])}
        }finally{remove(directory,recursive:true)}
    }
    @TestCase
    func hostNetworkProfileMustMatchTheActualSelectedSandboxPlan():Unit{
        let directory=Directory.createTemp("/tmp").toString()
        try{
            let root=hostLifecycleDirectory(directory)
            let allowed=managedNamespaceControlPlan(root,true);let denied=managedNamespaceControlPlan(root,false)
            @Expect(hostManagedNamespaceSandboxArguments(allowed,true).isOk(),true)
            @Expect(hostManagedNamespaceSandboxArguments(allowed,false).isError(),true)
            @Expect(hostManagedNamespaceSandboxArguments(denied,true).isError(),true)
        }finally{remove(directory,recursive:true)}
    }
    @TestCase
    func unknownOrDuplicatedNamespaceOptionRejectsTheWholeProjection():Unit{
        let directory=Directory.createTemp("/tmp").toString()
        try{
            let original=managedNamespaceControlPlan(hostLifecycleDirectory(directory),false)
            @Expect(hostManagedNamespaceSandboxArguments(managedNamespaceControlPrefix110("--share-net",original),false).isError(),true)
            @Expect(hostManagedNamespaceSandboxArguments(managedNamespaceControlPrefix110("--unshare-user",original),false).isError(),true)
        }finally{remove(directory,recursive:true)}
    }
    @TestCase
    func sharedPidPlanCannotStandInForTheActualIsolatedAdapterProfile():Unit{
        let directory=Directory.createTemp("/tmp").toString()
        try{
            let sandbox=WorkspaceSandbox(WorkspaceSandboxPolicy(hostLifecycleDirectory(directory),
                process:ProcessIsolationMode.Shared,bubblewrapExecutable:"/usr/bin/true",timeoutExecutable:"/usr/bin/true"))
            let plan=match(sandbox.plan(WorkspaceSandboxCommand("/usr/bin/true"))){
                case SandboxResult.Ok(value)=>value;case SandboxResult.Err(error)=>throw error}
            @Expect(hostManagedNamespaceSandboxArguments(plan.sandboxArguments,false).isError(),true)
        }finally{remove(directory,recursive:true)}
    }
}

private func managedNamespaceControlPrefix110(prefix:String,original:Array<String>):Array<String>{
    Array<String>(original.size+1,{index=>if(index==0){prefix}else{original[index-1]}})
}
