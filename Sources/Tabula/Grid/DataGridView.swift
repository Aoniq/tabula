import SwiftUI
import AppKit

/// SwiftUI wrapper around an NSTableView-based spreadsheet grid.
struct DataGridView: NSViewRepresentable {
    let source: GridDataSource
    /// Bump to force a reload (e.g. data changed).
    let version: Int
    var scrollToRow: Int? = nil
    var onScrolled: (() -> Void)? = nil

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
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
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

    override func drawGrid(inClipRect clipRect: NSRect) {
        // vertical lines only for rows that exist (avoid lines in empty area)
        let rect = NSRect(x: clipRect.minX, y: clipRect.minY, width: clipRect.width, height: min(clipRect.height, max(0, CGFloat(numberOfRows) * rowHeight - clipRect.minY)))
        super.drawGrid(inClipRect: rect)
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
    }
}

final class GridCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.cell?.isScrollable = true
        label.drawsBackground = false
        label.isBordered = false
        label.focusRingType = .none
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var editedHighlight = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if editedHighlight {
            NSColor.systemYellow.withAlphaComponent(0.28).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
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

    private var editing: (row: Int, column: Int, original: String?)?
    private var cancelEdit = false
    private var font: NSFont { NSFont.systemFont(ofSize: Settings.gridFontSize) }
    private var monoFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: Settings.gridFontSize, weight: .regular) }

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
        for c in table.tableColumns.reversed() { table.removeTableColumn(c) }
        let sampleRows = min(source.gridRowCount, 60)
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        for (i, col) in source.gridColumns.enumerated() {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            let title = col.name
            tc.title = title
            tc.headerToolTip = "\(col.name)  \(col.typeName)"
            tc.headerCell.lineBreakMode = .byTruncatingTail
            var width = (title as NSString).size(withAttributes: [.font: headerFont]).width + 28
            for r in 0..<sampleRows {
                if let v = source.gridValue(row: r, column: i) {
                    let s = v.count > 80 ? String(v.prefix(80)) : v
                    width = max(width, (s as NSString).size(withAttributes: [.font: font]).width + 14)
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
        let v = GridRowView()
        v.state = source?.gridRowState(row) ?? .normal
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
        let isDefault = source.gridIsDefault(row: row, column: col)
        cell.label.isEditable = false
        cell.label.delegate = self
        let numeric = value.map { Double($0) != nil } ?? false
        cell.label.font = numeric ? monoFont : font
        cell.label.alignment = .left
        var attrs: [NSAttributedString.Key: Any] = [.font: cell.label.font!]
        if state == .deleted { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if isDefault {
            attrs[.foregroundColor] = NSColor.tertiaryLabelColor
            cell.label.attributedStringValue = NSAttributedString(string: "DEFAULT", attributes: attrs)
        } else if let value {
            attrs[.foregroundColor] = NSColor.labelColor
            let display = value.count > 500 ? String(value.prefix(500)) + "…" : value
            cell.label.attributedStringValue = NSAttributedString(string: display.replacingOccurrences(of: "\n", with: "↵ "), attributes: attrs)
        } else {
            attrs[.foregroundColor] = NSColor.tertiaryLabelColor
            cell.label.attributedStringValue = NSAttributedString(string: Settings.nullText, attributes: attrs)
        }
        cell.editedHighlight = source.gridIsEdited(row: row, column: col) && state != .inserted
        if let fk = source.gridForeignKey(column: col), value != nil {
            cell.toolTip = "→ \(fk.refTable).\(fk.refColumns.joined(separator: ",")) (⌥-click to open)"
        } else {
            cell.toolTip = nil
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
        let tf = cell.label
        tf.isEditable = true
        tf.isSelectable = true
        tf.font = font
        tf.textColor = .labelColor
        tf.stringValue = original ?? ""
        tf.placeholderString = original == nil ? Settings.nullText : nil
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
        tf.isEditable = false
        tf.isSelectable = false
        editing = nil
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
