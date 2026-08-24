package core

public struct Rect <: Equatable<Rect> {
    public var x: Int64
    public var y: Int64
    public var width: Int64
    public var height: Int64

    public init(x: Int64, y: Int64, width: Int64, height: Int64) {
        this.x = x
        this.y = y
        this.width = if (width < 0) { 0 } else { width }
        this.height = if (height < 0) { 0 } else { height }
    }

    public operator func ==(other: Rect): Bool {
        x == other.x && y == other.y && width == other.width && height == other.height
    }

    public prop right: Int64 { get() { x + width } }
    public prop bottom: Int64 { get() { y + height } }
}

public struct Position {
    public var x: Int64
    public var y: Int64
    public init(x: Int64, y: Int64) {
        this.x = x
        this.y = y
    }
}

public enum Direction {
    | Horizontal
    | Vertical
}

public enum Constraint {
    | Length(Int64)
    | Percent(Int64)
    | Min(Int64)
    | Max(Int64)
    | Ratio(Int64, Int64)
}

public enum Flex {
    | Start
    | Center
    | End
    | SpaceBetween
}

public struct Spacing {
    public let left: Int64
    public let right: Int64
    public let top: Int64
    public let bottom: Int64

    public init(left!: Int64 = 0, right!: Int64 = 0, top!: Int64 = 0, bottom!: Int64 = 0) {
        this.left = max(0, left)
        this.right = max(0, right)
        this.top = max(0, top)
        this.bottom = max(0, bottom)
    }

    public static func zero(): Spacing {
        Spacing()
    }

    public static func all(value: Int64): Spacing {
        Spacing(left: value, right: value, top: value, bottom: value)
    }

    public static func symmetric(horizontal!: Int64 = 0, vertical!: Int64 = 0): Spacing {
        Spacing(left: horizontal, right: horizontal, top: vertical, bottom: vertical)
    }

    public func inner(area: Rect): Rect {
        Rect(
            area.x + left,
            area.y + top,
            area.width - left - right,
            area.height - top - bottom
        )
    }
}

public class Layout {
    private let direction: Direction
    private let constraints: Array<Constraint>
    private let flex: Flex
    private let gap: Int64
    private let margin: Spacing

    public init(
        direction: Direction,
        constraints: Array<Constraint>,
        flex!: Flex = Flex.Start,
        gap!: Int64 = 0,
        margin!: Spacing = Spacing.zero()
    ) {
        this.direction = direction
        this.constraints = constraints
        this.flex = flex
        this.gap = max(0, gap)
        this.margin = margin
    }

    public static func horizontal(constraints: Array<Constraint>): Layout {
        Layout(Direction.Horizontal, constraints)
    }

    public static func vertical(constraints: Array<Constraint>): Layout {
        Layout(Direction.Vertical, constraints)
    }

    public func withFlex(flex: Flex): Layout {
        Layout(direction, constraints, flex: flex, gap: gap, margin: margin)
    }

    public func withGap(gap: Int64): Layout {
        Layout(direction, constraints, flex: flex, gap: gap, margin: margin)
    }

    public func withMargin(margin: Spacing): Layout {
        Layout(direction, constraints, flex: flex, gap: gap, margin: margin)
    }

    public func split(area: Rect): Array<Rect> {
        let target = margin.inner(area)
        if (constraints.size == 0) { return [] }
        let total = match (direction) {
            case Horizontal => target.width
            case Vertical => target.height
        }
        let totalGap = gap * max(0, constraints.size - 1)
        let available = max(0, total - totalGap)
        var fixed: Int64 = 0
        var minCount: Int64 = 0
        var maxCount: Int64 = 0
        let sizes = Array<Int64>(constraints.size, repeat: 0)
        for (i in 0..constraints.size) {
            match (constraints[i]) {
                case Length(v) =>
                    sizes[i] = clamp(v, 0, available)
                    fixed += sizes[i]
                case Percent(p) =>
                    sizes[i] = clamp(available * clamp(p, 0, 100) / 100, 0, available)
                    fixed += sizes[i]
                case Min(_) => minCount++
                case Max(_) => maxCount++
                case Ratio(n, d) =>
                    sizes[i] = if (d <= 0 || n <= 0) { 0 } else { clamp(available * n / d, 0, available) }
                    fixed += sizes[i]
            }
        }

        var remaining = available - fixed
        if (remaining < 0) {
            remaining = 0
        }
        for (i in 0..constraints.size) {
            match (constraints[i]) {
                case Min(v) =>
                    let share = if (minCount <= 0) { 0 } else { remaining / minCount }
                    sizes[i] = max(v, share)
                case Max(v) =>
                    let share = if (maxCount <= 0) { 0 } else { remaining / maxCount }
                    sizes[i] = min(max(0, v), share)
                case _ => ()
            }
        }
        normalizeSizes(sizes, available, minCount > 0)

        let rects = Array<Rect>(constraints.size, repeat: Rect(area.x, area.y, 0, 0))
        let used = usedSize(sizes) + totalGap
        var flexGap = gap
        var offset: Int64 = flexOffset(total, used)
        match (flex) {
            case Flex.SpaceBetween =>
                if (constraints.size > 1 && used < total) {
                    flexGap = gap + (total - used) / (constraints.size - 1)
                }
            case _ => ()
        }
        for (i in 0..sizes.size) {
            match (direction) {
                case Horizontal =>
                    rects[i] = Rect(target.x + offset, target.y, sizes[i], target.height)
                case Vertical =>
                    rects[i] = Rect(target.x, target.y + offset, target.width, sizes[i])
            }
            offset += sizes[i] + flexGap
        }
        rects
    }

    private func flexOffset(total: Int64, used: Int64): Int64 {
        if (used >= total) { return 0 }
        match (flex) {
            case Flex.Start | Flex.SpaceBetween => 0
            case Flex.Center => (total - used) / 2
            case Flex.End => total - used
        }
    }

    private static func usedSize(sizes: Array<Int64>): Int64 {
        var used: Int64 = 0
        for (size in sizes) {
            used += size
        }
        used
    }

    private static func normalizeSizes(sizes: Array<Int64>, total: Int64, fill: Bool): Unit {
        var used: Int64 = 0
        for (size in sizes) {
            used += size
        }
        var i: Int64 = sizes.size - 1
        while (used > total && i >= 0) {
            let take = min(sizes[i], used - total)
            sizes[i] -= take
            used -= take
            i--
        }
        if (fill && used < total && sizes.size > 0) {
            sizes[sizes.size - 1] += total - used
        }
    }
}

public struct SizeHint {
    public let minWidth: Int64
    public let minHeight: Int64
    public let preferredWidth: Int64
    public let preferredHeight: Int64
    public let maxWidth: Int64
    public let maxHeight: Int64

    public init(
        minWidth!: Int64 = 0,
        minHeight!: Int64 = 0,
        preferredWidth!: Int64 = 0,
        preferredHeight!: Int64 = 0,
        maxWidth!: Int64 = Int64.Max,
        maxHeight!: Int64 = Int64.Max
    ) {
        this.minWidth = max(0, minWidth)
        this.minHeight = max(0, minHeight)
        this.preferredWidth = max(0, preferredWidth)
        this.preferredHeight = max(0, preferredHeight)
        this.maxWidth = max(0, maxWidth)
        this.maxHeight = max(0, maxHeight)
    }
}

public interface Sizable {
    func sizeHint(): SizeHint
}

public class Grid {
    private let rows: Array<Constraint>
    private let columns: Array<Constraint>
    private let gap: Int64
    private let margin: Spacing

    public init(rows: Array<Constraint>, columns: Array<Constraint>, gap!: Int64 = 0, margin!: Spacing = Spacing.zero()) {
        this.rows = rows
        this.columns = columns
        this.gap = max(0, gap)
        this.margin = margin
    }

    public func split(area: Rect): Array<Array<Rect>> {
        let target = margin.inner(area)
        let rowRects = Layout.vertical(rows).withGap(gap).split(target)
        let out = Array<Array<Rect>>(rowRects.size, repeat: [])
        for (r in 0..rowRects.size) {
            out[r] = Layout.horizontal(columns).withGap(gap).split(rowRects[r])
        }
        out
    }
}

public struct FlexItem {
    public let basis: Int64
    public let grow: Int64
    public let shrink: Int64

    public init(basis!: Int64 = 0, grow!: Int64 = 1, shrink!: Int64 = 1) {
        this.basis = max(0, basis)
        this.grow = max(0, grow)
        this.shrink = max(0, shrink)
    }
}

public class FlexLayout {
    private let direction: Direction
    private let items: Array<FlexItem>
    private let gap: Int64

    public init(direction: Direction, items: Array<FlexItem>, gap!: Int64 = 0) {
        this.direction = direction
        this.items = items
        this.gap = max(0, gap)
    }

    public func split(area: Rect): Array<Rect> {
        if (items.size == 0) { return [] }
        let total = match (direction) {
            case Direction.Horizontal => area.width
            case Direction.Vertical => area.height
        }
        let available = max(0, total - gap * max(0, items.size - 1))
        var basisTotal: Int64 = 0
        var growTotal: Int64 = 0
        for (item in items) {
            basisTotal += item.basis
            growTotal += item.grow
        }
        let sizes = Array<Int64>(items.size, repeat: 0)
        let extra = max(0, available - basisTotal)
        for (i in 0..items.size) {
            sizes[i] = items[i].basis + if (growTotal > 0) { extra * items[i].grow / growTotal } else { 0 }
        }
        Layout(direction, sizesToConstraints(sizes)).withGap(gap).split(area)
    }
}

public class LayoutCache {
    private var area: Rect = Rect(0, 0, 0, 0)
    private var rects: Array<Rect> = []
    private var valid: Bool = false

    public init() {}

    public func get(area: Rect, compute: (Rect) -> Array<Rect>): Array<Rect> {
        if (valid && this.area == area) {
            return rects
        }
        this.area = area
        rects = compute(area)
        valid = true
        rects
    }

    public func invalidate(): Unit {
        valid = false
    }
}

func sizesToConstraints(sizes: Array<Int64>): Array<Constraint> {
    let out = Array<Constraint>(sizes.size, repeat: Constraint.Length(0))
    for (i in 0..sizes.size) {
        out[i] = Constraint.Length(sizes[i])
    }
    out
}
