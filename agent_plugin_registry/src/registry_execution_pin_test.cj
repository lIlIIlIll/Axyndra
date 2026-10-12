package agent_plugin_registry

import std.fs.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// Diagnostic only: existing native path stat, no new Source gate or C API.
foreign func axyndra_read_view_probe(path:CString,output:CPointer<UInt8>,capacity:Int64):Int32
private func registryRewriteIdentity339a(path:String):String{
    unsafe{
        let name=LibC.mallocCString(path);let buffer=LibC.malloc<UInt8>(count:256)
        try{
            let code=axyndra_read_view_probe(name,buffer,256)
            if(code!=0){return "probe-error:"+code.toString()}
            CString(buffer).toString()
        }finally{LibC.free(buffer);LibC.free(name)}
    }
}
private func registryRewriteBytesEqual339a(left:Array<Byte>,right:Array<Byte>):Bool{
    if(left.size!=right.size){return false}
    for(index in 0..left.size){if(left[index]!=right[index]){return false}}
    true
}
private func pinRequire<T>(value:PluginImportResult<T>):T {
    match(value){case PluginImportResult.Ok(selected)=>selected
        case PluginImportResult.Err(error)=>throw IllegalStateException(error.code+": "+error.message)}
}
private func pinCode<T>(value:PluginImportResult<T>):String {
    match(value){case PluginImportResult.Ok(_)=>"unexpected-success";case PluginImportResult.Err(error)=>error.code}
}
private func pinRequire<T>(value:PluginRegistryResult<T>):T {
    match(value){case PluginRegistryResult.Ok(selected)=>selected
        case PluginRegistryResult.Err(error)=>throw registryTestOwnedFailure78(error)}
}
private func pinCode<T>(value:PluginRegistryResult<T>):String {
    match(value){case PluginRegistryResult.Ok(_)=>"unexpected-success"
        case PluginRegistryResult.Err(error)=>registryTestOwnedCode78(error)}
}
private class RegistryPinFixture {
    let root:String
    let registry:PluginRegistry
    let record:ProductPluginRecord
    private let peers=ArrayList<PluginRegistry>()
    init(){
        let path=Directory.createTemp("/tmp").toString();root=path
        let actual=PluginRegistry(path+"/settings",path);registry=actual
        try {
        let imported=registryFixtureRecord(actual.importLocal(registryFixturePackage(path,"1.0.0")))
        record=registryFixtureRecord(actual.setEnabled("pi:minimal-fixture",true)); imported.close()
        }catch(error:Exception){actual.close();throw error}
    }
    func pin():PluginRegistryExecutionPin {pinRequire(registry.captureExecutionPin(record))}
    func peer():PluginRegistry {
        let result=PluginRegistry(root+"/settings",root);peers.add(result);result
    }
    func close():Unit {
        for(peer in peers){peer.close()};peers.clear()
        record.close(); try{registry.close()}finally{remove(root,recursive:true)}
    }
}

@Test
class RegistryExecutionPinTests {
    @TestCase
    func secondRealRegistryDisableInvalidatesHeldPinAndCannotBeRearmedByRecordData():Unit {
        let f=RegistryPinFixture();let pin=f.pin()
        try{@Expect(pin.current().isOk())
            let _=pinRequire(f.peer().setEnabled("pi:minimal-fixture",false))
            @Expect(pinCode(pin.current()),"plugin.registry_execution_stale")
            @Expect(!f.registry.captureExecutionPin(f.record).isOk())
            @Expect(pinCode(pin.current()),"plugin.registry_execution_stale")
        }finally{pin.close();f.close()}
    }
    @TestCase
    func disableEnableAbaKeepsOldGenerationRevokedEvenWhenFinalEnabledBytesMatch():Unit {
        let f=RegistryPinFixture();let pin=f.pin()
        try{let other=f.peer();let _=pinRequire(other.setEnabled("pi:minimal-fixture",false))
            let enabled=pinRequire(other.setEnabled("pi:minimal-fixture",true))
            @Expect(pinCode(pin.current()),"plugin.registry_execution_stale")
            let replacement=pinRequire(f.registry.captureExecutionPin(enabled))
            try{@Expect(replacement.current().isOk());@Expect(!pin.current().isOk())}finally{replacement.close()}
        }finally{pin.close();f.close()}
    }
    @TestCase
    func activeShortLeaseBlocksActualWriterAndClosingPinDoesNotDropThatLease():Unit {
        let f=RegistryPinFixture();let pin=f.pin();let lease=pinRequire(pin.enter())
        try{pin.close()
            @Expect(pinCode(f.peer().setEnabled("pi:minimal-fixture",false)),"plugin.registry_busy")
            @Expect(!pin.current().isOk())
            lease.close();lease.close()
            @Expect(!pinRequire(f.peer().setEnabled("pi:minimal-fixture",false)).enabled)
        }finally{lease.close();pin.close();f.close()}
    }
    @TestCase
    func writerBusyDoesNotPermanentlyRevokeAnUnchangedPin():Unit {
        let f=RegistryPinFixture();let pin=f.pin()
        try{let writer=PluginRegistryWriterFence(f.root+"/settings",f.root)
            try{@Expect(pinCode(pin.current()),"plugin.registry_busy")}finally{writer.close()}
            @Expect(pin.current().isOk())
        }finally{pin.close();f.close()}
    }
    @TestCase
    func exactContentAndRetainedInodeRejectUnchangedLengthRewriteAndPathReplacement():Unit {
        for(replacePath in [false,true]){let f=RegistryPinFixture()
            let path=f.root+"/settings/plugins/lock.jsonl"
            let beforePin339a=registryRewriteIdentity339a(path);let pin=f.pin()
            try{let original=File.readFrom(path);let afterPin339a=registryRewriteIdentity339a(path)
                if(replacePath){rename(path,to:path+".old");File.writeTo(path,original)}
                else{File.writeTo(path,original)}
                let afterRewrite339a=registryRewriteIdentity339a(path)
                let equal339a=registryRewriteBytesEqual339a(File.readFrom(path),original)
                let code339a=pinCode(pin.current())
                println("registry-rewrite339a replacePath="+replacePath.toString()+
                    " beforePin="+beforePin339a+" afterPin="+afterPin339a+
                    " afterRewrite="+afterRewrite339a+" completeBytesEqual="+equal339a.toString()+" current="+code339a)
                @Expect(code339a,"plugin.registry_execution_stale")
            }finally{pin.close();f.close()}}
    }
    @TestCase
    func workspacePublicationMarkerAndGrantChangeNeverAuthorizeOldMountedGeneration():Unit {
        for(marker in [false,true]){let f=RegistryPinFixture();let pin=f.pin()
            try{if(marker){let writer=PluginRegistryWriterFence(f.root+"/settings",f.root)
                    try{writer.publication(true)}finally{writer.close()}}
                else{let _=pinRequire(f.peer().importLocal(registryFixturePackage(f.root,"2.0.0"),PluginInstallScope.Workspace))}
                @Expect(!pin.current().isOk())
                @Expect(!pin.current().isOk())
            }finally{pin.close();f.close()}}
    }
    @TestCase
    func absentWorkspaceMetadataBecomingPresentRevokesUserPinConservatively():Unit {
        let f=RegistryPinFixture();let pin=f.pin()
        try{@Expect(!exists(Path(f.root+"/.axyndra/plugins/lock.jsonl")))
            let _=pinRequire(f.peer().importLocal(registryFixturePackage(f.root,"2.0.0"),PluginInstallScope.Workspace))
            @Expect(pinCode(pin.current()),"plugin.registry_execution_stale")
        }finally{pin.close();f.close()}
    }
    @TestCase
    func heldMetadataRejectsSymlinkSubstitutionAndDoesNotFollowExternalContent():Unit {
        let f=RegistryPinFixture();let pin=f.pin()
        try{let path=f.root+"/settings/plugins/lock.jsonl";let original=File.readFrom(path)
            let external=f.root+"/outside";File.writeTo(external,original)
            remove(path);SymbolicLink.create(path,to:external)
            @Expect(pinCode(pin.current()),"plugin.registry_execution_stale")
            @Expect(File.readFrom(external),original)
        }finally{pin.close();f.close()}
    }
}
