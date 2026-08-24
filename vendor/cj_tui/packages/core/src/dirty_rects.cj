package core

import std.collection.*

public class DirtyRects {
    private let items = ArrayList<Rect>()

    public init() {}

    public init(rects: Array<Rect>) {
        addAll(rects)
    }

    public static func full(area: Rect): DirtyRects {
        let dirty = DirtyRects()
        dirty.add(area)
        dirty
    }

    public func add(rect: Rect): Unit {
        if (rect.width <= 0 || rect.height <= 0) { return }
        var merged = rect
        var i: Int64 = 0
        while (i < items.size) {
            let current = items[i]
            if (canMerge(current, merged)) {
                merged = unionRect(current, merged)
                items.remove(at: i)
            } else {
                i++
            }
        }
        items.add(merged)
    }

    public func addAll(rects: Array<Rect>): Unit {
        for (rect in rects) { add(rect) }
    }

    public func addAll(other: DirtyRects): Unit {
        addAll(other.rects())
    }

    public func clear(): Unit {
        while (items.size > 0) {
            items.remove(at: 0)
        }
    }

    public func isEmpty(): Bool {
        items.size == 0
    }

    public func rects(): Array<Rect> {
        items.toArray()
    }

    public func copy(): DirtyRects {
        DirtyRects(rects())
    }

    public func covers(area: Rect): Bool {
        if (area.width <= 0 || area.height <= 0) { return true }
        for (rect in items) {
            if (rect.x <= area.x && rect.y <= area.y && rect.right >= area.right && rect.bottom >= area.bottom) {
                return true
            }
        }
        false
    }

    public func intersects(area: Rect): Bool {
        for (rect in items) {
            let hit = intersect(rect, area)
            if (hit.width > 0 && hit.height > 0) { return true }
        }
        false
    }

    public func intersectsRect(x: Int64, y: Int64, width: Int64, height: Int64): Bool {
        if (width <= 0 || height <= 0) { return false }
        let right = x + width
        let bottom = y + height
        for (rect in items) {
            if (rect.x < right && rect.right > x && rect.y < bottom && rect.bottom > y) {
                return true
            }
        }
        false
    }

    public func intersectsCell(x: Int64, y: Int64): Bool {
        for (rect in items) {
            if (x >= rect.x && x < rect.right && y >= rect.y && y < rect.bottom) {
                return true
            }
        }
        false
    }

    public func cellCount(): Int64 {
        var count: Int64 = 0
        for (rect in items) {
            count += rect.width * rect.height
        }
        count
    }
}

func canMerge(left: Rect, right: Rect): Bool {
    let overlap = intersect(left, right)
    if (overlap.width > 0 && overlap.height > 0) { return true }
    if (left.y == right.y && left.height == right.height && (left.right == right.x || right.right == left.x)) { return true }
    if (left.x == right.x && left.width == right.width && (left.bottom == right.y || right.bottom == left.y)) { return true }
    false
}

func unionRect(left: Rect, right: Rect): Rect {
    let x1 = min(left.x, right.x)
    let y1 = min(left.y, right.y)
    let x2 = max(left.right, right.right)
    let y2 = max(left.bottom, right.bottom)
    Rect(x1, y1, x2 - x1, y2 - y1)
}
