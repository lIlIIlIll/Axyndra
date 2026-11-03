package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.{reserveNativeControlMetadata, nativeControlMetadataUsage113}
import std.unittest.*
import std.unittest.testmacro.*

// These two controls exercise the exact production DATA holder with the real
// Native bank. They do not replace an actual process/Future/Registry test.
@Test
class HostRegistryMountData159Tests {
    @TestCase
    func launchReturnAloneKeepsDispatchShareAndTheOriginalPhysicalFloor159(): Unit {
        let before = nativeControlMetadataUsage113()
        let root = reserveNativeControlMetadata(65536)
        try {
            let payment = root.deriveRetainedLease()
            let data = hostRetainRegistryMountData159(payment)
            let held = root.retainedCustodyUsage113()
            let bankHeld = nativeControlMetadataUsage113()
            @Expect(held[2], 2)
            @Expect(bankHeld[1] >= before[1] + 16777216)
            data.returnedLaunch159()
            let custodyActual159b1 = root.retainedCustodyUsage113()
            let custodyExpected159b1 = held
            @Expect(custodyActual159b1[0], custodyExpected159b1[0])
            @Expect(custodyActual159b1[1], custodyExpected159b1[1])
            @Expect(custodyActual159b1[2], custodyExpected159b1[2])
            let custodyActual159b2 = nativeControlMetadataUsage113()
            let custodyExpected159b2 = bankHeld
            @Expect(custodyActual159b2[0], custodyExpected159b2[0])
            @Expect(custodyActual159b2[1], custodyExpected159b2[1])
            data.retiredDispatch159()
            let released = root.retainedCustodyUsage113()
            @Expect(released[0], held[0] - 16384 - 1024)
            @Expect(released[1], held[1])
            @Expect(released[2], 1)
            let custodyActual159b3 = nativeControlMetadataUsage113()
            let custodyExpected159b3 = bankHeld
            @Expect(custodyActual159b3[0], custodyExpected159b3[0])
            @Expect(custodyActual159b3[1], custodyExpected159b3[1])
            var refused = false
            try { let _ = data.deriveError159(65536) }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
            // Repeated acknowledgments cannot retire the parent's last share.
            data.returnedLaunch159(); data.retiredDispatch159()
            let custodyActual159b4 = root.retainedCustodyUsage113()
            let custodyExpected159b4 = released
            @Expect(custodyActual159b4[0], custodyExpected159b4[0])
            @Expect(custodyActual159b4[1], custodyExpected159b4[1])
            @Expect(custodyActual159b4[2], custodyExpected159b4[2])
        } finally { root.close() }
        let custodyActual159b5 = nativeControlMetadataUsage113()
        let custodyExpected159b5 = before
        @Expect(custodyActual159b5[0], custodyExpected159b5[0])
        @Expect(custodyActual159b5[1], custodyExpected159b5[1])
    }

    @TestCase
    func dispatchCollectionWaitsForLaunchFrameAndIndependentErrorOutlivesBoth159(): Unit {
        let before = nativeControlMetadataUsage113()
        let root = reserveNativeControlMetadata(65536)
        let payment = root.deriveRetainedLease()
        let data = hostRetainRegistryMountData159(payment)
        let errorData = data.deriveError159(65536)
        try {
            let held = root.retainedCustodyUsage113()
            let bankHeld = nativeControlMetadataUsage113()
            @Expect(held[2], 3)
            data.retiredDispatch159()
            let custodyActual159b6 = root.retainedCustodyUsage113()
            let custodyExpected159b6 = held
            @Expect(custodyActual159b6[0], custodyExpected159b6[0])
            @Expect(custodyActual159b6[1], custodyExpected159b6[1])
            @Expect(custodyActual159b6[2], custodyExpected159b6[2])
            data.returnedLaunch159()
            let errorStillHeld = root.retainedCustodyUsage113()
            @Expect(errorStillHeld[0], held[0] - 16384 - 1024)
            @Expect(errorStillHeld[1], held[1])
            @Expect(errorStillHeld[2], 2)
            root.close()
            @Expect(errorData.retainedCustodyUsage113()[2], 1)
            let custodyActual159b7 = nativeControlMetadataUsage113()
            let custodyExpected159b7 = bankHeld
            @Expect(custodyActual159b7[0], custodyExpected159b7[0])
            @Expect(custodyActual159b7[1], custodyExpected159b7[1])
            // The copied diagnostic belongs to its own real consumer.
            errorData.close()
            let custodyActual159b8 = nativeControlMetadataUsage113()
            let custodyExpected159b8 = before
            @Expect(custodyActual159b8[0], custodyExpected159b8[0])
            @Expect(custodyActual159b8[1], custodyExpected159b8[1])
        } finally { errorData.close(); root.close() }
    }
}
