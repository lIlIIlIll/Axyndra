package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.fs.*
import yjson.*
import yjson_support.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ReadViewParameterContextTests {
    @TestCase
    func actualSubdirectoryAndRootKeepTheirExactRelativeWorkingDirectory(): Unit {
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "/tmp/workspace/project").value().getOrThrow(), "project")
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "/tmp/workspace").value().getOrThrow(), ".")
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "").value().getOrThrow(), ".")
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace/", "/tmp/workspace/project/.").value().getOrThrow(), "project")
    }
    @TestCase
    func siblingPrefixRelativeAndEscapingActualContextsRefuse(): Unit {
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "/tmp/workspace-other").isError())
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "/tmp/workspace/../other").isError())
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "project").isError())
        @Expect(hostReadViewRelativeWorkingDirectory("/tmp/workspace", "/tmp/workspace/a\u{0000}").isError())
    }
    @TestCase
    func relativeProtectedRootsKeepWorkspaceReadableAndActualStateSecret217(): Unit {
        let relative = "../home"
        let protectedFile = hostResolveThroughExistingAncestor(Path(relative)).join("private.txt").toString()
        let ordinaryFile = "/home/example-user/workspace/fixture.txt"
        for (state in [false, true]) {
            let host = HostJavaScriptPluginHost({ root => HostLocalReadTargetInspector(root) },
                settingsRoot: if (state) { "" } else { relative },
                readViewStateRoot: if (state) { relative } else { "" })
            try {
                @Expect(host.readViewSensitive(ordinaryFile), false)
                @Expect(host.readViewSensitive(protectedFile))
                if (state) { @Expect(host.contextReadHardSensitive(protectedFile)) }
                @Expect(host.contextReadHardSensitive("/home/example-user/workspace/.env"))
                @Expect(host.contextReadHardSensitive("/home/example-user/workspace/credentials/token"))
            } finally { host.close().value().getOrThrow() }
        }
    }
}


// These tests exercise metadata selection/classification and native no-follow
// probing only. They create no admitted Operation/Source/approval/Receipt and
// never claim that a descriptive binding is permission for a worker.
class ReadViewContextMetadataFixture {
    let root:String
    let workspace:String
    let settings:String
    let host:HostJavaScriptPluginHost
    let namespace="axyndra:cwd-metadata-contract"
    let packageDigest="sha256:"+modelPolicySha256Text("metadata-only package identity")
    init(){
        let directory=Directory.createTemp("/tmp").toString();root=directory
        workspace=directory+"/workspace";settings=directory+"/settings"
        Directory.create(workspace);Directory.create(workspace+"/sub")
        Directory.create(settings+"/plugins",recursive:true)
        host=HostJavaScriptPluginHost({path=>HostLocalReadTargetInspector(path)},settingsRoot:settings)
    }
    func configure(optin:Bool):HostPluginHttpConfiguration {
        let grant=objectValue([ValueField("kind",textValue("tool")),ValueField("name",textValue("inspect")),
            ValueField("effect",textValue("read_only")),ValueField("services",listValue([textValue("process.readview")]))])
        let plugin=objectValue([ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(packageDigest)),
            ValueField("configuration",objectValue([])),ValueField("requests",listValue([])),ValueField("credentials",listValue([])),
            ValueField("tool_read_grants",listValue([grant])),ValueField("read_view_parameter_references",listValue([textValue("inspect")]))])
        if(optin){plugin.put("read_view_parameter_contexts",listValue([textValue("inspect")]))}
        File.writeTo(settings+"/plugins/services.json",stringifyUnifiedJson(objectValue([
            ValueField("version",integerValue(1)),ValueField("plugins",listValue([plugin]))])).toArray())
        match(loadHostPluginHttpConfiguration(settings,namespace,packageDigest)){
            case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
    }
    func context(cwd:String,token:CancellationToken,caps!:CapabilitySet=CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)])):ToolInvocationContext {
        ToolInvocationContext(RunId("metadata-only-no-root"),SessionId("metadata-only-thread"),caps,cancellation:token,
            toolContext:ToolContextDescriptor(workspaceRoot:workspace,cwd:cwd))}
    func close():Unit {host.close().value().getOrThrow();remove(root,recursive:true)}
}

@Test
class ReadViewContextMetadataBoundaryTests {
    @TestCase
    func defaultDoesNotReadCwdOrAppendMetadataAndOptinUsesActualContainedDirectory():Unit {
        let f=ReadViewContextMetadataFixture();let cancellation=CancellationSource()
        try{let binding=objectValue([ValueField("call_id",textValue("descriptive-only"))])
            let original=hostReadViewContextBinding(f.host,f.configure(false),"inspect",
                f.context(f.root+"/outside",cancellation.token),binding).value().getOrThrow()
            @Expect(refEq(original,binding));@Expect(original.field("working_directory").isNone())
            let context=f.context(f.workspace+"/sub/.",cancellation.token)
            let selected=hostReadViewContextBinding(f.host,f.configure(true),"inspect",context,binding).value().getOrThrow()
            @Expect(selected.field("working_directory").getOrThrow().text,"sub")
            @Expect(binding.field("working_directory").isNone());@Expect(context.capabilities.values.size,1)
            @Expect(!context.capabilities.allows(CapabilityKind.ExtensionInvoke));@Expect(!context.capabilities.allows(CapabilityKind.WorkspaceWrite))
        }finally{cancellation.close();f.close()}
    }
    @TestCase
    func actualOutsideSymlinkAndIntermediateSymlinkNeverBecomeCwdMetadata():Unit {
        let f=ReadViewContextMetadataFixture();let cancellation=CancellationSource()
        try{Directory.create(f.root+"/external");Directory.create(f.root+"/external/sub")
            SymbolicLink.create(f.workspace+"/escape",to:f.root+"/external")
            SymbolicLink.create(f.workspace+"/internal-link",to:f.workspace+"/sub")
            let configuration=f.configure(true);let binding=objectValue([])
            for(cwd in [f.root+"/external",f.workspace+"/escape",f.workspace+"/escape/sub",f.workspace+"/internal-link"]){
                @Expect(hostReadViewContextBinding(f.host,configuration,"inspect",f.context(cwd,cancellation.token),binding).isError())}
            @Expect(binding.fields.size,0)
        }finally{cancellation.close();f.close()}
    }
    @TestCase
    func currentConfigChangeAndCancelledActualTokenRefuseMetadataWithoutChangingBinding():Unit {
        let f=ReadViewContextMetadataFixture();let cancellation=CancellationSource()
        try{let configuration=f.configure(true);let path=f.settings+"/plugins/services.json"
            let original=String.fromUtf8(File.readFrom(path));let binding=objectValue([])
            File.writeTo(path,(original+"\n").toArray())
            @Expect(hostReadViewContextBinding(f.host,configuration,"inspect",f.context(f.workspace,cancellation.token),binding).isError())
            File.writeTo(path,original.toArray());let _=cancellation.cancel()
            @Expect(hostReadViewContextBinding(f.host,configuration,"inspect",f.context(f.workspace,cancellation.token),binding).isError())
            @Expect(binding.fields.size,0)
        }finally{cancellation.close();f.close()}
    }
    @TestCase
    func NarrowReadCapabilityCannotBeWidenedByMetadataOptinOrAuthoredRelativePath():Unit {
        let f=ReadViewContextMetadataFixture();let cancellation=CancellationSource()
        try{let configuration=f.configure(true);let binding=objectValue([])
            let narrow=CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead,resource:f.workspace+"/other")])
            @Expect(hostReadViewContextBinding(f.host,configuration,"inspect",f.context(f.workspace+"/sub",cancellation.token,caps:narrow),binding).isError())
            @Expect(hostReadViewContextBinding(f.host,configuration,"inspect",f.context("sub",cancellation.token),binding).isError())
            @Expect(binding.fields.size,0);@Expect(narrow.values.size,1)
        }finally{cancellation.close();f.close()}
    }
}
