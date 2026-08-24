package core

import std.collection.*
import std.fs.*

public class Paginator {
    public var page: Int64
    public var pageSize: Int64
    public var total: Int64

    public init(page!: Int64 = 0, pageSize!: Int64 = 10, total!: Int64 = 0) {
        this.pageSize = max(1, pageSize)
        this.total = max(0, total)
        let pages = if (this.total <= 0) { 0 } else { (this.total + this.pageSize - 1) / this.pageSize }
        this.page = clamp(page, 0, max(0, pages - 1))
    }

    public func pageCount(): Int64 {
        if (total <= 0) { return 0 }
        (total + pageSize - 1) / pageSize
    }

    public func offset(): Int64 {
        page * pageSize
    }

    public func next(): Unit {
        page = min(max(0, pageCount() - 1), page + 1)
    }

    public func previous(): Unit {
        page = max(0, page - 1)
    }

    public func handle(key: KeyEvent): Bool {
        match (key.code) {
            case KeyCode.PageDown | KeyCode.Right =>
                next()
                true
            case KeyCode.PageUp | KeyCode.Left =>
                previous()
                true
            case KeyCode.Home =>
                page = 0
                true
            case KeyCode.End =>
                page = max(0, pageCount() - 1)
                true
            case _ => false
        }
    }
}

public class TableColumn {
    public let title: String
    public var width: Int64
    public let align: TextAlign

    public init(title: String, width!: Int64 = 10, align!: TextAlign = TextAlign.Left) {
        this.title = title
        this.width = max(1, width)
        this.align = align
    }
}

public enum TableStatus {
    | Ready
    | Empty
    | Loading
    | Error(String)
}

public class VirtualTable <: Widget {
    private let columns: Array<TableColumn>
    private let rowCount: Int64
    private let rowAt: (Int64) -> Array<String>
    public var offset: Int64
    public var selectedRow: ?Int64
    public var selectedColumn: Int64
    public var columnOffset: Int64
    public var frozenColumns: Int64 = 0
    public var sortColumn: ?Int64 = None
    public var sortDescending: Bool = false
    public var filterText: String = ""
    public var stickyHeader: Bool = true
    public var status: TableStatus = TableStatus.Ready
    public var emptyText: String = "No rows"
    public var loadingText: String = "Loading"
    private let selectedRows = ArrayList<Int64>()
    private let rowCacheIndices = ArrayList<Int64>()
    private let rowCacheValues = ArrayList<Array<String>>()
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style
    private let cellStyle: Style
    private let statusStyle: Style
    private let selectionModel: ?SelectionModel
    private let scrollState: ?ScrollState
    private let sortState: ?SortState
    private let filterState: ?FilterState

    public init(
        columns: Array<TableColumn>,
        rowCount: Int64,
        rowAt: (Int64) -> Array<String>,
        offset!: Int64 = 0,
        selectedRow!: ?Int64 = None,
        selectedColumn!: Int64 = 0,
        columnOffset!: Int64 = 0,
        block!: ?Block = None,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White),
        cellStyle!: Style = Style(fg: Color.Black, bg: Color.Cyan),
        statusStyle!: Style = Style(fg: Color.Indexed(8)),
        selectionModel!: ?SelectionModel = None,
        scrollState!: ?ScrollState = None,
        sortState!: ?SortState = None,
        filterState!: ?FilterState = None
    ) {
        this.columns = columns
        this.rowCount = max(0, rowCount)
        this.rowAt = rowAt
        this.offset = max(0, offset)
        this.selectedRow = selectedRow
        this.selectedColumn = max(0, selectedColumn)
        this.columnOffset = max(0, columnOffset)
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
        this.cellStyle = cellStyle
        this.statusStyle = statusStyle
        this.selectionModel = selectionModel
        this.scrollState = scrollState
        this.sortState = sortState
        this.filterState = filterState
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        syncExternalState()
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        ensureColumnVisible(target.width)
        let headerRows = if (stickyHeader) { Int64(1) } else { Int64(0) }
        if (stickyHeader) {
            renderColumns(target.x, target.y, columnTitles(), buffer, Style(fg: Color.Yellow, modifier: Modifier.strong()), None)
        }
        if (renderStatus(target, buffer, headerRows)) { return }
        let limit = max(0, target.height - headerRows)
        for (row in 0..limit) {
            let index = offset + row
            match (sourceIndexAtVisible(index)) {
                case Some(sourceIndex) =>
                    let active = match (selectedRow) {
                        case Some(v) => v == index
                        case None => false
                    } || isSelected(sourceIndex) || modelSelected(sourceIndex)
                    renderColumns(
                        target.x,
                        target.y + headerRows + row,
                        cachedRow(sourceIndex),
                        buffer,
                        if (active) { selectedStyle } else { style },
                        if (active) { selectedColumn } else { None }
                    )
                case None => return
            }
        }
    }

    public func handle(key: KeyEvent, viewportHeight: Int64): Bool {
        let current = match (selectedRow) {
            case Some(v) => v
            case None => 0
        }
        let total = visibleRowCount()
        match (key.code) {
            case KeyCode.Up =>
                selectedRow = Some(max(0, current - 1))
                ensureSelectedVisible(viewportHeight)
                true
            case KeyCode.Down =>
                selectedRow = Some(min(max(0, total - 1), current + 1))
                ensureSelectedVisible(viewportHeight)
                true
            case KeyCode.PageUp =>
                selectedRow = Some(max(0, current - max(1, viewportHeight)))
                ensureSelectedVisible(viewportHeight)
                true
            case KeyCode.PageDown =>
                selectedRow = Some(min(max(0, total - 1), current + max(1, viewportHeight)))
                ensureSelectedVisible(viewportHeight)
                true
            case KeyCode.Left =>
                selectedColumn = max(0, selectedColumn - 1)
                columnOffset = min(columnOffset, selectedColumn)
                true
            case KeyCode.Right =>
                selectedColumn = min(max(0, columns.size - 1), selectedColumn + 1)
                if (selectedColumn < columns.size) { columnOffset = min(columnOffset, selectedColumn) }
                true
            case KeyCode.Home =>
                selectedRow = Some(0)
                offset = 0
                true
            case KeyCode.End =>
                selectedRow = Some(max(0, total - 1))
                ensureSelectedVisible(viewportHeight)
                true
            case KeyCode.Char(r' ') =>
                toggleSelectedRow()
                true
            case _ => false
        }
    }

    public func handleWithDirty(key: KeyEvent, viewportHeight: Int64, area: Rect): ?DirtyRects {
        let beforeOffset = offset
        let beforeSelected = selectedRow
        let beforeColumn = selectedColumn
        if (!handle(key, viewportHeight)) { return None }
        if (beforeOffset != offset || beforeColumn != selectedColumn) {
            return Some(dirtyBody(area))
        }
        Some(dirtySelectionChange(area, beforeSelected, selectedRow))
    }

    public func dirtyHeader(area: Rect): DirtyRects {
        let dirty = DirtyRects()
        if (stickyHeader && area.height > 0) {
            dirty.add(Rect(area.x, area.y, area.width, 1))
        }
        dirty
    }

    public func dirtyBody(area: Rect): DirtyRects {
        let dirty = DirtyRects()
        let headerRows = if (stickyHeader) { Int64(1) } else { Int64(0) }
        dirty.add(Rect(area.x, area.y + headerRows, area.width, max(0, area.height - headerRows)))
        dirty
    }

    public func dirtyRows(area: Rect, rows: Array<Int64>): DirtyRects {
        let dirty = DirtyRects()
        let headerRows = if (stickyHeader) { Int64(1) } else { Int64(0) }
        for (row in rows) {
            addVirtualTableRowDirty(dirty, area, Some(row), offset, headerRows)
        }
        if (dirty.isEmpty()) { dirty.add(area) }
        dirty
    }

    public func dirtySelectionChange(area: Rect, before: ?Int64, after: ?Int64): DirtyRects {
        let rows = ArrayList<Int64>()
        match (before) {
            case Some(row) => rows.add(row)
            case None => ()
        }
        match (after) {
            case Some(row) => rows.add(row)
            case None => ()
        }
        dirtyRows(area, rows.toArray())
    }

    public func dirtyStatus(area: Rect): DirtyRects {
        dirtyBody(area)
    }

    public func clearCachedRows(): Unit {
        clearRowCache()
    }

    public func cachedRowCount(): Int64 {
        rowCacheIndices.size
    }

    public func sortBy(column: Int64, descending!: Bool = false): Unit {
        sortColumn = Some(clamp(column, 0, max(0, columns.size - 1)))
        sortDescending = descending
        offset = 0
        clearRowCache()
    }

    public func clearSort(): Unit {
        sortColumn = None
        sortDescending = false
        clearRowCache()
    }

    public func resizeColumn(column: Int64, width: Int64): Bool {
        if (column < 0 || column >= columns.size) { return false }
        columns[column].width = max(1, width)
        true
    }

    public func setFrozenColumns(count: Int64): Unit {
        frozenColumns = clamp(count, 0, columns.size)
    }

    public func setFilter(text: String): Unit {
        filterText = text
        offset = 0
        selectedRow = None
        clearRowCache()
    }

    public func setStatus(status: TableStatus): Unit {
        this.status = status
    }

    public func toggleSelectedRow(): Unit {
        match (selectedRow) {
            case Some(row) =>
                match (sourceIndexAtVisible(row)) {
                    case Some(sourceIndex) =>
                        match (selectionModel) {
                            case Some(model) =>
                                model.toggle(sourceIndex)
                                return
                            case None => ()
                        }
                        if (isSelected(sourceIndex)) {
                            removeSelected(sourceIndex)
                        } else {
                            selectedRows.add(sourceIndex)
                        }
                    case None => return
                }
            case None => ()
        }
    }

    public func isSelected(row: Int64): Bool {
        for (selected in selectedRows) {
            if (selected == row) { return true }
        }
        false
    }

    public func selectedRowIndices(): Array<Int64> {
        selectedRows.toArray()
    }

    private func columnTitles(): Array<String> {
        let titles = ArrayList<String>()
        for (i in 0..columns.size) {
            let suffix = match (sortColumn) {
                case Some(col) =>
                    if (col == i) {
                        if (sortDescending) { " v" } else { " ^" }
                    } else {
                        ""
                    }
                case None => ""
            }
            titles.add(columns[i].title + suffix)
        }
        titles.toArray()
    }

    private func renderColumns(x: Int64, y: Int64, values: Array<String>, buffer: Buffer, style: Style, activeColumn: ?Int64): Unit {
        var cx = x
        let limit = min(values.size, columns.size)
        let frozen = min(frozenColumns, limit)
        for (i in 0..frozen) {
            cx = renderColumnCell(cx, y, i, values, buffer, style, activeColumn)
            if (cx > buffer.area.right) { return }
        }
        for (i in max(columnOffset, frozen)..limit) {
            cx = renderColumnCell(cx, y, i, values, buffer, style, activeColumn)
            if (cx > buffer.area.right) { return }
        }
    }

    private func renderColumnCell(
        cx: Int64,
        y: Int64,
        i: Int64,
        values: Array<String>,
        buffer: Buffer,
        style: Style,
        activeColumn: ?Int64
    ): Int64 {
            let column = columns[i]
            let text = truncate(values[i], column.width)
            let cellArea = Rect(cx, y, column.width, 1)
            let rowStyle = match (activeColumn) {
                case Some(col) => if (col == i) { cellStyle } else { style }
                case None => style
            }
            buffer.setString(alignedX(cellArea, displayWidthFast(text), column.align), y, text, style: rowStyle)
            cx + column.width + 1
    }

    private func ensureSelectedVisible(viewportHeight: Int64): Unit {
        let total = visibleRowCount()
        match (selectedRow) {
            case Some(row) =>
                if (row < offset) {
                    offset = row
                } else if (viewportHeight > 0 && row >= offset + viewportHeight) {
                    offset = row - viewportHeight + 1
                }
                offset = clamp(offset, 0, max(0, total - viewportHeight))
            case None => ()
        }
    }

    private func ensureColumnVisible(width: Int64): Unit {
        if (selectedColumn < columnOffset) {
            columnOffset = selectedColumn
            return
        }
        var used: Int64 = 0
        for (i in columnOffset..min(selectedColumn + 1, columns.size)) {
            used += columns[i].width + 1
        }
        while (used > width && columnOffset < selectedColumn) {
            used -= columns[columnOffset].width + 1
            columnOffset++
        }
    }

    private func visibleIndices(): Array<Int64> {
        let rows = ArrayList<Int64>()
        for (i in 0..rowCount) {
            if (matchesFilter(i)) {
                rows.add(i)
            }
        }
        match (sortColumn) {
            case Some(column) => sortRows(rows, column)
            case None => ()
        }
        rows.toArray()
    }

    private func usesDerivedRows(): Bool {
        if (!filterText.isEmpty()) { return true }
        match (sortColumn) {
            case Some(_) => true
            case None => false
        }
    }

    private func visibleRowCount(): Int64 {
        if (!usesDerivedRows()) { return rowCount }
        visibleIndices().size
    }

    private func sourceIndexAtVisible(index: Int64): ?Int64 {
        if (index < 0) { return None }
        if (!usesDerivedRows()) {
            if (index >= rowCount) { return None }
            return Some(index)
        }
        let indices = visibleIndices()
        if (index >= indices.size) { return None }
        Some(indices[index])
    }

    private func matchesFilter(index: Int64): Bool {
        if (filterText.isEmpty()) { return true }
        for (cell in cachedRow(index)) {
            if (cell.contains(filterText)) { return true }
        }
        false
    }

    private func sortRows(rows: ArrayList<Int64>, column: Int64): Unit {
        var i: Int64 = 1
        while (i < rows.size) {
            let key = rows[i]
            var j = i - 1
            while (j >= 0 && rowComesAfter(rows[j], key, column)) {
                rows[j + 1] = rows[j]
                j--
            }
            rows[j + 1] = key
            i++
        }
    }

    private func rowComesAfter(left: Int64, right: Int64, column: Int64): Bool {
        let leftValue = valueAt(left, column)
        let rightValue = valueAt(right, column)
        let cmp = compareStrings(leftValue, rightValue)
        if (sortDescending) { cmp < 0 } else { cmp > 0 }
    }

    private func valueAt(row: Int64, column: Int64): String {
        let values = cachedRow(row)
        if (column >= 0 && column < values.size) { values[column] } else { "" }
    }

    private func cachedRow(index: Int64): Array<String> {
        for (i in 0..rowCacheIndices.size) {
            if (rowCacheIndices[i] == index) {
                return rowCacheValues[i]
            }
        }
        let row = rowAt(index)
        rowCacheIndices.add(index)
        rowCacheValues.add(row)
        row
    }

    private func clearRowCache(): Unit {
        while (rowCacheIndices.size > 0) {
            rowCacheIndices.remove(at: 0)
            rowCacheValues.remove(at: 0)
        }
    }

    private func renderStatus(area: Rect, buffer: Buffer, headerRows: Int64): Bool {
        let y = area.y + headerRows
        if (y >= area.bottom) { return true }
        match (status) {
            case TableStatus.Ready =>
                if (visibleRowCount() == 0) {
                    buffer.setString(area.x, y, truncate(emptyText, area.width), style: statusStyle)
                    return true
                }
                false
            case TableStatus.Empty =>
                buffer.setString(area.x, y, truncate(emptyText, area.width), style: statusStyle)
                true
            case TableStatus.Loading =>
                buffer.setString(area.x, y, truncate(loadingText, area.width), style: statusStyle)
                true
            case TableStatus.Error(message) =>
                buffer.setString(area.x, y, truncate(message, area.width), style: Style(fg: Color.Red).patch(statusStyle))
                true
        }
    }

    private func syncExternalState(): Unit {
        match (scrollState) {
            case Some(state) => offset = state.offset
            case None => ()
        }
        match (sortState) {
            case Some(state) =>
                sortColumn = state.column
                sortDescending = state.descending
            case None => ()
        }
        match (filterState) {
            case Some(state) => filterText = state.query
            case None => ()
        }
    }

    private func modelSelected(index: Int64): Bool {
        match (selectionModel) {
            case Some(model) => model.isSelected(index)
            case None => false
        }
    }

    private func removeSelected(row: Int64): Unit {
        for (i in 0..selectedRows.size) {
            if (selectedRows[i] == row) {
                selectedRows.remove(at: i)
                return
            }
        }
    }
}

func addVirtualTableRowDirty(dirty: DirtyRects, area: Rect, selected: ?Int64, offset: Int64, headerRows: Int64): Unit {
    match (selected) {
        case Some(index) =>
            let row = index - offset + headerRows
            if (row >= 0 && row < area.height) {
                dirty.add(Rect(area.x, area.y + row, area.width, 1))
            }
        case None => ()
    }
}

public class TreeNode {
    public let id: String
    public let label: String
    public var expanded: Bool
    private let children: ArrayList<TreeNode>

    public init(id: String, label: String, expanded!: Bool = false, children!: Array<TreeNode> = []) {
        this.id = id
        this.label = label
        this.expanded = expanded
        this.children = ArrayList<TreeNode>()
        for (child in children) {
            this.children.add(child)
        }
    }

    public func add(child: TreeNode): Unit {
        children.add(child)
    }

    public func childNodes(): Array<TreeNode> {
        children.toArray()
    }
}

public class Tree <: Widget {
    private let roots: Array<TreeNode>
    public var selected: Int64
    public var offset: Int64
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style

    public init(
        roots: Array<TreeNode>,
        selected!: Int64 = 0,
        offset!: Int64 = 0,
        block!: ?Block = None,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.roots = roots
        this.selected = max(0, selected)
        this.offset = max(0, offset)
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
    }

    public func toggleSelected(): Unit {
        let nodes = visibleNodes()
        if (selected >= 0 && selected < nodes.size) {
            nodes[selected].expanded = !nodes[selected].expanded
        }
    }

    public func selectedId(): ?String {
        let nodes = visibleNodes()
        if (selected >= 0 && selected < nodes.size) {
            Some(nodes[selected].id)
        } else {
            None
        }
    }

    public func selectById(id: String): Bool {
        let nodes = visibleNodes()
        for (i in 0..nodes.size) {
            if (nodes[i].id == id) {
                selected = i
                return true
            }
        }
        false
    }

    public func findById(id: String): ?TreeNode {
        for (root in roots) {
            match (findTreeNode(root, id)) {
                case Some(node) => return Some(node)
                case None => ()
            }
        }
        None
    }

    public func expandAll(): Unit {
        for (root in roots) {
            setExpandedRecursive(root, true)
        }
    }

    public func collapseAll(): Unit {
        for (root in roots) {
            setExpandedRecursive(root, false)
        }
        selected = 0
        offset = 0
    }

    public func handle(key: KeyEvent, viewportHeight: Int64): Bool {
        let total = visibleNodes().size
        match (key.code) {
            case KeyCode.Up => selected = max(0, selected - 1); ensureVisible(total, viewportHeight); true
            case KeyCode.Down => selected = min(max(0, total - 1), selected + 1); ensureVisible(total, viewportHeight); true
            case KeyCode.Left => collapseSelected(); true
            case KeyCode.Right => expandSelected(); true
            case KeyCode.Enter | KeyCode.Char(r' ') => toggleSelected(); true
            case _ => false
        }
    }

    public func expandSelected(): Unit {
        let nodes = visibleNodes()
        if (selected >= 0 && selected < nodes.size) {
            nodes[selected].expanded = true
        }
    }

    public func collapseSelected(): Unit {
        let nodes = visibleNodes()
        if (selected >= 0 && selected < nodes.size) {
            nodes[selected].expanded = false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        let nodes = visibleRows()
        for (row in 0..target.height) {
            let index = offset + row
            if (index >= nodes.size) { return }
            let (node, depth) = nodes[index]
            let marker = if (node.childNodes().size > 0) { if (node.expanded) { "- " } else { "+ " } } else { "  " }
            let text = repeat("  ", depth) + marker + node.label
            buffer.setString(target.x, target.y + row, truncate(text, target.width), style: if (index == selected) { selectedStyle } else { style })
        }
    }

    private func ensureVisible(total: Int64, viewportHeight: Int64): Unit {
        if (selected < offset) {
            offset = selected
        } else if (selected >= offset + viewportHeight) {
            offset = selected - viewportHeight + 1
        }
        offset = clamp(offset, 0, max(0, total - viewportHeight))
    }

    private func visibleNodes(): Array<TreeNode> {
        let rows = visibleRows()
        let nodes = ArrayList<TreeNode>()
        for ((node, _) in rows) {
            nodes.add(node)
        }
        nodes.toArray()
    }

    private func visibleRows(): Array<(TreeNode, Int64)> {
        let rows = ArrayList<(TreeNode, Int64)>()
        for (node in roots) {
            collectTreeRows(node, 0, rows)
        }
        rows.toArray()
    }
}

func collectTreeRows(node: TreeNode, depth: Int64, rows: ArrayList<(TreeNode, Int64)>): Unit {
    rows.add((node, depth))
    if (node.expanded) {
        for (child in node.childNodes()) {
            collectTreeRows(child, depth + 1, rows)
        }
    }
}

func findTreeNode(node: TreeNode, id: String): ?TreeNode {
    if (node.id == id) { return Some(node) }
    for (child in node.childNodes()) {
        match (findTreeNode(child, id)) {
            case Some(found) => return Some(found)
            case None => ()
        }
    }
    None
}

func setExpandedRecursive(node: TreeNode, expanded: Bool): Unit {
    node.expanded = expanded
    for (child in node.childNodes()) {
        setExpandedRecursive(child, expanded)
    }
}

func compareStrings(left: String, right: String): Int64 {
    let a = unsafe { left.rawData() }
    let b = unsafe { right.rawData() }
    let limit = min(a.size, b.size)
    for (i in 0..limit) {
        if (a[i] < b[i]) { return -1 }
        if (a[i] > b[i]) { return 1 }
    }
    if (a.size < b.size) { return -1 }
    if (a.size > b.size) { return 1 }
    0
}

public class FilePicker <: Widget {
    public var path: String
    private let extension: String
    private let state = ListState(selected: Some(0))
    private var entries: Array<String> = []
    public var searchText: String = ""
    public var showHidden: Bool = false

    public init(path!: String = ".", extension!: String = "", showHidden!: Bool = false) {
        this.path = path
        this.extension = extension
        this.showHidden = showHidden
        refresh()
    }

    public func refresh(): Unit {
        let dirs = ArrayList<String>()
        let files = ArrayList<String>()
        dirs.add("..")
        try {
            for (entry in Directory.readFrom(path)) {
                let name = entry.name
                if (!showHidden && name.startsWith(".")) { continue }
                if (!searchText.isEmpty() && !name.contains(searchText)) { continue }
                let childPath = joinPath(path, name)
                if (isDirectory(childPath)) {
                    insertSorted(dirs, name)
                } else if (extension.isEmpty() || name.endsWith(extension)) {
                    insertSorted(files, name)
                }
            }
        } catch (_) {}
        for (file in files) {
            dirs.add(file)
        }
        entries = dirs.toArray()
    }

    public func selectedEntry(): ?String {
        match (state.selected) {
            case Some(index) =>
                if (index >= 0 && index < entries.size) { Some(entries[index]) } else { None }
            case None => None
        }
    }

    public func selectedPath(): ?String {
        match (selectedEntry()) {
            case Some(entry) => Some(if (entry == "..") { parentPath(path) } else { joinPath(path, entry) })
            case None => None
        }
    }

    public func chooseSelected(): ?String {
        selectedPath()
    }

    public func setSearch(text: String): Unit {
        searchText = text
        state.select(Some(0))
        state.offset = 0
        refresh()
    }

    public func toggleHidden(): Unit {
        showHidden = !showHidden
        refresh()
    }

    public func selectedInfo(): ?FileEntryInfo {
        match (selectedEntry()) {
            case Some(entry) =>
                let fullPath = if (entry == "..") { parentPath(path) } else { joinPath(path, entry) }
                Some(FileEntryInfo(entry, fullPath, isDirectory(fullPath)))
            case None => None
        }
    }

    public func enterSelected(): Bool {
        match (selectedPath()) {
            case Some(nextPath) =>
                if (isDirectory(nextPath)) {
                    path = nextPath
                    state.select(Some(0))
                    state.offset = 0
                    refresh()
                    return true
                }
                false
            case None => false
        }
    }

    public func parent(): Bool {
        let nextPath = parentPath(path)
        if (nextPath == path) { return false }
        path = nextPath
        state.select(Some(0))
        state.offset = 0
        refresh()
        true
    }

    public func handle(key: KeyEvent, viewportHeight: Int64): Bool {
        match (key.code) {
            case KeyCode.Up =>
                state.move(-1, entries.size, viewportHeight: viewportHeight)
                true
            case KeyCode.Down =>
                state.move(1, entries.size, viewportHeight: viewportHeight)
                true
            case KeyCode.PageUp =>
                state.move(-max(1, viewportHeight), entries.size, viewportHeight: viewportHeight)
                true
            case KeyCode.PageDown =>
                state.move(max(1, viewportHeight), entries.size, viewportHeight: viewportHeight)
                true
            case KeyCode.Home =>
                state.select(Some(0))
                state.scrollToVisible(entries.size, viewportHeight)
                true
            case KeyCode.End =>
                state.select(Some(max(0, entries.size - 1)))
                state.scrollToVisible(entries.size, viewportHeight)
                true
            case KeyCode.Enter =>
                enterSelected()
            case _ => false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        List(entries, state: Some(state), block: Block(title: path)).render(area, buffer)
    }
}

public class FileEntryInfo {
    public let name: String
    public let path: String
    public let isDir: Bool

    public init(name: String, path: String, isDir: Bool) {
        this.name = name
        this.path = path
        this.isDir = isDir
    }
}

func insertSorted(items: ArrayList<String>, value: String): Unit {
    var index: Int64 = 0
    while (index < items.size && compareStrings(items[index], value) <= 0) {
        index++
    }
    items.add(value)
    var i = items.size - 1
    while (i > index) {
        items[i] = items[i - 1]
        i--
    }
    items[index] = value
}

func joinPath(base: String, name: String): String {
    if (base.isEmpty() || base == ".") { return name }
    if (base.endsWith("/")) { base + name } else { base + "/" + name }
}

func parentPath(path: String): String {
    if (path.isEmpty() || path == "." || path == "/") { return path }
    var end = path.size
    while (end > 1 && path[end - 1] == b'/') { end-- }
    var i = end - 1
    while (i > 0) {
        if (path[i] == b'/') {
            if (i == 0) { return "/" }
            return path[..i]
        }
        i--
    }
    "."
}

func isDirectory(path: String): Bool {
    try {
        _ = Directory.readFrom(path)
        true
    } catch (_) {
        false
    }
}
