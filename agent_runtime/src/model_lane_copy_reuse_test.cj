package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func laneCopyFixture232(version: String, thread: ThreadId): ToolSetSnapshot {
    let schema = objectValue([])
    ToolSetSnapshot("copy-" + version, [ToolSnapshotEntry("fixture.read", version, schema, version, [],
        implementationFingerprint: "fixture-" + version,
        schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))], threadId: Some(thread))
}
private func laneCopyChange232(thread: ThreadId): RunModelLaneChange {
    let before = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
        1000, 100, 20, "estimator", "retry", "cache", laneCopyFixture232("first", thread), "system")
    RunModelLaneChange(before, modelLaneReplacingToolSet(before, laneCopyFixture232("second", thread)), 10)
}

@Test
class ValidatedModelLaneCopies232Tests {
    @TestCase
    func ReturnedCopiesPreserveValidationAndCannotMutateTheFrozenChange(): Unit {
        let thread = ThreadId("lane-copy-thread")
        let change = laneCopyChange232(thread)
        validateModelLaneChange(change, thread)
        let copies = validatedModelLaneCopies232(change, thread)
        @Expect(copies[0].toolSet.id, "copy-first"); @Expect(copies[1].toolSet.id, "copy-second")
        copies[1].toolSet.entries[0] = copies[0].toolSet.entries[0]
        @Expect(copies[1].toolSet.entries[0].description, "first")
        @Expect(change.nextLane().toolSet.entries[0].description, "second")
        validateModelLaneChange(change, thread)
    }
    @TestCase
    func WrongThreadKeepsTheOriginalPublicValidationFailure(): Unit {
        let change = laneCopyChange232(ThreadId("lane-copy-thread"))
        var previous = ""; var copied = ""
        try { validateModelLaneChange(change, ThreadId("other-thread")) }
        catch (error: IllegalArgumentException) { previous = error.message }
        try { let _ = validatedModelLaneCopies232(change, ThreadId("other-thread")) }
        catch (error: IllegalArgumentException) { copied = error.message }
        @Expect(previous, "safe cut requires a distinct snapshot for this Thread")
        @Expect(copied, previous)
    }
}
