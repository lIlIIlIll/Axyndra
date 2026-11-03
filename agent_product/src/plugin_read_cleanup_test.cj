package agent_product

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

class ReadCleanupOwnerProbe {
    let path: String
    var calls: Int64 = 0
    var failure: Int64 = 0
    init(path: String) {
        this.path = path
        File.writeTo(path, "owned private copy".toArray())
    }
    func cleanup(): Result<Unit> {
        calls++
        if (failure == 1) {
            return pluginProcessError("fixture.read_cleanup_pending", "fixture retains its private copy")
        }
        if (failure == 2) { throw IllegalStateException("fixture cleanup exception") }
        if (exists(Path(path))) { remove(path) }
        Result.Ok(())
    }
}

@Test
class ProductReadCleanupOwnerTests {
    @TestCase
    func distinctFixedOwnersRejectReplacementAndClosedRegistration(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let host = ProductJavaScriptPluginHost()
        let view = ReadCleanupOwnerProbe(root + "/view")
        let context = ReadCleanupOwnerProbe(root + "/context")
        try {
            lifecycleTestRequire(host.ownReadViewCleanup({ => view.cleanup() }))
            lifecycleTestRequire(host.ownContextReadCleanup({ => context.cleanup() }))
            @Expect(host.ownReadViewCleanup({ => Result.Ok(()) }).error().getOrThrow().code,
                "read_view.owner_conflict")
            @Expect(host.ownContextReadCleanup({ => Result.Ok(()) }).error().getOrThrow().code,
                "context.read_owner_conflict")
            lifecycleTestRequire(host.close())
            @Expect(view.calls, 1); @Expect(context.calls, 1)
            @Expect(!exists(Path(view.path)) && !exists(Path(context.path)))
            @Expect(host.ownReadViewCleanup({ => Result.Ok(()) }).isError())
            @Expect(host.ownContextReadCleanup({ => Result.Ok(()) }).isError())
            lifecycleTestRequire(host.close())
            @Expect(view.calls, 2); @Expect(context.calls, 2)
        } finally {
            let _ = host.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func failedOrThrowingOwnerNeverSkipsOtherCleanupAndRetriesOriginalOwner(): Unit {
        for (mode in [1, 2]) {
            let root = Directory.createTemp("/tmp").toString()
            let host = ProductJavaScriptPluginHost()
            let view = ReadCleanupOwnerProbe(root + "/view")
            let context = ReadCleanupOwnerProbe(root + "/context")
            view.failure = mode
            try {
                lifecycleTestRequire(host.ownReadViewCleanup({ => view.cleanup() }))
                lifecycleTestRequire(host.ownContextReadCleanup({ =>
                    // Re-enter the host lock to prove cleanup is called outside it.
                    @Expect(host.ownReadViewCleanup({ => Result.Ok(()) }).isError())
                    context.cleanup()
                }))
                let result = host.close()
                let expected = if (mode == 1) { "fixture.read_cleanup_pending" } else { "plugin.resource_cleanup_failed" }
                @Expect(result.error().getOrThrow().code, expected)
                @Expect(view.calls, 1); @Expect(context.calls, 1)
                @Expect(exists(Path(view.path)) && !exists(Path(context.path)))
                view.failure = 0
                lifecycleTestRequire(host.close())
                @Expect(view.calls, 2); @Expect(context.calls, 2)
                @Expect(!exists(Path(view.path)) && !exists(Path(context.path)))
            } finally {
                view.failure = 0
                let _ = host.close()
                remove(root, recursive: true)
            }
        }
    }
}
