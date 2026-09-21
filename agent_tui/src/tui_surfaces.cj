package agent_tui

import core.*
import std.collection.*

enum SurfacePlacement {
    Primary
    | Anchored
    | Fullscreen
}

enum SurfaceOwner {
    Transcript
    | Composer
    | Modal
    | Ask
    | Approval
    | Todo
    | PlanReview
    | AgentHub
    | Completion
}

// SurfaceHost is the single geometry and ownership ledger for product UI.
// Controllers still own their state and key semantics; the host owns where a
// controller is painted, which surface is active, and which surface receives
// focus. That keeps alternate-screen decisions independent from panel chrome.
class SurfaceHost {
    private var viewportValue = Rect(0, 0, 0, 0)
    private var activeOwnerValue = SurfaceOwner.Transcript
    private var activePlacementValue = SurfacePlacement.Primary
    private var focusOwnerValue = SurfaceOwner.Composer
    private var generationValue: Int64 = 0
    private let areas = HashMap<String, Rect>()

    func begin(viewport: Rect): Unit {
        viewportValue = viewport
        areas.clear()
        activeOwnerValue = SurfaceOwner.Transcript
        activePlacementValue = SurfacePlacement.Primary
        focusOwnerValue = SurfaceOwner.Composer
        generationValue++
    }

    func register(owner: SurfaceOwner, placement: SurfacePlacement, area: Rect): Unit {
        let _ = placement
        areas[surfaceOwnerKey(owner)] = area
    }

    func activate(owner: SurfaceOwner, placement: SurfacePlacement, area: Rect): Unit {
        register(owner, placement, area)
        activeOwnerValue = owner
        activePlacementValue = placement
    }

    func focus(owner: SurfaceOwner): Unit {
        focusOwnerValue = owner
    }

    func viewport(): Rect {
        viewportValue
    }

    func area(owner: SurfaceOwner): Rect {
        match (areas.get(surfaceOwnerKey(owner))) {
            case Some(value) => value
            case None => Rect(0, 0, 0, 0)
        }
    }

    func contains(owner: SurfaceOwner, x: Int64, y: Int64): Bool {
        let area = this.area(owner)
        area.width > 0 && area.height > 0 && x >= area.x && x < area.right && y >= area.y && y < area.bottom
    }

    func activeOwner(): SurfaceOwner {
        activeOwnerValue
    }

    func activePlacement(): SurfacePlacement {
        activePlacementValue
    }

    func focusOwner(): SurfaceOwner {
        focusOwnerValue
    }

    func generation(): Int64 {
        generationValue
    }

    func presentationMode(fullscreen!: Bool): PresentationMode {
        if (fullscreen) {
            PresentationMode.Fullscreen
        } else {
            PresentationMode.Primary
        }
    }

    func fullscreenArea(margin!: Int64 = 1): Rect {
        insetSurface(viewportValue, margin)
    }

    func centeredPanel(width: Int64, height: Int64): Rect {
        let panelWidth = min(max(1, width), max(1, viewportValue.width - 2))
        let panelHeight = min(max(1, height), max(1, viewportValue.height - 2))
        Rect(
            viewportValue.x + max(0, (viewportValue.width - panelWidth) / 2),
            viewportValue.y + max(0, (viewportValue.height - panelHeight) / 2),
            panelWidth,
            panelHeight
        )
    }

    func anchoredPanel(anchor: Rect, width: Int64, height: Int64): Rect {
        let panelWidth = min(max(1, width), max(1, viewportValue.width - 2))
        let panelHeight = min(max(1, height), max(1, viewportValue.height - 2))
        var x = anchor.x
        var y = anchor.y - panelHeight
        if (y < viewportValue.y) {
            y = anchor.bottom
        }
        x = min(max(viewportValue.x, x), max(viewportValue.x, viewportValue.right - panelWidth))
        y = min(max(viewportValue.y, y), max(viewportValue.y, viewportValue.bottom - panelHeight))
        Rect(x, y, panelWidth, panelHeight)
    }
}

func surfaceOwnerKey(owner: SurfaceOwner): String {
    match (owner) {
        case SurfaceOwner.Transcript => "transcript"
        case SurfaceOwner.Composer => "composer"
        case SurfaceOwner.Modal => "modal"
        case SurfaceOwner.Ask => "ask"
        case SurfaceOwner.Approval => "approval"
        case SurfaceOwner.Todo => "todo"
        case SurfaceOwner.PlanReview => "plan-review"
        case SurfaceOwner.AgentHub => "agent-hub"
        case SurfaceOwner.Completion => "completion"
    }
}

func insetSurface(area: Rect, margin: Int64): Rect {
    let xMargin = min(max(0, margin), max(0, area.width / 2))
    let yMargin = min(max(0, margin), max(0, area.height / 2))
    Rect(
        area.x + xMargin,
        area.y + yMargin,
        max(0, area.width - xMargin * 2),
        max(0, area.height - yMargin * 2)
    )
}
