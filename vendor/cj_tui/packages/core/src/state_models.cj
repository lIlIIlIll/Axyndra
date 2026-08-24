package core

import std.collection.*

public enum SelectionMode {
    | NoSelection
    | Single
    | Multiple
}

public class SelectionModel {
    public let mode: SelectionMode
    public var current: ?Int64
    private let selected = ArrayList<Int64>()

    public init(mode!: SelectionMode = SelectionMode.Single, current!: ?Int64 = None) {
        this.mode = mode
        this.current = current
        match (current) {
            case Some(index) =>
                if (!isNoneSelection(mode)) { selected.add(max(0, index)) }
            case None => ()
        }
    }

    public func clear(): Unit {
        current = None
        while (selected.size > 0) {
            selected.remove(at: 0)
        }
    }

    public func select(index: Int64): Unit {
        if (isNoneSelection(mode)) { return }
        let value = max(0, index)
        current = Some(value)
        if (isSingleSelection(mode)) {
            while (selected.size > 0) { selected.remove(at: 0) }
            selected.add(value)
        } else if (!isSelected(value)) {
            selected.add(value)
        }
    }

    public func toggle(index: Int64): Unit {
        if (isNoneSelection(mode)) { return }
        let value = max(0, index)
        if (isSingleSelection(mode)) {
            select(value)
            return
        }
        var i: Int64 = 0
        while (i < selected.size) {
            if (selected[i] == value) {
                selected.remove(at: i)
                current = Some(value)
                return
            }
            i++
        }
        selected.add(value)
        current = Some(value)
    }

    public func move(delta: Int64, total: Int64): ?Int64 {
        if (total <= 0) {
            clear()
            return None
        }
        let base = match (current) {
            case Some(value) => value
            case None => if (delta >= 0) { -1 } else { total }
        }
        let next = clamp(base + delta, 0, total - 1)
        current = Some(next)
        Some(next)
    }

    public func isSelected(index: Int64): Bool {
        for (value in selected) {
            if (value == index) { return true }
        }
        false
    }

    public func selectedIndices(): Array<Int64> {
        selected.toArray()
    }
}

public class ScrollState {
    public var offset: Int64

    public init(offset!: Int64 = 0) {
        this.offset = max(0, offset)
    }

    public func scroll(delta: Int64, total: Int64, viewport: Int64): Unit {
        offset = clamp(offset + delta, 0, max(0, total - max(0, viewport)))
    }

    public func scrollTo(index: Int64, total: Int64, viewport: Int64): Unit {
        offset = clamp(index, 0, max(0, total - max(0, viewport)))
    }

    public func ensureVisible(index: Int64, total: Int64, viewport: Int64): Unit {
        if (total <= 0 || viewport <= 0) {
            offset = 0
            return
        }
        let current = clamp(index, 0, total - 1)
        if (current < offset) {
            offset = current
        } else if (current >= offset + viewport) {
            offset = current - viewport + 1
        }
        offset = clamp(offset, 0, max(0, total - viewport))
    }

    public func handle(key: KeyEvent, total: Int64, viewport: Int64): Bool {
        match (key.code) {
            case KeyCode.Up => scroll(-1, total, viewport); true
            case KeyCode.Down => scroll(1, total, viewport); true
            case KeyCode.PageUp => scroll(-max(1, viewport), total, viewport); true
            case KeyCode.PageDown => scroll(max(1, viewport), total, viewport); true
            case KeyCode.Home => offset = 0; true
            case KeyCode.End => offset = max(0, total - max(0, viewport)); true
            case _ => false
        }
    }
}

public class SortState {
    public var column: ?Int64
    public var descending: Bool

    public init(column!: ?Int64 = None, descending!: Bool = false) {
        this.column = column
        this.descending = descending
    }

    public func set(column: Int64, descending!: Bool = false): Unit {
        this.column = Some(max(0, column))
        this.descending = descending
    }

    public func clear(): Unit {
        column = None
        descending = false
    }

    public func toggle(column: Int64): Unit {
        match (this.column) {
            case Some(current) =>
                if (current == column) {
                    descending = !descending
                } else {
                    set(column)
                }
            case None => set(column)
        }
    }
}

public class FilterState {
    public var query: String
    public var active: Bool

    public init(query!: String = "", active!: Bool = false) {
        this.query = query
        this.active = active || !query.isEmpty()
    }

    public func set(query: String): Unit {
        this.query = query
        this.active = !query.isEmpty()
    }

    public func clear(): Unit {
        query = ""
        active = false
    }

    public func matches(text: String): Bool {
        !active || query.isEmpty() || text.contains(query)
    }
}

func isNoneSelection(mode: SelectionMode): Bool {
    match (mode) {
        case SelectionMode.NoSelection => true
        case _ => false
    }
}

func isSingleSelection(mode: SelectionMode): Bool {
    match (mode) {
        case SelectionMode.Single => true
        case _ => false
    }
}
