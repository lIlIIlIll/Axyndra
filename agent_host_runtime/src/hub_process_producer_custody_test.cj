package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_extension_runtime.nativeControlMetadataUsage113
import agent_domain.LogicalJsonOwnerReservation as HubProcessTestPaidOwner
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ActualHubProcessProducerCustodyTests {
    @TestCase
    func actualTwoBackgroundFramesRemainPaidUntilEachFutureReturned():Unit {
        let root=reserveNativeControlMetadata(1048576)
        let meter=HostPaidValueProjection151(root)
        try { actualTwoProducerHelper(root,meter) }
        finally { meter.closeUnpublished151() }
    }
    private func actualTwoProducerHelper(root:HubProcessTestPaidOwner,
        meter:HostPaidValueProjection151):Unit {
        let registry=HostHubProcessProducerCustody.prepare(meter)
        let before=root.retainedCustodyUsage113()
        let first=registry.reserveProducerBeforeClosure()
        let second=registry.reserveProducerBeforeClosure()
        let after=root.retainedCustodyUsage113()
        @Expect(after[0],before[0]+2*(65536+1024))
        @Expect(after[2],before[2]+2)
        let firstEntered=AtomicBool(false);let secondEntered=AtomicBool(false)
        let releaseFirst=AtomicBool(false);let releaseSecond=AtomicBool(false)
        let firstCalls=AtomicInt64(0);let secondCalls=AtomicInt64(0)
        // The original caller already paid these DATA cells. Each actual
        // closure is constructed only after its producer ticket is registered.
        first.start({=>firstCalls.fetchAdd(1);firstEntered.store(true)
            while(!releaseFirst.load()){sleep(Duration.millisecond)}})
        second.start({=>secondCalls.fetchAdd(1);secondEntered.store(true)
            while(!releaseSecond.load()){sleep(Duration.millisecond)}})
        try {
            let enteredUntil=MonoTime.now()+Duration.second*5
            while((!firstEntered.load() || !secondEntered.load()) && MonoTime.now()<enteredUntil){
                sleep(Duration.millisecond)}
            @Expect(firstEntered.load());@Expect(secondEntered.load())
            @Expect(firstCalls.load(),1);@Expect(secondCalls.load(),1)
            @Expect(!first.collectReturned());@Expect(!second.collectReturned())
            @Expect(!first.retireObservedReturn());@Expect(!second.retireObservedReturn())
            @Expect(root.retainedCustodyUsage113()[0],after[0])
            releaseFirst.store(true)
            @Expect(waitActualHubProducer(first))
            @Expect(first.retireObservedReturn())
            @Expect(root.retainedCustodyUsage113()[0],after[0]-(65536+1024))
            @Expect(!second.collectReturned());@Expect(!second.retireObservedReturn())
            @Expect(secondCalls.load(),1)
            releaseSecond.store(true)
            @Expect(waitActualHubProducer(second));@Expect(second.retireObservedReturn())
            @Expect(root.retainedCustodyUsage113()[0],before[0])
            @Expect(root.retainedCustodyUsage113()[2],before[2])
        } finally {
            releaseFirst.store(true);releaseSecond.store(true)
            let _=waitActualHubProducer(first);let _=waitActualHubProducer(second)
            let _=first.retireObservedReturn();let _=second.retireObservedReturn()
        }
        // This verifies actual task-share ledger retirement only. It does
        // not claim physical process exit, scheduler closure reclamation,
        // whole Native/Root zero, SQL commit or launch authorization.
    }

    @TestCase
    func originalAggregatePressureRefusesProducerBeforeConstructingItsAction():Unit {
        let root=reserveNativeControlMetadata(1048576)
        let meter=HostPaidValueProjection151(root)
        let registry=HostHubProcessProducerCustody.prepare(meter)
        let pressure=root.deriveRetainedLease()
        try {
            // One independent phase in the original bank, not another pool.
            // Fill its actual remaining aggregate capacity exactly, including
            // the already installed caller/registry share and 1KiB overhead.
            let before=nativeControlMetadataUsage113()
            let available=134217728-before[1]
            let own=root.retainedCustodyUsage113()
            pressure.ensureRetainedPeak(available+own[1]-own[0])
            let calls=AtomicInt64(0)
            var refused=false
            try {
                let producer=registry.reserveProducerBeforeClosure()
                producer.start({=>calls.fetchAdd(1)})
            } catch(_:LogicalJsonPayloadError){refused=true}
            @Expect(refused);@Expect(calls.load(),0)
            @Expect(registry.countRegistered(),0)
        } finally { pressure.close();meter.closeUnpublished151() }
    }
}

private func waitActualHubProducer(value:HostHubProcessProducerCell):Bool {
    let until=MonoTime.now()+Duration.second*5
    while(MonoTime.now()<until){
        if(value.collectReturned()){return true}
        sleep(Duration.millisecond)}
    value.collectReturned()
}
