import Foundation

/// Splits an assistant reply into prose and fenced code blocks.
enum AssistantMarkdown {
    enum Segment: Equatable {
        case prose(String)
        /// `complete` is false while the closing fence hasn't streamed in yet.
        case code(language: String, code: String, complete: Bool)
    }

    /// Fence languages whose blocks get Insert / Run buttons.
    static let runnableLanguages: Set<String> = ["", "sql", "postgresql", "postgres", "pgsql", "psql", "plpgsql", "mysql", "mariadb", "sqlite", "redis"]

    static func isRunnable(_ language: String) -> Bool {
        runnableLanguages.contains(language.lowercased())
    }

    static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var fence: (marker: String, lang: String)?

        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.prose(s)) }
            prose = []
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if trimmed.hasPrefix(f.marker) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: f.marker.prefix(1) + " ")).isEmpty {
                    out.append(.code(language: f.lang, code: code.joined(separator: "\n"), complete: true))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if let marker = fenceMarker(trimmed) {
                flushProse()
                let lang = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                fence = (marker, lang.lowercased())
            } else {
                prose.append(line)
            }
        }
        if let f = fence {
            out.append(.code(language: f.lang, code: code.joined(separator: "\n"), complete: false))
        } else {
            flushProse()
        }
        return out
    }

    /// Runnable code blocks (SQL) in a reply.
    static func sqlBlocks(_ text: String) -> [String] {
        segments(text).compactMap {
            if case .code(let lang, let code, true) = $0, isRunnable(lang) { return code }
            return nil
        }
    }

    // MARK: Prose blocks (SwiftUI's markdown Text only handles inline styles)

    enum ProseBlock: Equatable {
        case heading(level: Int, text: String)
        case listItem(marker: String, text: String, indent: Int)
        case quote(String)
        case paragraph(String)
        case rule
    }

    static func proseBlocks(_ prose: String) -> [ProseBlock] {
        var out: [ProseBlock] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        for raw in prose.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = (line.prefix { $0 == " " }.count) / 2
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.hasPrefix(" ") {
                    flush(); out.append(.heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))); continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); out.append(.rule); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); out.append(.listItem(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent)); continue
            }
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), dot > trimmed.startIndex,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[..<dot].count <= 3,
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.listItem(marker: String(trimmed[...dot]), text: trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces), indent: indent))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush(); out.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))); continue
            }
            para.append(trimmed)
        }
        flush()
        return out
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for ch in ["`", "~"] {
            let run = trimmed.prefix { String($0) == ch }
            if run.count >= 3 {
                // Backtick fences can't contain backticks in the info string.
                if ch == "`" && trimmed.dropFirst(run.count).contains("`") { return nil }
                return String(run)
            }
        }
        return nil
    }
}
