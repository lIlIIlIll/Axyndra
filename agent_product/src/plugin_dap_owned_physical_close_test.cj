package agent_product

import agent_domain.*
import agent_host_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginDapOwnedPhysicalCloseTests {
    @TestCase
    func realNativeDescriptorCustodyReturnsFirstCloseErrorAndRetriesSameOwner():Unit{
        let probe=OwnedDapCleanupProbe();let f=OwnedDapProductFixture()
        let thread="dap-owned-native-close-first-error"
        let entered=AtomicBool(false);let release=AtomicBool(false)
        try{
            lifecycleTestRequire(f.actual.product.observeManagedCleanupForFixture(probe))
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"actual-native-custody").isError)
            @Expect(probe.count(),1);let original=probe.at(0)
            let borrowing=spawn{original.withPhysicalCustodyBorrow({=>
                entered.store(true);let until=MonoTime.now()+Duration.second*15
                while(!release.load() && MonoTime.now()<until){sleep(Duration.millisecond*2)}
                if(!release.load()){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"fixture.physical_borrow_timeout","actual native custody borrower was not released"))}
                Result<Unit>.Ok(())})}
            try{
                let until=MonoTime.now()+Duration.second*3
                while(!entered.load() && MonoTime.now()<until){sleep(Duration.millisecond*2)}
                @Expect(entered.load());@Expect(original.snapshot().borrowed,1)
                @Expect(f.actual.product.stopPluginService(SessionId(thread),productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),"stdio").isError())
                let failed=MonoTime.now()+Duration.second*5
                while(!original.snapshot().physicalCloseHadError && MonoTime.now()<failed){sleep(Duration.millisecond*2)}
                let debt=original.snapshot()
                // This flag comes ONLY from the original real physical
                // processes.closeChannelOperation returning Result.Err. The
                // actual native stdout FD is still under its original ioLock;
                // its normal 2s close deadline cannot claim physical release.
                @Expect(debt.physicalCloseHadError && debt.physicalCloseErrorRetained && debt.physicalClosePendingError)
                @Expect(!debt.processCloseAcknowledged)
                @Expect(debt.paymentRetained && !debt.released && debt.namespaceDescriptorsRetained)
                @Expect(!f.released());@Expect(!f.visible(thread))
                release.store(true);lifecycleTestRequire(borrowing.get())
                let finished=MonoTime.now()+Duration.second*5
                while(!original.snapshot().released && MonoTime.now()<finished){sleep(Duration.millisecond*2)}
                let completed=original.snapshot()
                @Expect(completed.physicalCloseHadError);@Expect(!completed.physicalCloseErrorRetained)
                @Expect(completed.released && completed.processCloseAcknowledged && completed.pumpsJoined && completed.ioDrained)
                @Expect(!completed.paymentRetained && !completed.namespaceDescriptorsRetained)
                @Expect(completed.borrowed,0);@Expect(probe.count(),1)
                f.stop(thread)
            }finally{release.store(true);let _=borrowing.get()}
        }finally{release.store(true);f.close()}
    }
}
