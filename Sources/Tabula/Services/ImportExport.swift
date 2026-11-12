import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Entry points for import / export / backup / restore. The heavy lifting lives in
// Exporter.swift, ImportCSV.swift and DumpTool.swift; the sheets in Views/Export*, Import*, Dump*.

@MainActor
enum ImportController {
    static func importCSV(into tab: TableTabState) {
        guard let ws = tab.workspace, ws.isConnected else { return }
        guard ws.family != .redis else {
            ws.showToast("CSV import is not supported for Redis", error: true)
            return
        }
        guard tab.object.kind == .table else {
            ws.showToast("CSV can only be imported into tables", error: true)
            return
        }
        if ws.config.safeMode == .readOnly {
            _ = ws.approveWrites(["INSERT INTO \(ws.dialect.qualified(tab.object))"])   // shows the read-only alert
            return
        }
        if tab.hasDataChanges {
            let a = NSAlert()
            a.messageText = "“\(tab.object.name)” has uncommitted changes"
            a.informativeText = "Commit or discard them before importing."
            a.runModal()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import CSV into \(tab.object.name)"
        panel.prompt = "Choose"
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText]
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let model = try CSVImportModel(tab: tab, workspace: ws, url: url)
            SheetPresenter.present { host in
                model.close = { host.close() }
                return CSVImportSheet(model: model)
            }
        } catch {
            ws.showToast("Could not read \(url.lastPathComponent): \(error.localizedDescription)", error: true)
        }
    }

    /// Files below this size open in a query tab; larger ones are streamed statement by statement.
    static let smallFileLimit = 1_000_000

    static func runSQLFile(_ ws: WorkspaceState) {
        guard ws.isConnected else { return }
        let panel = NSOpenPanel()
        panel.title = "Run SQL File"
        panel.prompt = "Run"
        var types: [UTType] = [.plainText]
        if let sql = UTType(filenameExtension: "sql") { types.insert(sql, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size < smallFileLimit {
            guard let text = readText(url) else {
                ws.showToast("Could not read \(url.lastPathComponent)", error: true)
                return
            }
            ws.newQueryTab(sql: text, title: url.lastPathComponent, run: true)
            return
        }
        let model = SQLFileRunModel(workspace: ws, url: url, fileSize: size)
        SheetPresenter.present { host in
            model.close = { host.close() }
            return SQLFileRunSheet(model: model)
        }
        model.start()
    }

    nonisolated static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }
}

@MainActor
enum ExportController {
    static func exportTable(_ tab: TableTabState) {
        guard let ws = tab.workspace else { return }
        let model = ExportSheetModel(table: tab, workspace: ws)
        SheetPresenter.present { host in
            model.close = { host.close() }
            return ExportSheet(model: model)
        }
    }

    static func exportResult(_ q: QueryTabState) {
        guard let ws = q.workspace else { return }
        guard let r = q.selectedResult, r.isResultSet else {
            ws.showToast("There is no result set to export", error: true)
            return
        }
        let rows = q.model(for: r).orderedRows
        let title = q.title.hasSuffix(".sql") ? String(q.title.dropLast(4)) : q.title
        let model = ExportSheetModel(result: r, orderedRows: rows, title: title, workspace: ws)
        SheetPresenter.present { host in
            model.close = { host.close() }
            return ExportSheet(model: model)
        }
    }
}

@MainActor
enum DumpController {
    static func backup(_ ws: WorkspaceState) {
        guard checkSupported(ws, action: "Backup") else { return }
        let model = DumpSheetModel(workspace: ws, mode: .backup)
        SheetPresenter.present { host in
            model.close = { host.close() }
            return DumpSheet(model: model)
        }
    }

    static func restore(_ ws: WorkspaceState) {
        guard checkSupported(ws, action: "Restore") else { return }
        if ws.config.safeMode == .readOnly {
            _ = ws.approveWrites(["RESTORE DATABASE \(ws.currentDatabase)"])   // shows the read-only alert
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Restore \(DumpConnection(ws).targetDescription)"
        panel.prompt = "Choose"
        var types: [UTType] = [.plainText, .data]
        if let sql = UTType(filenameExtension: "sql") { types.insert(sql, at: 0) }
        if ws.family == .postgres, let dump = UTType(filenameExtension: "dump") { types.insert(dump, at: 1) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let model = DumpSheetModel(workspace: ws, mode: .restore(url))
        SheetPresenter.present { host in
            model.close = { host.close() }
            return DumpSheet(model: model)
        }
    }

    private static func checkSupported(_ ws: WorkspaceState, action: String) -> Bool {
        guard ws.isConnected else { return false }
        if ws.family == .redis {
            let a = NSAlert()
            a.messageText = "\(action) is not supported for Redis"
            a.informativeText = "Use redis-cli (BGSAVE / --rdb) or your hosting provider's snapshots instead."
            a.runModal()
            return false
        }
        if ws.family != .sqlite && DumpConnection(ws).database.isEmpty {
            let a = NSAlert()
            a.messageText = "Select a database first"
            a.informativeText = "\(action) works on the current database. Choose one with the database switcher."
            a.runModal()
            return false
        }
        return true
    }
}

// MARK: - Sheet hosting

/// Hosts a SwiftUI view as a sheet on the key window (or a standalone window as a fallback).
@MainActor
final class SheetPresenter {
    private var controller: NSViewController?
    private weak var presenter: NSViewController?
    private var window: NSWindow?

    @discardableResult
    static func present<Content: View>(_ build: (SheetPresenter) -> Content) -> SheetPresenter {
        let host = SheetPresenter()
        let hc = NSHostingController(rootView: build(host))
        hc.sizingOptions = [.preferredContentSize]
        host.controller = hc
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let parent, let vc = parent.contentViewController {
            host.presenter = vc
            vc.presentAsSheet(hc)
        } else {
            let w = NSWindow(contentViewController: hc)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            w.makeKeyAndOrderFront(nil)
            host.window = w
        }
        return host
    }

    func close() {
        guard let controller else { return }
        if let presenter {
            presenter.dismiss(controller)
        } else {
            window?.close()
            window = nil
        }
        self.controller = nil
    }
}

// MARK: - Shared sheet chrome

struct IOSheetHeader: View {
    var icon: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Monospaced, auto-scrolling log output.
struct IOLogView: View {
    var text: String
    var minHeight: CGFloat = 160

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(minHeight: minHeight, maxHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .onChange(of: text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

extension Int {
    /// "12,345"
    var ioGrouped: String { formatted(.number.grouping(.automatic)) }
}

func ioByteString(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}
