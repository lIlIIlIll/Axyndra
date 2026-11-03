package process4cj

import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Actual Linux raw process/descriptor tests. Host policy, Derived Source,
// Registry and Store receipts are verified separately by the actual bridge.
@Test
class OwnedNamespaceCheckedCloseControls {
    @TestCase
    func sameActualHostNetworkCanBePreservedAndClosedAfterAdapterExit():Unit {
        let arguments=ArrayList<String>()
        for(value in namespaceFixtureArguments(false,"/usr/bin/python3",
            ["-u","-c","import sys; print('READY',flush=True); sys.stdin.buffer.read()"])
            where value!="--unshare-net"){arguments.add(value)}
        let service=startProcess(ProcessCommand("/usr/bin/bwrap",arguments:arguments.toArray()))
        try{
            @Expect(readLineBounded(service.stdout,64).getOrThrow(),"READY")
            let owned=service.borrowSandboxNamespaces()
            try{
                let child=startProcessInSandboxNamespaces(ProcessCommand("/usr/bin/bwrap",
                    arguments:namespaceFixtureArguments(true,"/bin/sleep",["30"])),owned)
                try{
                    var observed:?ProcessSandboxPayloadIdentity=None<ProcessSandboxPayloadIdentity>
                    let deadline=MonoTime.now()+Duration.second*2
                    while(observed.isNone() && MonoTime.now()<deadline){
                        try{observed=Some(child.sandboxPayloadIdentity(owned,"/bin/sleep"))}
                        catch(_:ProcessError){sleep(Duration.millisecond*5)}}
                    @Expect(observed.isSome(),true)
                    @Expect(observed.getOrThrow().namespacePid>2,true)
                    @Expect(child.close(),true)
                }finally{let _=child.close()}
                @Expect(service.close(),true)
                @Expect(owned.current(),false)
                // Cleanup ACK does not require the adapter or its source to
                // remain current, and success is idempotent for this object.
                @Expect(owned.acknowledgeClose(),true)
                @Expect(owned.acknowledgeClose(),true)
            }finally{@Expect(owned.acknowledgeClose(),true)}
        }finally{let _=service.close()}
    }
}
