import SwiftUI
import AppKit

/// SwiftUI wrapper around an NSTableView-based spreadsheet grid.
struct DataGridView: NSViewRepresentable {
    let source: GridDataSource
    /// Bump to force a reload (e.g. data changed).
    let version: Int
    var scrollToRow: Int? = nil
    var onScrolled: (() -> Void)? = nil
    /// Changes when a fresh data set is loaded; the grid scrolls back to the top.
    var dataGeneration: Int = 0

    func makeCoordinator() -> GridCoordinator { GridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let table = GridTableView()
        table.coordinator = context.coordinator
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = Settings.alternatingRows
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = max(20, Settings.gridFontSize + 9)
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(GridCoordinator.doubleClicked(_:))
        table.action = #selector(GridCoordinator.clicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        scroll.documentView = table
        context.coordinator.tableView = table
        context.coordinator.update(source: source, version: version)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(source: source, version: version)
        if context.coordinator.lastGeneration != dataGeneration {
            context.coordinator.lastGeneration = dataGeneration
            DispatchQueue.main.async { context.coordinator.tableView?.scrollRowToVisible(0) }
        }
        if let row = scrollToRow, let table = context.coordinator.tableView, row < table.numberOfRows {
            DispatchQueue.main.async {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                context.coordinator.beginEditing(row: row, column: 0)
                onScrolled?()
            }
        }
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: GridCoordinator?

    override func keyDown(with event: NSEvent) {
        guard let c = coordinator else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            c.deleteSelected()
        case 36, 76: // return, enter
            if selectedRow >= 0 { c.beginEditing(row: selectedRow, column: max(0, c.lastColumn)) }
        case 123: // left: move "focused" column
            c.lastColumn = max(0, c.lastColumn - 1)
            scrollColumnToVisible(c.lastColumn)
        case 124: // right
            c.lastColumn = min(numberOfColumns - 1, c.lastColumn + 1)
            scrollColumnToVisible(c.lastColumn)
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copyRows(format: .tsv)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRowIndexes.count > 0 }
        return super.validateUserInterfaceItem(item)
    }

}

final class GridRowView: NSTableRowView {
    var state: GridRowState = .normal

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let color: NSColor?
        switch state {
        case .inserted: color = NSColor.systemGreen.withAlphaComponent(0.16)
        case .deleted: color = NSColor.systemRed.withAlphaComponent(0.20)
        default: color = nil
        }
        if let color {
            color.setFill()
            bounds.fill()
        }
        // vertical column separators, only on real rows
        if let table = superview as? NSTableView {
            NSColor.separatorColor.withAlphaComponent(0.35).setFill()
            // only columns intersecting the area being drawn
            let visible = table.columnIndexes(in: convert(dirtyRect, to: table))
            for i in visible {
                let x = table.rect(ofColumn: i).maxX - 1 - frame.minX
                NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
            }
        }
    }
}

/// Shared, precomputed text attributes for grid cells (rebuilt when columns/fonts change).
struct GridCellStyle {
    let font: NSFont
    let monoFont: NSFont
    let paragraph: NSParagraphStyle
    let nullText: String
    let lineHeight: CGFloat

    init(fontSize: CGFloat, nullText: String) {
        font = NSFont.systemFont(ofSize: fontSize)
        monoFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        paragraph = p
        self.nullText = nullText
        lineHeight = ceil(font.ascender - font.descender + font.leading)
    }
}

/// Lightweight cell that draws its own text — no Auto Layout, no NSTextField —
/// so scrolling through large result sets stays smooth. An NSTextField is only
/// created while the cell is being edited.
final class GridCell: NSTableCellView {
    enum Kind { case value, null, placeholder }

    private var text = ""
    private var kind = Kind.value
    private var numeric = false
    private var deleted = false
    private var style: GridCellStyle?
    var editedHighlight = false
    weak var editor: NSTextField?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if oldValue != backgroundStyle { needsDisplay = true } }
    }

    func configure(text: String, kind: Kind, numeric: Bool, deleted: Bool, edited: Bool, style: GridCellStyle) {
        self.text = text
        self.kind = kind
        self.numeric = numeric
        self.deleted = deleted
        self.editedHighlight = edited
        self.style = style
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        if editedHighlight {
            NSColor.systemYellow.withAlphaComponent(0.28).setFill()
            bounds.fill()
        }
        if editor != nil { return }
        let emphasized = backgroundStyle == .emphasized
        let color: NSColor
        switch kind {
        case .value: color = emphasized ? .alternateSelectedControlTextColor : .labelColor
        case .null, .placeholder: color = emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.6) : .tertiaryLabelColor
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: numeric && kind == .value ? style.monoFont : style.font,
            .foregroundColor: color,
            .paragraphStyle: style.paragraph,
        ]
        if deleted { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let rect = NSRect(x: 5, y: floor((bounds.height - style.lineHeight) / 2), width: max(0, bounds.width - 9), height: style.lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

enum CopyFormat { case tsv, csv, json, sqlInsert, markdown }

@MainActor
final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    weak var tableView: GridTableView?
    private(set) var source: GridDataSource?
    private var columnSignature: [String] = []
    private var lastVersion = -1
    var lastColumn = 0
    var lastGeneration = 0

    private var editing: (row: Int, column: Int, original: String?)?
    private var cancelEdit = false
    private var style = GridCellStyle(fontSize: Settings.gridFontSize, nullText: Settings.nullText)
    private var font: NSFont { style.font }
    /// Per column: render values with monospaced digits.
    private var numericColumns: [Bool] = []

    private static let numericTypeHints = ["int", "serial", "numeric", "decimal", "float", "double", "real", "money", "number", "oid"]

    func update(source: GridDataSource, version: Int) {
        guard let table = tableView else { return }
        let sameSource = self.source === source
        self.source = source
        let sig = source.gridColumns.map { $0.name + ":" + $0.typeName }
        if sig != columnSignature || !sameSource {
            columnSignature = sig
            rebuildColumns()
            lastVersion = version
            table.reloadData()
        } else if version != lastVersion {
            lastVersion = version
            if editing == nil { table.reloadData() }
        }
        syncSelection()
        updateSortIndicators()
    }

    private func syncSelection() {
        guard let table = tableView, let source else { return }
        let want = source.gridSelection.filteredIndexSet { $0 < table.numberOfRows }
        if table.selectedRowIndexes != want && editing == nil {
            table.selectRowIndexes(want, byExtendingSelection: false)
        }
    }

    private func rebuildColumns() {
        guard let table = tableView, let source else { return }
        style = GridCellStyle(fontSize: Settings.gridFontSize, nullText: Settings.nullText)
        numericColumns = source.gridColumns.map { c in
            let t = c.typeName.lowercased()
            return GridCoordinator.numericTypeHints.contains { t.contains($0) } && !t.contains("[]") && !t.hasPrefix("_")
        }
        for c in table.tableColumns.reversed() { table.removeTableColumn(c) }
        // sample up to ~150 rows spread over the whole result for column widths
        let rowCount = source.gridRowCount
        let sampleIndexes = rowCount <= 150 ? Array(0..<rowCount) : stride(from: 0, to: rowCount, by: max(1, rowCount / 150)).map { $0 }
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        for (i, col) in source.gridColumns.enumerated() {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            let title = col.name
            tc.title = title
            if let fk = source.gridForeignKey(column: i) {
                tc.headerToolTip = "\(col.name)  \(col.typeName)\n→ \(fk.refTable).\(fk.refColumns.joined(separator: ",")) — ⌥-click a value to open the referenced row"
            } else {
                tc.headerToolTip = "\(col.name)  \(col.typeName)"
            }
            tc.headerCell.lineBreakMode = .byTruncatingTail
            var width = (title as NSString).size(withAttributes: [.font: headerFont]).width + 28
            for r in sampleIndexes {
                if let v = source.gridValue(row: r, column: i) {
                    let s = v.count > 80 ? String(v.prefix(80)) : v
                    width = max(width, (s as NSString).size(withAttributes: [.font: font]).width + 20)
                }
            }
            tc.width = min(max(width, 50), 340)
            tc.minWidth = 30
            tc.maxWidth = 4000
            table.addTableColumn(tc)
        }
    }

    private func updateSortIndicators() {
        guard let table = tableView, let source else { return }
        let sort = source.gridSort.first
        for (i, tc) in table.tableColumns.enumerated() {
            let name = i < source.gridColumns.count ? source.gridColumns[i].name : ""
            var img: NSImage?
            if let sort, sort.column == name {
                img = NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
            }
            table.setIndicatorImage(img, in: tc)
        }
    }

    private func columnIndex(_ tc: NSTableColumn?) -> Int? {
        guard let id = tc?.identifier.rawValue, id.hasPrefix("c") else { return nil }
        return Int(id.dropFirst())
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { source?.gridRowCount ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("GridRow")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? GridRowView) ?? {
            let r = GridRowView()
            r.identifier = id
            return r
        }()
        let state = source?.gridRowState(row) ?? .normal
        if v.state != state { v.state = state; v.needsDisplay = true }
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let source, let col = columnIndex(tableColumn) else { return nil }
        let id = NSUserInterfaceItemIdentifier("GridCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCell) ?? {
            let c = GridCell(frame: .zero)
            c.identifier = id
            return c
        }()
        let state = source.gridRowState(row)
        let value = source.gridValue(row: row, column: col)
        let numeric = col < numericColumns.count && numericColumns[col]
        let edited = state != .inserted && source.gridIsEdited(row: row, column: col)
        if source.gridIsDefault(row: row, column: col) {
            cell.configure(text: "DEFAULT", kind: .placeholder, numeric: false, deleted: state == .deleted, edited: edited, style: style)
        } else if let value {
            var display = value
            if display.utf8.count > 300 { display = String(display.prefix(300)) + "…" }
            if display.contains(where: { $0 == "\n" || $0 == "\r" }) {
                display = display.replacingOccurrences(of: "\r\n", with: "↵ ").replacingOccurrences(of: "\n", with: "↵ ").replacingOccurrences(of: "\r", with: "↵ ")
            }
            cell.configure(text: display, kind: .value, numeric: numeric, deleted: state == .deleted, edited: edited, style: style)
        } else {
            cell.configure(text: style.nullText, kind: .null, numeric: false, deleted: state == .deleted, edited: edited, style: style)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = tableView else { return }
        source?.gridSelectionChanged(table.selectedRowIndexes)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let col = columnIndex(tableColumn) else { return }
        source?.gridSortRequested(column: col)
        tableView.reloadData()
        updateSortIndicators()
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard let source else { return 100 }
        var width: CGFloat = 50
        for r in 0..<min(source.gridRowCount, 500) {
            if let v = source.gridValue(row: r, column: column) {
                width = max(width, (String(v.prefix(200)) as NSString).size(withAttributes: [.font: font]).width + 16)
            }
        }
        return min(width, 1200)
    }

    // MARK: Clicks & editing

    @objc func clicked(_ sender: Any?) {
        guard let table = tableView else { return }
        if table.clickedColumn >= 0 { lastColumn = table.clickedColumn }
        if NSEvent.modifierFlags.contains(.option), table.clickedRow >= 0, table.clickedColumn >= 0,
           source?.gridForeignKey(column: table.clickedColumn) != nil {
            source?.gridFollowForeignKey(row: table.clickedRow, column: table.clickedColumn)
        }
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard let table = tableView, table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
        beginEditing(row: table.clickedRow, column: table.clickedColumn)
    }

    func beginEditing(row: Int, column: Int) {
        guard let table = tableView, let source, source.gridEditable,
              row >= 0, row < table.numberOfRows, column >= 0, column < table.numberOfColumns,
              source.gridRowState(row) != .deleted,
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? GridCell else { return }
        table.scrollColumnToVisible(column)
        let original = source.gridIsDefault(row: row, column: column) ? nil : source.gridValue(row: row, column: column)
        editing = (row, column, original)
        lastColumn = column
        cancelEdit = false
        cell.editor?.removeFromSuperview()
        let tf = NSTextField(frame: cell.bounds.insetBy(dx: 1, dy: 1))
        tf.autoresizingMask = [.width, .height]
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.focusRingType = .none
        tf.font = font
        tf.lineBreakMode = .byClipping
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.delegate = self
        tf.stringValue = original ?? ""
        tf.placeholderString = original == nil ? style.nullText : nil
        cell.addSubview(tf)
        cell.editor = tf
        cell.needsDisplay = true
        table.window?.makeFirstResponder(tf)
        tf.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEdit = true
            tableView?.window?.makeFirstResponder(tableView)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, let e = editing, let source else { return }
        editing = nil
        defer {
            tf.removeFromSuperview()
        }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap { NSTextMovement(rawValue: $0) }
        if !cancelEdit {
            let newValue = tf.stringValue
            let changed = e.original == nil ? !newValue.isEmpty : newValue != e.original
            if changed { source.gridSetValue(.text(newValue), row: e.row, column: e.column) }
        }
        cancelEdit = false
        tableView?.reloadData(forRowIndexes: IndexSet(integer: e.row), columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
        tableView?.window?.makeFirstResponder(tableView)
        if movement == .tab {
            let next = e.column + 1
            if next < (tableView?.numberOfColumns ?? 0) {
                DispatchQueue.main.async { self.beginEditing(row: e.row, column: next) }
            }
        } else if movement == .backtab, e.column > 0 {
            DispatchQueue.main.async { self.beginEditing(row: e.row, column: e.column - 1) }
        }
    }

    func deleteSelected() {
        guard let table = tableView, let source, source.gridEditable else { return }
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        source.gridDeleteRows(rows)
    }

    // MARK: Copy

    private func selectedRows() -> IndexSet {
        guard let table = tableView else { return [] }
        if table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow) {
            return IndexSet(integer: table.clickedRow)
        }
        return table.selectedRowIndexes
    }

    func copyRows(format: CopyFormat) {
        guard let source else { return }
        let rows = selectedRows()
        guard !rows.isEmpty else { return }
        let cols = source.gridColumns.map(\.name)
        let data: [[String?]] = rows.map { r in cols.indices.map { source.gridValue(row: r, column: $0) } }
        let text = Exporter.render(columns: cols, rows: data, format: format, table: source.gridTable, dialect: source.gridDialect, includeHeader: format != .tsv)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table = tableView, let source else { return }
        let row = table.clickedRow
        let col = table.clickedColumn
        if row >= 0 && !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        func item(_ title: String, _ key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
            return i
        }
        let rows = selectedRows()
        let editable = source.gridEditable
        if row >= 0 && col >= 0 {
            let value = source.gridValue(row: row, column: col)
            let colName = col < source.gridColumns.count ? source.gridColumns[col].name : ""
            menu.addItem(item("Copy Cell Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value ?? "", forType: .string)
            })
        }
        if !rows.isEmpty {
            menu.addItem(item("Copy Row\(rows.count > 1 ? "s" : "")") { [weak self] in self?.copyRows(format: .tsv) })
            let sub = NSMenu()
            sub.addItem(item("CSV") { [weak self] in self?.copyRows(format: .csv) })
            sub.addItem(item("JSON") { [weak self] in self?.copyRows(format: .json) })
            sub.addItem(item("SQL INSERT") { [weak self] in self?.copyRows(format: .sqlInsert) })
            sub.addItem(item("Markdown") { [weak self] in self?.copyRows(format: .markdown) })
            let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
            copyAs.submenu = sub
            menu.addItem(copyAs)
        }
        if col >= 0 && col < source.gridColumns.count {
            let colName = source.gridColumns[col].name
            menu.addItem(item("Copy Column Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(colName, forType: .string)
            })
        }
        if editable && row >= 0 && col >= 0 {
            menu.addItem(.separator())
            menu.addItem(item("Edit Cell") { [weak self] in self?.beginEditing(row: row, column: col) })
            let setSub = NSMenu()
            setSub.addItem(item("NULL") { source.gridSetValue(.null, row: row, column: col) })
            setSub.addItem(item("Empty String") { source.gridSetValue(.text(""), row: row, column: col) })
            setSub.addItem(item("DEFAULT") { source.gridSetValue(.defaultValue, row: row, column: col) })
            let setItem = NSMenuItem(title: "Set Value", action: nil, keyEquivalent: "")
            setItem.submenu = setSub
            menu.addItem(setItem)
            menu.addItem(item("Duplicate Row\(rows.count > 1 ? "s" : "")") { source.gridDuplicateRows(rows) })
            let deleting = rows.allSatisfy { source.gridRowState($0) == .deleted }
            menu.addItem(item(deleting ? "Restore Row\(rows.count > 1 ? "s" : "")" : "Delete Row\(rows.count > 1 ? "s" : "")") { source.gridDeleteRows(rows) })
        }
        if row >= 0 && col >= 0 && source.gridTable != nil && col < source.gridColumns.count {
            menu.addItem(.separator())
            let value = source.gridValue(row: row, column: col)
            let colName = source.gridColumns[col].name
            let shown = value.map { $0.count > 30 ? String($0.prefix(30)) + "…" : $0 } ?? "NULL"
            menu.addItem(item("Filter: \(colName) = \(shown)") { source.gridQuickFilter(column: col, value: value) })
            if let fk = source.gridForeignKey(column: col), value != nil {
                menu.addItem(item("Open Referenced Row in \(fk.refTable)") { source.gridFollowForeignKey(row: row, column: col) })
            }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
