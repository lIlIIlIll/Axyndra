package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

private func ownedWitnessCase(pool: LogicalJsonOwnerBudget): OwnedCanonicalThreadItemCustody {
    let owner = pool.acquire(1)
    try {
        owner.ensureRetainedPeak(16777216)
        let text = String.fromUtf8(Array<Byte>(1048576, repeat: b'w')) + "\u{0}雪"
        OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("owned-witness-item"), ThreadId("owned-witness-thread"),
            SemanticTurnId("owned-witness-turn"), 1, ThreadItemContent.SystemNote(text), ItemProvenance("system")), owner)
    } catch (error: Exception) { owner.close(); throw error }
}

@Test
class OwnedCanonicalRetirementWitnessTests {
    @TestCase
    func ExactPrivateDOMWitnessRequiresAllActualAliasesButNotDetachedStorageToRetire(): Unit {
        let pool = LogicalJsonOwnerBudget(); let root = ownedWitnessCase(pool)
        let first = root.retainAliasCustody().value().getOrThrow()
        let second = first.retainAliasCustody().value().getOrThrow()
        let witness = first.retirementWitness().value().getOrThrow()
        @Expect(refEq(witness, second.retirementWitness().value().getOrThrow()), true)
        let storage = first.deriveRetainedAllocation(4096).value().getOrThrow()
        @Expect(witness.isItemRetired(), false)
        @Expect(root.closeAfterConsumption().isOk(), true)
        @Expect(first.closeAfterAliasRetirement().isOk(), true)
        @Expect(witness.isItemRetired(), false)
        @Expect(second.withItem({ _ =>
            @Expect(witness.isItemRetired(), false)
            @Expect(second.closeAfterAliasRetirement().isOk(), false)
            Result.Ok(()) }).isOk(), true)
        @Expect(second.closeAfterAliasRetirement().isOk(), true)
        @Expect(witness.isItemRetired(), true)
        @Expect(first.retirementWitness().isOk(), false)
        @Expect(pool.usage()[0], 1); @Expect(pool.usage()[1] >= 16777216, true)
        storage.close()
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
