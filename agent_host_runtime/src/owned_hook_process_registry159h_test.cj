package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.{reserveNativeControlMetadata, nativeControlMetadataUsage113}
import process4cj.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os == "Linux"]
private func hookRegistryUsage159h(expected: (Int64, Int64)): Unit {
    let actual = nativeControlMetadataUsage113()
    @Expect(actual[0], expected[0]); @Expect(actual[1], expected[1])
}

@When[os == "Linux"]
private func hookRegistryCycleFrame159h(root: String, closing: Bool): Unit {
    let port = HostLocalProcessPort(HostLocalReadTargetInspector(root))
    let baseline = nativeControlMetadataUsage113()
    try {
        let count: Int64 = if (closing) { 1 } else { 16 }
        for (_ in 0..count) {
            let id = OperationId("hook-reservation-identity-159h")
            port.reserveHookOperation159h(id)
            let held = nativeControlMetadataUsage113()
            @Expect(held[0], baseline[0] + 1)
            @Expect(held[1], baseline[1] + 16777216)
            var rejected = false
            try { port.reserveHookOperation159h(id) }
            catch (_: IllegalStateException) { rejected = true }
            @Expect(rejected); hookRegistryUsage159h(held)
            let process = startProcess(ProcessCommand("/bin/sh",
                arguments: ["-c", if (closing) { "sleep 30" } else { "exit 0" }],
                workingDirectory: root, maxOutputBytes: 4096))
            try {
                port.registerOperationProcess(id, process)
                @Expect(port.hasActiveOperation(id))
                if (closing) {
                    let closed = port.beginNativeClose()
                    @Expect(closed.firstError, "")
                    // A real kill/close request is not either caller return.
                    hookRegistryUsage159h(held)
                    @Expect(port.reservedOperationCancelled(id))
                }
                let status = process.wait()
                if (!closing) { @Expect(status.code, 0) }
                let _ = process.close()
                @Expect(!process.isAlive())
                port.finishOperationProcess(id)
                @Expect(!port.hasActiveOperation(id))
                // Finish alone cannot retire the independently reserved ID.
                hookRegistryUsage159h(held)
            } finally { let _ = process.close() }
            // The process helper/close calls have returned. The actual entry
            // has no exported copy and release unlinks/clears its entire node.
            port.releaseOperation(id)
            hookRegistryUsage159h(baseline)
        }
        if (closing) {
            var rejected = false
            try { port.reserveHookOperation159h(OperationId("closed-hook-159h")) }
            catch (_: IllegalStateException) { rejected = true }
            @Expect(rejected); hookRegistryUsage159h(baseline)
        }
    } finally { let _ = port.beginNativeClose() }
}

@When[os == "Linux"]
private func hookRegistryFixture159h(closing: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    try { hookRegistryCycleFrame159h(root, closing) }
    finally { remove(root, recursive: true) }
}

@When[os == "Linux"]
@Test
class ActualHookProcessRegistry159hTests {
    @TestCase
    func actualHookKernelRegistryRepeatedProcessesRetireIndependentCopiedIdentity159h(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(262144)
        try { hookRegistryFixture159h(false) } finally { fixture.close() }
        hookRegistryUsage159h(before)
    }

    @TestCase
    func actualHookCloseAndFinishCannotReplaceReservationReturn159h(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(262144)
        try { hookRegistryFixture159h(true) } finally { fixture.close() }
        hookRegistryUsage159h(before)
    }
}
