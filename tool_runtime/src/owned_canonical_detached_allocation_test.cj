package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

private func ownedDetachedCase(pool: LogicalJsonOwnerBudget): OwnedCanonicalThreadItemCustody {
    let owner = pool.acquire(1)
    try {
        owner.ensureRetainedPeak(16777216)
        let text = String.fromUtf8(Array<Byte>(1048576, repeat: b'x')) + "\u{0}雪"
        OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("owned-detached-item"), ThreadId("owned-detached-thread"),
            SemanticTurnId("owned-detached-turn"), 1, ThreadItemContent.SystemNote(text), ItemProvenance("system")), owner)
    } catch (error: Exception) { owner.close(); throw error }
}

private class OwnedCanonicalDetachedStorageFixture {
    private let owner: LogicalJsonOwnerReservation
    private var encoded: ?String = None
    init(owner: LogicalJsonOwnerReservation) {
        this.owner = owner
        // Same real derived owner prepays array/String/append overlap.
        owner.ensureRetainedPeak(12582912)
        encoded = Some(String.fromUtf8(Array<Byte>(1048576, repeat: b'e')) + "\u{0}雪")
    }
    func validate(): Bool { let value = encoded.getOrThrow(); value.size > 1048576 && value.endsWith("\u{0}雪") }
    func retire(): Unit { encoded = None; owner.close() }
}

@Test
class OwnedCanonicalDetachedAllocationTests {
    @TestCase
    func DetachedStorageKeepsSameOriginalPoolAfterRealDOMAliasesRetireUntilStorageClears(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let root = ownedDetachedCase(pool)
        let held = root.retainAliasCustody().value().getOrThrow()
        let actual = held.deriveRetainedAllocation(12582912).value().getOrThrow()
        let storage = OwnedCanonicalDetachedStorageFixture(actual)
        @Expect(root.closeAfterConsumption().isOk(), true)
        @Expect(held.closeAfterAliasRetirement().isOk(), true)
        @Expect(pool.usage()[0], 1)
        @Expect(pool.usage()[1] >= 16777216, true)
        @Expect(storage.validate(), true)
        @Expect(held.deriveRetainedAllocation(1).isOk(), false)
        storage.retire()
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
