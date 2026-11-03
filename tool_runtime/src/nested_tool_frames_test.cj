package tool_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class NestedToolFramesTests {
    @TestCase
    func deepestReturnOwnsTheSinglePendingRootRelease(): Unit {
        let root = OperationId("root"); let child = OperationId("child")
        let frames = NestedToolSlotFrames(root, "plugin.program.run")
        @Expect(frames.begin(root).isOk())
        @Expect(frames.activate(root).isOk())
        @Expect(frames.enter(root, child, "plugin.workspace.read").isOk())
        @Expect(frames.begin(child).isOk())
        @Expect(frames.activate(child).isOk())
        // Both executor and outer callback return early. Neither is a nested
        // action ACK and neither may release the shared ledger reservation.
        @Expect(frames.leave(child).isError())
        @Expect(frames.returnChild(root).isError())
        frames.finishRoot()
        @Expect(!frames.takeRelease())
        @Expect(frames.begin(child).isError())
        @Expect(frames.returnChild(child).isOk())
        @Expect(frames.takeRelease())
        @Expect(!frames.takeRelease())
        @Expect(!frames.contains(root) && !frames.contains(child))
    }

    @TestCase
    func yieldedAdmissionAfterRootFinishReleasesOnlyAfterSlotRestored(): Unit {
        let root = OperationId("yielded")
        let frames = NestedToolSlotFrames(root, "plugin.program.run")
        @Expect(frames.begin(root).isOk())
        frames.finishRoot()
        @Expect(!frames.takeRelease())
        @Expect(frames.activate(root).isError())
        @Expect(frames.takeRelease())
        @Expect(!frames.takeRelease())
        @Expect(frames.restore(root).isError())
    }

    @TestCase
    func reentrantParentAndSiblingCannotBorrowTheLeafReservation(): Unit {
        let root = OperationId("root"); let child = OperationId("child")
        let frames = NestedToolSlotFrames(root, "plugin.program.run")
        @Expect(frames.begin(root).isOk() && frames.activate(root).isOk())
        @Expect(frames.enter(root, child, "plugin.workspace.read").isOk())
        @Expect(frames.begin(root).isError())
        @Expect(frames.enter(root, OperationId("sibling"), "plugin.workspace.glob").isError())
        @Expect(frames.begin(OperationId("forged")).isError())
        @Expect(frames.leave(child).isOk())
        @Expect(frames.enter(root, child, "plugin.workspace.read").isError())
        @Expect(frames.returnChild(root).isOk())
        frames.finishRoot()
        @Expect(frames.takeRelease() && !frames.takeRelease())
    }

    @TestCase
    func depthAndWidthLimitsDoNotRefundAttemptedCalls(): Unit {
        let root = OperationId("root"); let first = OperationId("first")
        let frames = NestedToolSlotFrames(root, "plugin.program.run")
        @Expect(frames.begin(root).isOk() && frames.activate(root).isOk())
        @Expect(frames.enter(root, first, "plugin.workspace.read").isOk())
        for (index in 0..32) {
            @Expect(frames.begin(first).isOk())
            @Expect(frames.restore(first).isOk())
        }
        @Expect(frames.begin(first).isError())
        @Expect(frames.leave(first).isOk() && frames.returnChild(root).isOk())
        frames.finishRoot(); @Expect(frames.takeRelease())
        let depth = NestedToolSlotFrames(OperationId("d0"), "plugin.program.run")
        for (index in 0..8) {
            let parent = OperationId("d" + index.toString()); let child = OperationId("d" + (index + 1).toString())
            @Expect(depth.begin(parent).isOk() && depth.activate(parent).isOk())
            @Expect(depth.enter(parent, child, "plugin.workspace.read").isOk())
        }
        @Expect(depth.begin(OperationId("d8")).isError())
        for (index in 0..8) {
            let child = OperationId("d" + (8 - index).toString())
            let parent = OperationId("d" + (7 - index).toString())
            @Expect(depth.leave(child).isOk() && depth.returnChild(parent).isOk())
        }
        depth.finishRoot(); @Expect(depth.takeRelease())
    }
}
