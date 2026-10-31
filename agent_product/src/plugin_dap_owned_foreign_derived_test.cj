package agent_product

import agent_domain.*
import agent_host_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// This observer parks only after real inventory adoption and physical attach.
// It holds no Host/Store/owner lock and receives no Source/Prepared/FD authority.
class OwnedDapExecutingScopeWindow <: HostManagedChannelCleanupObserver {
    private let lock=Mutex()
    private var value:?HostManagedChannelCleanupBorrow=None<HostManagedChannelCleanupBorrow>
    let entered=AtomicBool(false)
    let released=AtomicBool(false)
    public func observe(borrow:HostManagedChannelCleanupBorrow):Unit{
        lock.lock();try{
            if(value.isSome()){throw IllegalStateException("one actual adapter window required")}
            value=Some(borrow)
        }finally{lock.unlock()}
        entered.store(true)
        let until=MonoTime.now()+Duration.second*10
        while(!released.load() && MonoTime.now()<until){sleep(Duration.millisecond*2)}
        if(!released.load()){throw IllegalStateException("bounded actual executing window was not released")}
    }
    func actual():HostManagedChannelCleanupBorrow{lock.lock();try{value.getOrThrow()}finally{lock.unlock()}}
}

@Test
class PluginDapOwnedForeignDerivedTests {
    @TestCase
    func twoCurrentActualDerivedSpawnsCannotBorrowEachOthersParentRoot():Unit{
        let leftWindow=OwnedDapExecutingScopeWindow();let rightWindow=OwnedDapExecutingScopeWindow()
        let left=OwnedDapProductFixture();var right:?OwnedDapProductFixture=None<OwnedDapProductFixture>
        try{
            let openedRight=OwnedDapProductFixture();right=Some(openedRight)
            lifecycleTestRequire(left.actual.product.observeManagedCleanupForFixture(leftWindow))
            lifecycleTestRequire(openedRight.actual.product.observeManagedCleanupForFixture(rightWindow))
            @Expect(!left.start("actual-left-scope").isError);@Expect(!openedRight.start("actual-right-scope").isError)
            let leftExecution=spawn{left.launch("actual-left-scope","actual-left-derived")}
            let rightExecution=spawn{openedRight.launch("actual-right-scope","actual-right-derived")}
            try{
                let until=MonoTime.now()+Duration.second*8
                while((!leftWindow.entered.load() || !rightWindow.entered.load()) && MonoTime.now()<until){sleep(Duration.millisecond*2)}
                @Expect(leftWindow.entered.load() && rightWindow.entered.load())
                let observed=MonoTime.now()+Duration.second
                while((left.actual.commandCount("adapter-start")!=1 || openedRight.actual.commandCount("adapter-start")!=1) && MonoTime.now()<observed){sleep(Duration.millisecond*2)}
                // Both original grants must independently pass actual current
                // Source and full Store Executing before the production
                // prepare(A parent, B Derived child) rejection is observable.
                let rejected=lifecycleTestRequire(leftWindow.actual().compareExecutingScope(rightWindow.actual()))
                @Expect(!rejected.sameRoot);@Expect(!rejected.sameRun);@Expect(!rejected.sameThread)
                @Expect(rejected.crossEffectRejected)
                @Expect(leftWindow.actual().snapshot().paymentRetained)
                @Expect(rightWindow.actual().snapshot().paymentRetained)
                @Expect(left.actual.commandCount("adapter-start"),1)
                @Expect(openedRight.actual.commandCount("adapter-start"),1)
                @Expect(left.actual.commandCount("initialize"),0);@Expect(openedRight.actual.commandCount("initialize"),0)
                leftWindow.released.store(true);rightWindow.released.store(true)
                @Expect(!leftExecution.get().isError);@Expect(!rightExecution.get().isError)
                @Expect(left.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1)
                @Expect(openedRight.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1)
                @Expect(left.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),4)
                @Expect(openedRight.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),4)
                @Expect(left.actual.commandCount("adapter-start"),1)
                @Expect(openedRight.actual.commandCount("adapter-start"),1)
            }finally{
                leftWindow.released.store(true);rightWindow.released.store(true)
                let _=leftExecution.get();let _=rightExecution.get()
            }
            left.stop("actual-left-scope");openedRight.stop("actual-right-scope")
        }finally{
            leftWindow.released.store(true);rightWindow.released.store(true)
            // If an impossible foreign prepare produced a real owner, its
            // debt is in the original left lease and must ACK before the
            // borrowed original right payment can be retired.
            try{left.close()}finally{match(right){case Some(value)=>value.close();case None=>()}}
        }
    }
}
