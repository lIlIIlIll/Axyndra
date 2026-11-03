package agent_host_runtime

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Actual filesystem visibility primitives only. No Source, approval,
// Registry installation, process or Hosted lifecycle ACK is manufactured.
@Test
class ManagedChannelActualPathVisibilityControls {
    @TestCase
    func configuredSubdirectoryDoesNotHideTheActualMountedWorkspaceRoot():Unit {
        let root=Directory.createTemp("/tmp").toString()
        try {
            let workspace=root+"/workspace";Directory.create(workspace);Directory.create(workspace+"/operator-sub")
            let actualRoot=hostLifecycleDirectory(workspace)
            let configuredCwd=hostLifecycleDirectory(workspace+"/operator-sub")
            let request=ProcessRequest("/usr/bin/true",workingDirectory:configuredCwd)
            @Expect(hostManagedChannelPathVisible(request,actualRoot,actualRoot,true),true)
            @Expect(hostManagedChannelPathVisible(request,actualRoot,configuredCwd,true),true)
            @Expect(hostManagedChannelPathVisible(request,actualRoot,root,true),false)
            @Expect(hostManagedChannelPathVisible(request,actualRoot,workspace+"-other",true),false)
        } finally { remove(root,recursive:true) }
    }
    @TestCase
    func isolatedFilesystemRootStillRequiresAnExplicitOutsideReadOnlyMount():Unit {
        let root=Directory.createTemp("/tmp").toString()
        try {
            let workspace=root+"/workspace";let isolated=root+"/package";let mount=root+"/mount"
            Directory.create(workspace);Directory.create(isolated);Directory.create(mount)
            let actualRoot=hostLifecycleDirectory(workspace);let actualIsolated=hostLifecycleDirectory(isolated)
            let actualMount=hostLifecycleDirectory(mount)
            let request=ProcessRequest("/usr/bin/true",workingDirectory:actualIsolated,
                sandboxMode:ProcessSandboxMode.IsolatedReadOnly,filesystemRoot:actualIsolated,readOnlyMounts:[actualMount])
            @Expect(hostManagedChannelPathVisible(request,actualRoot,actualIsolated,true),true)
            @Expect(hostManagedChannelPathVisible(request,actualRoot,actualRoot,true),false)
            @Expect(hostManagedChannelPathVisible(request,actualRoot,actualMount,true),true)
        } finally { remove(root,recursive:true) }
    }
}
