import SwiftUI
import AppKit
import Observation

/// Executes a large SQL file statement by statement with progress (stops at the first error).
@MainActor
@Observable
final class SQLFileRunModel {
    enum Phase: Equatable {
        case reading
        case running
        case failed(statementNumber: Int, statement: String, error: String)
        case finished
    }

    let workspace: WorkspaceState
    let url: URL
    let fileSize: Int
    var phase: Phase = .reading
    var executed = 0
    var total = 0
    var currentPreview = ""
    var cancelRequested = false
    var started = Date()
    var close: () -> Void = {}

    init(workspace: WorkspaceState, url: URL, fileSize: Int) {
        self.workspace = workspace
        self.url = url
        self.fileSize = fileSize
    }

    /// Split a script into executable units (lines for Redis, statements otherwise).
    nonisolated static func split(_ text: String, family: DatabaseFamily) -> [String] {
        if family == .redis {
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        return SQLTokenizer.statements(text)
    }

    /// Run statements starting at `from` until ~0.3 s have passed. Returns how many succeeded and
    /// the error of the statement that failed (if any). Runs on the DB queue.
    nonisolated static func runChunk(_ d: DatabaseDriver, statements: [String], from: Int, maxCount: Int = 500) -> (Int, Error?) {
        let deadline = Date().addingTimeInterval(0.3)
        var i = from
        while i < statements.count && i - from < maxCount {
            do { _ = try d.execute(statements[i]) } catch { return (i - from, error) }
            i += 1
            if Date() > deadline { break }
        }
        return (i - from, nil)
    }

    func start() {
        let ws = workspace
        let url = url
        let family = ws.family
        started = Date()
        Task {
            let stmts: [String]? = await Task.detached(priority: .userInitiated) {
                ImportController.readText(url).map { SQLFileRunModel.split($0, family: family) }
            }.value
            guard let stmts else {
                close()
                ws.showToast("Could not read \(url.lastPathComponent)", error: true)
                return
            }
            guard !cancelRequested else { close(); return }
            guard !stmts.isEmpty else {
                close()
                ws.showToast("\(url.lastPathComponent) contains no statements")
                return
            }
            total = stmts.count
            guard ws.approveWrites(stmts) else { close(); return }
            phase = .running
            var hadDDL = false
            while executed < stmts.count && !cancelRequested {
                currentPreview = Self.preview(stmts[executed])
                let from = executed
                let result: (Int, Error?)
                do {
                    result = try await ws.run { Self.runChunk($0, statements: stmts, from: from) }
                } catch {
                    result = (0, error)
                }
                for s in stmts[from..<(from + result.0)] where !hadDDL {
                    let kw = SQLTokenizer.leadingKeywords(s, count: 1).first ?? ""
                    if ["CREATE", "DROP", "ALTER", "RENAME", "TRUNCATE", "USE"].contains(kw) { hadDDL = true }
                }
                executed += result.0
                if let error = result.1 {
                    if cancelRequested { break }   // interrupted by Stop
                    let failing = stmts[executed]
                    phase = .failed(statementNumber: executed + 1, statement: String(failing.prefix(20_000)), error: error.localizedDescription)
                    ws.logHistory("-- \(url.lastPathComponent): statement \(executed + 1) of \(stmts.count) failed\n" + String(failing.prefix(2000)),
                                  duration: Date().timeIntervalSince(started), success: false)
                    break
                }
            }
            if phase == .running {
                phase = .finished
                ws.logHistory("-- Ran \(url.lastPathComponent): \(executed) of \(stmts.count) statements\(cancelRequested ? " (stopped)" : "")",
                              duration: Date().timeIntervalSince(started), success: true)
                close()
                ws.showToast(cancelRequested ? "Stopped after \(executed.ioGrouped) of \(stmts.count.ioGrouped) statements"
                                             : "Executed \(executed.ioGrouped) statements from \(url.lastPathComponent)")
            }
            if hadDDL || executed > 0 {
                await ws.syncCurrentDatabase()
                await ws.reloadObjects()
            }
        }
    }

    private static func preview(_ s: String) -> String {
        let oneLine = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
    }

    func cancel() {
        switch phase {
        case .reading, .running:
            cancelRequested = true
            workspace.cancelRunning()
        default:
            close()
        }
    }
}

struct SQLFileRunSheet: View {
    @Bindable var model: SQLFileRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSheetHeader(icon: "doc.text", title: "Run “\(model.url.lastPathComponent)”",
                          subtitle: "\(ioByteString(model.fileSize)) · \(model.workspace.config.displayName)")

            switch model.phase {
            case .reading:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().progressViewStyle(.linear)
                    Text("Reading and splitting statements…").font(.callout).foregroundStyle(.secondary)
                }
            case .running, .finished:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(model.executed), total: Double(max(model.total, 1)))
                    Text(model.cancelRequested ? "Stopping…" : "Statement \(min(model.executed + 1, model.total).ioGrouped) of \(model.total.ioGrouped)")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text(model.currentPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            case .failed(let n, let statement, let error):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Statement \(n.ioGrouped) of \(model.total.ioGrouped) failed — execution stopped", systemImage: "exclamationmark.triangle.fill")
                        .font(.body.weight(.semibold)).foregroundStyle(.red)
                    Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    IOLogView(text: statement, minHeight: 150)
                    Text("\(model.executed.ioGrouped) statement\(model.executed == 1 ? " was" : "s were") executed before the error and were not rolled back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                switch model.phase {
                case .failed, .finished:
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                default:
                    Button("Stop", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.cancelRequested)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
