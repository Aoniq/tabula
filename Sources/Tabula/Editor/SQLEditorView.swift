import SwiftUI
import AppKit

struct CompletionItem: Hashable {
    enum Kind { case keyword, function, table, view, column, schema, snippet, saved }
    var text: String
    var kind: Kind
    var detail: String = ""
    var insertText: String? = nil

    var badge: String {
        switch kind {
        case .keyword: return "K"
        case .function: return "ƒ"
        case .table: return "T"
        case .view: return "V"
        case .column: return "C"
        case .schema: return "S"
        case .snippet: return "⌘"
        case .saved: return "★"
        }
    }

    var badgeColor: NSColor {
        switch kind {
        case .keyword: return .systemBlue
        case .function: return .systemPurple
        case .table: return .systemGreen
        case .view: return .systemTeal
        case .column: return .systemOrange
        case .schema: return .systemBrown
        case .snippet, .saved: return .systemPink
        }
    }
}

/// Supplies completion candidates. Implemented by the query tab view.
@MainActor
protocol CompletionSource: AnyObject {
    func completions(prefix: String, qualifier: String?, fullText: String) -> [CompletionItem]
}

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var request: EditorRequest?
    var requestID: Int
    var fontSize: CGFloat
    var completionSource: CompletionSource?
    var onSelectionChange: (NSRange) -> Void
    var redisMode = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = SQLTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.redisMode = redisMode
        tv.applyFont(size: fontSize)
        tv.string = text
        tv.delegate = context.coordinator
        tv.completionSource = completionSource
        scroll.documentView = tv

        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak ruler, weak tv] _ in
            ruler?.needsDisplay = true
            MainActor.assumeIsolated { tv?.completion.hide() }
        }
        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        tv.highlight()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self
        tv.completionSource = completionSource
        tv.redisMode = redisMode
        if tv.currentFontSize != fontSize {
            tv.applyFont(size: fontSize)
            tv.highlight()
        }
        if requestID != context.coordinator.lastRequestID {
            context.coordinator.lastRequestID = requestID
            if let request { context.coordinator.perform(request) }
        } else if tv.string != text && !context.coordinator.isUpdating {
            tv.string = text
            tv.highlight()
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        weak var ruler: LineNumberRuler?
        var lastRequestID = 0
        var isUpdating = false

        init(_ parent: SQLEditorView) {
            self.parent = parent
            self.lastRequestID = parent.requestID
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isUpdating = true
            parent.text = tv.string
            isUpdating = false
            tv.highlight()
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.onSelectionChange(tv.selectedRange())
        }

        func perform(_ r: EditorRequest) {
            guard let tv = textView else { return }
            switch r {
            case .insert(let s):
                let range = tv.selectedRange()
                if tv.shouldChangeText(in: range, replacementString: s) {
                    tv.replaceCharacters(in: range, with: s)
                    tv.didChangeText()
                }
            case .replaceAll(let s):
                let range = NSRange(location: 0, length: (tv.string as NSString).length)
                if tv.shouldChangeText(in: range, replacementString: s) {
                    tv.replaceCharacters(in: range, with: s)
                    tv.didChangeText()
                }
            case .select(let range):
                let len = (tv.string as NSString).length
                tv.setSelectedRange(NSRange(location: min(range.location, len), length: min(range.length, max(0, len - range.location))))
                tv.scrollRangeToVisible(tv.selectedRange())
            case .focus:
                tv.window?.makeFirstResponder(tv)
            }
        }
    }
}

// MARK: - Text view

final class SQLTextView: NSTextView {
    weak var completionSource: CompletionSource?
    lazy var completion = CompletionPopup(textView: self)
    var redisMode = false
    private(set) var currentFontSize: CGFloat = 13

    func applyFont(size: CGFloat) {
        currentFontSize = size
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        font = f
        typingAttributes = [.font: f, .foregroundColor: NSColor.textColor]
    }

    // MARK: Highlighting

    func highlight() {
        guard let storage = textStorage else { return }
        let text = string
        let full = NSRange(location: 0, length: (text as NSString).length)
        let font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        if full.length < 400_000 {
            let ns = text as NSString
            for t in SQLTokenizer.tokenize(text) {
                let color: NSColor?
                switch t.kind {
                case .comment: color = .systemGray
                case .string: color = .systemRed
                case .number: color = .systemOrange
                case .quotedIdentifier: color = .systemTeal
                case .parameter: color = .systemPink
                case .word:
                    let w = ns.substring(with: t.range).uppercased()
                    if redisMode {
                        color = t.range.location == 0 || ns.character(at: t.range.location - 1) == 10 ? .systemBlue : nil
                    } else if SQLKeywords.keywordSet.contains(w) {
                        color = .systemBlue
                    } else if SQLKeywords.functionSet.contains(w) {
                        color = .systemPurple
                    } else {
                        color = nil
                    }
                default: color = nil
                }
                if let color { storage.addAttribute(.foregroundColor, value: color, range: t.range) }
            }
        }
        storage.endEditing()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if completion.isVisible {
            switch event.keyCode {
            case 125: completion.move(1); return
            case 126: completion.move(-1); return
            case 36, 76, 48: completion.accept(); return
            case 53: completion.hide(); return
            default: break
            }
        }
        // ⌃Space → explicit completion
        if event.keyCode == 49 && event.modifierFlags.contains(.control) {
            updateCompletion(explicit: true)
            return
        }
        super.keyDown(with: event)
        guard Settings.autocomplete, !event.modifierFlags.contains(.command) else {
            completion.hide()
            return
        }
        if let chars = event.characters, let scalar = chars.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." {
            updateCompletion(explicit: false)
        } else if event.keyCode == 51 && completion.isVisible {
            updateCompletion(explicit: false)
        } else {
            completion.hide()
        }
    }

    override func complete(_ sender: Any?) {
        updateCompletion(explicit: true)
    }

    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        // keep indentation of the current line
        let ns = string as NSString
        let loc = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: max(0, loc - lineRange.location)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    override func resignFirstResponder() -> Bool {
        completion.hide()
        return super.resignFirstResponder()
    }

    /// Toggle `-- ` comments on the selected lines.
    @objc func toggleComment() {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let block = ns.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let trailingNewline = parts.last == ""
        if trailingNewline { parts.removeLast() }
        let allCommented = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let newParts = parts.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                if let r = line.range(of: "-- ") ?? line.range(of: "--") { return line.replacingCharacters(in: r, with: "") }
                return line
            }
            return "-- " + line
        }
        let replacement = newParts.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        if shouldChangeText(in: lines, replacementString: replacement) {
            replaceCharacters(in: lines, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
        }
    }

    // MARK: Completion

    /// Current partial word range (identifier chars) before the cursor, plus an optional qualifier before a dot.
    func partialWord() -> (range: NSRange, prefix: String, qualifier: String?) {
        let ns = string as NSString
        let cursor = selectedRange().location
        var start = cursor
        func isIdent(_ c: unichar) -> Bool {
            guard let s = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(s) || c == 95 || c == 36
        }
        while start > 0 && isIdent(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: cursor - start))
        var qualifier: String?
        if start > 0 && ns.character(at: start - 1) == 46 { // "."
            var qs = start - 1
            var q = qs
            // allow quoted qualifier "x". or `x`.
            if qs > 0 && (ns.character(at: qs - 1) == 34 || ns.character(at: qs - 1) == 96) {
                let quote = ns.character(at: qs - 1)
                q = qs - 1
                var k = q - 1
                while k >= 0 && ns.character(at: k) != quote { k -= 1 }
                if k >= 0 { qualifier = ns.substring(with: NSRange(location: k + 1, length: q - k - 1)) }
            } else {
                while qs > 0 && isIdent(ns.character(at: qs - 1)) { qs -= 1 }
                qualifier = ns.substring(with: NSRange(location: qs, length: q - qs))
            }
        }
        return (NSRange(location: start, length: cursor - start), prefix, qualifier)
    }

    func updateCompletion(explicit: Bool) {
        guard let source = completionSource, !redisMode else { return }
        // Don't complete inside strings or comments
        let cursor = selectedRange().location
        if selectedRange().length > 0 { completion.hide(); return }
        for t in SQLTokenizer.tokenize(string) where (t.kind == .string || t.kind == .comment) && cursor > t.range.location && cursor <= NSMaxRange(t.range) {
            if !(t.kind == .comment && cursor == NSMaxRange(t.range) && string.hasSuffix("\n")) {
                completion.hide()
                return
            }
        }
        let p = partialWord()
        if !explicit && p.qualifier == nil && p.prefix.count < 2 {
            completion.hide()
            return
        }
        let items = source.completions(prefix: p.prefix, qualifier: p.qualifier, fullText: string)
        if items.isEmpty || (items.count == 1 && items[0].text == p.prefix) {
            completion.hide()
            return
        }
        completion.show(items: items, replacing: p.range)
    }

    func insertCompletion(_ item: CompletionItem, replacing range: NSRange) {
        var text = item.insertText ?? item.text
        if item.kind == .keyword || item.kind == .function {
            text = Settings.uppercaseKeywords ? text.uppercased() : text.lowercased()
        }
        let r = NSRange(location: range.location, length: max(0, selectedRange().location - range.location))
        if shouldChangeText(in: r, replacementString: text) {
            replaceCharacters(in: r, with: text)
            didChangeText()
        }
    }
}

// MARK: - Line numbers

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 13) - 2), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let ns = tv.string as NSString

        var line = 1
        var i = 0
        let start = charRange.location
        while i < start {
            if ns.character(at: i) == 10 { line += 1 }
            i += 1
        }
        let inset = tv.textContainerInset.height
        var index = start
        let end = NSMaxRange(charRange)
        func draw(_ n: Int, y: CGFloat, height: CGFloat) {
            let s = "\(n)" as NSString
            let size = s.size(withAttributes: attrs)
            let p = convert(NSPoint(x: 0, y: y + inset), from: tv)
            s.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: p.y + (height - size.height) / 2), withAttributes: attrs)
        }
        if ns.length == 0 {
            draw(1, y: 0, height: font.pointSize + 4)
            return
        }
        while index < end {
            let lr = ns.lineRange(for: NSRange(location: index, length: 0))
            let g = lm.glyphIndexForCharacter(at: lr.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            draw(line, y: frag.minY, height: frag.height)
            line += 1
            index = NSMaxRange(lr)
        }
        if end == ns.length && ns.length > 0 && ns.character(at: ns.length - 1) == 10 {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 { draw(line, y: extra.minY, height: extra.height) }
        }
        let digits = max(2, String(line).count)
        let needed = CGFloat(digits) * (font.pointSize * 0.62) + 16
        if abs(needed - ruleThickness) > 1 { ruleThickness = needed }
    }
}

// MARK: - Completion popup

@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var textView: SQLTextView?
    private var panel: NSPanel?
    private var table: NSTableView?
    private var items: [CompletionItem] = []
    private var replaceRange = NSRange(location: 0, length: 0)

    init(textView: SQLTextView) {
        self.textView = textView
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let t = NSTableView()
        t.headerView = nil
        t.backgroundColor = .clear
        t.rowHeight = 20
        t.intercellSpacing = NSSize(width: 0, height: 0)
        t.style = .plain
        t.addTableColumn(NSTableColumn(identifier: .init("item")))
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(doubleClicked)
        scroll.documentView = t
        effect.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
        p.contentView = effect
        table = t
        return p
    }

    func show(items: [CompletionItem], replacing range: NSRange) {
        guard let tv = textView, let window = tv.window else { return }
        self.items = items
        self.replaceRange = range
        let p = panel ?? makePanel()
        panel = p
        table?.reloadData()
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table?.scrollRowToVisible(0)
        let caret = tv.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let height = CGFloat(min(items.count, 10)) * 20 + 8
        var frame = NSRect(x: caret.minX - 24, y: caret.minY - height - 2, width: 380, height: height)
        if let screen = window.screen, frame.minY < screen.visibleFrame.minY {
            frame.origin.y = caret.maxY + 2
        }
        p.setFrame(frame, display: true)
        if p.parent == nil { window.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard let t = table, !items.isEmpty else { return }
        let row = min(max(0, t.selectedRow + delta), items.count - 1)
        t.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        t.scrollRowToVisible(row)
    }

    func accept() {
        guard let t = table, t.selectedRow >= 0, t.selectedRow < items.count else { hide(); return }
        let item = items[t.selectedRow]
        hide()
        textView?.insertCompletion(item, replacing: replaceRange)
    }

    @objc private func doubleClicked() { accept() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell) ?? CompletionCell()
        cell.identifier = id
        cell.configure(item)
        return cell
    }
}

final class CompletionCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for v in [badge, title, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        title.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: CompletionItem) {
        badge.stringValue = item.badge
        badge.textColor = .white
        badge.layer?.backgroundColor = item.badgeColor.cgColor
        title.stringValue = item.text
        detail.stringValue = item.detail
    }
}
