package agent_app

import agent_tui.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class GalleryCliTests {
    @TestCase
    func acceptsEveryRegistryLifecycleState(): Unit {
        var stateCount = 0
        for (descriptor in agentCardRendererRegistry()) {
            for (state in descriptor.lifecycleStates) {
                stateCount += 1
                @Expect(galleryState(state))
                @Expect(galleryStateNames().contains(state))
            }
        }
        @Expect(stateCount > 0)
    }

    @TestCase
    func invalidStateRemainsTypedCliFailure(): Unit {
        @Expect(!galleryState("not-a-gallery-state"))
        @Expect(runGalleryCli(["--state", "not-a-gallery-state", "--plain"]), 2)
    }
}
