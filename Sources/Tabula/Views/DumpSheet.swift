import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DumpSheetModel {
    enum Mode: Equatable {
        case backup
        case restore(URL)
    }

    enum Phase: Equatable {
        case options
        case running
        case succeeded(String)
        case failed(String, toolMissing: Bool)
    }

    let workspace: WorkspaceState
    let mode: Mode
    let connection: DumpConnection

    var content: DumpContent = .full
    var pgFormat: PGDumpFormat = .plain
    var includeDrop = false
    var singleTransaction = false
    var clean = false

    var phase: Phase = .options
    var log = ""
    var outputURL: URL?
    private var process: ToolProcess?
    var close: () -> Void = {}

    /// pg_dump custom archive chosen for restore.
    let isCustomArchive: Bool
    let inputSize: Int

    init(workspace: WorkspaceState, mode: Mode) {
        self.workspace = workspace
        self.mode = mode
        connection = DumpConnection(workspace)
        if case .restore(let url) = mode {
            isCustomArchive = workspace.family == .postgres && DumpTool.isPGCustomArchive(url)
            inputSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        } else {
            isCustomArchive = false
            inputSize = 0
        }
    }

    var family: DatabaseFamily { workspace.family }
    var isBackup: Bool { mode == .backup }

    var toolName: String {
        (isBackup ? DumpTool.backupTool(for: family) : DumpTool.restoreTool(for: family, customArchive: isCustomArchive)) ?? "—"
    }

    var toolPath: String? { DumpTool.path(for: toolName) }

    var title: String {
        switch mode {
        case .backup: return "Back Up “\(databaseLabel)”"
        case .restore(let url): return "Restore “\(url.lastPathComponent)”"
        }
    }

    var databaseLabel: String {
        family == .sqlite ? (connection.filePath as NSString).lastPathComponent : connection.database
    }

    var subtitle: String {
        "\(workspace.config.kind.displayName) · \(family == .sqlite ? connection.filePath : "\(connection.host):\(connection.port)")"
    }

    // MARK: Actions

    func backup() {
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd-HHmm"
            return f.string(from: Date())
        }()
        let ext = family == .postgres ? pgFormat.fileExtension : "sql"
        let base = family == .sqlite ? ((connection.filePath as NSString).lastPathComponent as NSString).deletingPathExtension : connection.database
        let panel = NSSavePanel()
        panel.title = "Save Backup"
        panel.nameFieldStringValue = "\(base.isEmpty ? "backup" : base)-\(stamp).\(ext)"
        if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        phase = .running
        log = ""
        Task {
            var includeRoutines = true
            var preamble = ""
            if family == .mysql, content != .data, let exe = toolPath {
                let server = workspace.serverVersion
                let clientVersion = await Task.detached { DumpTool.clientVersionString(exe) }.value
                if !DumpTool.mysqldumpCanDumpRoutines(clientVersion: clientVersion, serverVersion: server) {
                    includeRoutines = false
                    let db = connection.database
                    let sql = "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = \(workspace.dialect.literal(db))"
                    let n = Int((try? await workspace.run { try $0.scalar(sql) }) ?? nil ?? "") ?? 0
                    if n > 0 {
                        preamble = "Warning: this mysqldump (\(clientVersion.trimmingCharacters(in: .whitespacesAndNewlines))) cannot dump stored routines from a \(server) server; \(n) routine\(n == 1 ? " was" : "s were") skipped. Use a mysqldump matching the server version (Settings › Tools) to include them.\n"
                    }
                }
            }
            do {
                let cmd = try DumpTool.backupCommand(connection, content: content, pgFormat: pgFormat, includeDrop: includeDrop, includeRoutines: includeRoutines, output: url)
                outputURL = url
                run(cmd, preamble: preamble)
            } catch let e as ToolNotFoundError {
                phase = .failed(e.localizedDescription, toolMissing: true)
            } catch {
                phase = .failed(error.localizedDescription, toolMissing: false)
            }
        }
    }

    func restore() {
        guard case .restore(let url) = mode else { return }
        let target = family == .sqlite ? connection.filePath : connection.database
        guard workspace.approveWrites(["RESTORE DATABASE \(target) FROM '\(url.lastPathComponent)'"]) else { return }
        do {
            let cmd = try DumpTool.restoreCommand(connection, input: url, singleTransaction: singleTransaction, clean: clean)
            run(cmd)
        } catch let e as ToolNotFoundError {
            phase = .failed(e.localizedDescription, toolMissing: true)
        } catch {
            phase = .failed(error.localizedDescription, toolMissing: false)
        }
    }

    private func append(_ s: String) {
        log += s
        if log.count > 200_000 { log = "…\n" + String(log.suffix(150_000)) }
    }

    private func run(_ cmd: ToolCommand, preamble: String = "") {
        phase = .running
        log = preamble + "$ \(cmd.displayString)\n"
        let started = Date()
        let p = ToolProcess(cmd)
        process = p
        p.start(output: { [weak self] text in
            DispatchQueue.main.async { self?.append(text) }
        }, completion: { [weak self] status, launchError in
            DispatchQueue.main.async { self?.finished(status: status, launchError: launchError, tool: cmd.toolName, started: started) }
        })
    }

    private func finished(status: Int32, launchError: String?, tool: String, started: Date) {
        let cancelled = process?.wasCancelled ?? false
        process = nil
        let elapsed = Date().timeIntervalSince(started)
        let duration = elapsed < 60 ? String(format: "%.1f s", elapsed) : String(format: "%d min %02d s", Int(elapsed) / 60, Int(elapsed) % 60)
        if let launchError { append(launchError + "\n") }
        let ok = status == 0 && launchError == nil && !cancelled
        switch mode {
        case .backup:
            if ok, let url = outputURL {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                phase = .succeeded("Backup saved to \(url.lastPathComponent) (\(ioByteString(size)), \(duration)).")
                workspace.showToast("Backup of \(databaseLabel) saved")
            } else {
                if let url = outputURL { try? FileManager.default.removeItem(at: url) }
                phase = .failed(cancelled ? "Backup cancelled." : "\(tool) failed (exit status \(status)). See the log for details.", toolMissing: false)
            }
        case .restore:
            if ok {
                phase = .succeeded("Restore into \(databaseLabel) completed in \(duration).")
                workspace.showToast("Restored \(databaseLabel)")
            } else {
                phase = .failed(cancelled ? "Restore cancelled — the database may be partially restored." : "\(tool) failed (exit status \(status)). See the log for details.", toolMissing: false)
            }
            workspace.logHistory("-- Restore \(databaseLabel) from file", duration: elapsed, success: ok)
            let ws = workspace
            Task {
                await ws.syncCurrentDatabase()
                await ws.reloadObjects()
                for t in ws.tabs { if case .table(let s) = t.content, s.dataLoaded, !s.hasChanges { await s.reload() } }
            }
        }
    }

    func cancel() {
        if phase == .running {
            process?.cancel()
        } else {
            close()
        }
    }

    func revealOutput() {
        if let outputURL { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
    }

    func openToolSettings() {
        close()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct DumpSheet: View {
    @Bindable var model: DumpSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSheetHeader(icon: model.isBackup ? "externaldrive.badge.timemachine" : "arrow.counterclockwise.circle",
                          title: model.title, subtitle: model.subtitle)

            if model.phase == .options {
                if model.isBackup { backupOptions } else { restoreOptions }
                toolLine
            } else {
                status
                IOLogView(text: model.log, minHeight: 200)
            }

            footer
        }
        .padding(20)
        .frame(width: 600)
    }

    // MARK: Options

    private var backupOptions: some View {
        Form {
            Picker("Include:", selection: $model.content) {
                ForEach(DumpContent.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if model.family == .postgres {
                Picker("Format:", selection: $model.pgFormat) {
                    ForEach(PGDumpFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            if model.family != .sqlite {
                Toggle(model.family == .postgres ? "Add DROP … IF EXISTS before CREATE statements" : "Add DROP TABLE before CREATE TABLE",
                       isOn: $model.includeDrop)
                    .disabled(model.content == .data)
            }
        }
        .formStyle(.columns)
    }

    private var restoreOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("File:").foregroundStyle(.secondary)
                    if case .restore(let url) = model.mode {
                        Text("\(url.lastPathComponent) · \(ioByteString(model.inputSize))").lineLimit(1).truncationMode(.middle)
                    }
                }
                GridRow {
                    Text("Format:").foregroundStyle(.secondary)
                    Text(model.isCustomArchive ? "pg_dump custom archive (restored with pg_restore)" : "SQL script")
                }
                GridRow {
                    Text("Target:").foregroundStyle(.secondary)
                    Text(model.connection.targetDescription).fontWeight(.semibold)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isCustomArchive ? "This archive will be restored into “\(model.databaseLabel)”." : "Every statement in this file will run against “\(model.databaseLabel)”.").fontWeight(.semibold)
                    Text("Existing tables and data in this database may be overwritten or dropped. This cannot be undone.\(model.workspace.config.tag == .production ? " This connection is tagged Production." : "")")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            if model.family == .postgres {
                Toggle("Restore in a single transaction (all or nothing)", isOn: $model.singleTransaction)
                if model.isCustomArchive {
                    Toggle("Drop existing objects before recreating them (--clean)", isOn: $model.clean)
                }
            }
        }
    }

    @ViewBuilder
    private var toolLine: some View {
        if let p = model.toolPath {
            Text("Uses \(p)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("\(model.toolName) was not found. Set its location in Settings › Tools.").font(.callout)
                Button("Open Settings…") { model.openToolSettings() }.controlSize(.small)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isBackup ? "Backing up with \(model.toolName)…" : "Restoring with \(model.toolName)…")
            }
        case .succeeded(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg, let missing):
            HStack(spacing: 8) {
                Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if missing { Button("Open Settings…") { model.openToolSettings() }.controlSize(.small) }
            }
        case .options:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if case .succeeded = model.phase, model.isBackup {
                Button("Show in Finder") { model.revealOutput() }
            }
            Spacer()
            switch model.phase {
            case .options:
                Button("Cancel", role: .cancel) { model.close() }.keyboardShortcut(.cancelAction)
                if model.isBackup {
                    Button("Back Up…") { model.backup() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.toolPath == nil)
                } else {
                    Button("Restore", role: .destructive) { model.restore() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.toolPath == nil)
                }
            case .running:
                Button("Stop", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
            case .succeeded, .failed:
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
