package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

func surfaceOwnerName(owner: SurfaceOwner): String {
    match (owner) {
        case SurfaceOwner.Transcript => "transcript"
        case SurfaceOwner.Composer => "composer"
        case SurfaceOwner.Modal => "modal"
        case SurfaceOwner.Ask => "ask"
        case SurfaceOwner.Approval => "approval"
        case SurfaceOwner.Todo => "todo"
        case SurfaceOwner.PlanReview => "plan"
        case SurfaceOwner.AgentHub => "hub"
        case SurfaceOwner.Completion => "completion"
    }
}

func surfacePlacementName(placement: SurfacePlacement): String {
    match (placement) {
        case SurfacePlacement.Primary => "primary"
        case SurfacePlacement.Anchored => "anchored"
        case SurfacePlacement.Fullscreen => "fullscreen"
    }
}

func presentationModeName(mode: PresentationMode): String {
    match (mode) {
        case PresentationMode.Primary => "primary"
        case PresentationMode.Fullscreen => "fullscreen"
    }
}

@Test
class TuiSurfaceHostTests {
    @TestCase
    func activeSurfaceOwnsFocusAndHitTesting(): Unit {
        let host = SurfaceHost()
        let viewport = Rect(0, 0, 80, 24)
        host.begin(viewport)
        let transcript = Rect(0, 0, 80, 18)
        let modal = Rect(20, 5, 40, 10)
        host.activate(SurfaceOwner.Transcript, SurfacePlacement.Primary, transcript)
        host.activate(SurfaceOwner.Modal, SurfacePlacement.Anchored, modal)
        host.focus(SurfaceOwner.Modal)

        @Expect(surfaceOwnerName(host.activeOwner()), "modal")
        @Expect(surfacePlacementName(host.activePlacement()), "anchored")
        @Expect(surfaceOwnerName(host.focusOwner()), "modal")
        @Expect(host.contains(SurfaceOwner.Modal, 20, 5), true)
        @Expect(host.contains(SurfaceOwner.Modal, 60, 15), false)
        @Expect(host.area(SurfaceOwner.Transcript).width, 80)
    }

    @TestCase
    func geometryHelpersStayInsideViewport(): Unit {
        let host = SurfaceHost()
        host.begin(Rect(0, 0, 30, 12))
        let fullscreen = host.fullscreenArea(margin: 2)
        let centered = host.centeredPanel(100, 100)
        let anchored = host.anchoredPanel(Rect(0, 0, 30, 12), 16, 8)

        @Expect(fullscreen, Rect(2, 2, 26, 8))
        @Expect(centered.x >= 0, true)
        @Expect(centered.y >= 0, true)
        @Expect(centered.right <= 30, true)
        @Expect(centered.bottom <= 12, true)
        @Expect(anchored.right <= 30, true)
        @Expect(anchored.bottom <= 12, true)
    }

    @TestCase
    func presentationModeTracksFullscreenSurface(): Unit {
        let host = SurfaceHost()
        @Expect(presentationModeName(host.presentationMode(fullscreen: false)), "primary")
        @Expect(presentationModeName(host.presentationMode(fullscreen: true)), "fullscreen")
    }
}
