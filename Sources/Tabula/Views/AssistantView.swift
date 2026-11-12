import SwiftUI
import AppKit

/// AI SQL assistant chat, shown in the right inspector panel.
struct AssistantView: View {
    let ws: WorkspaceState

    var body: some View {
        let assistant = ws.assistant
        Group {
            if assistant.hasAPIKey {
                AssistantChatView(ws: ws, assistant: assistant)
            } else {
                AssistantSetupView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { assistant.refreshKeyStatus() }
    }
}

// MARK: - Setup state

private struct AssistantSetupView: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
            Text("AI SQL Assistant").font(.headline)
            Text("Ask Claude to write, explain, fix and optimize queries using your schema. Only table and column definitions are shared — never row data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                
            Text("Add your Anthropic API key to get started.")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button {
                openSettings()
            } label: {
                Label("Open AI Settings…", systemImage: "key")
            }
            .controlSize(.large)
            Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Chat

private struct AssistantChatView: View {
    let ws: WorkspaceState
    @Bindable var assistant: AssistantState
    @AppStorage(SettingsKey.anthropicModel) private var modelSetting = AnthropicAPI.defaultModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if assistant.messages.isEmpty {
                emptyState
            } else {
                messageList
            }
            Divider()
            quickActions
            inputArea
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text(modelSetting.isEmpty ? AnthropicAPI.defaultModel : modelSetting)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Model — change it in Settings → AI")
            Spacer(minLength: 4)
            Button {
                assistant.newChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("New chat")
            .disabled(assistant.messages.isEmpty && assistant.draft.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask about \(ws.currentDatabase.isEmpty ? ws.config.displayName : ws.currentDatabase)")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Claude sees your table and column definitions and the current query — never row data. Mention @table to include a specific table.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(assistant.messages) { m in
                        AssistantMessageView(ws: ws, assistant: assistant, message: m)
                            .id(m.id)
                    }
                    if let status = assistant.status {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 2)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: assistant.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: assistant.messages.last?.text.count ?? 0) { _, _ in
                if assistant.isStreaming { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], spacing: 6) {
            ForEach(AssistantState.QuickAction.allCases, id: \.self) { action in
                Button {
                    assistant.perform(action, ws: ws)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(!assistant.canRun(action, ws: ws))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var inputArea: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AssistantInputField(text: $assistant.draft,
                                placeholder: "Ask about your data… (⌘↩ to send)",
                                focusRequest: assistant.focusRequest,
                                onSubmit: { assistant.sendDraft(ws: ws) })
                .frame(height: 70)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                if let att = AssistantContext.editorAttachment(ws: ws) {
                    Label(att.label, systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("The current editor query is attached to your next message when it has changed")
                }
                Spacer()
                if assistant.isStreaming {
                    Button(role: .cancel) {
                        assistant.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        assistant.sendDraft(ws: ws)
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (⌘↩)")
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Message bubbles

private struct AssistantMessageView: View {
    let ws: WorkspaceState
    let assistant: AssistantState
    let message: AssistantState.Message

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantReply
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 28)
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .textSelection(.enabled)
                    
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                if let att = message.attachment {
                    Label(att, systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var assistantReply: some View {
        if message.isError {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(message.text).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                HStack {
                    if message.errorStatus == 401 || message.errorStatus == 403 || message.errorStatus == 404 {
                        SettingsLink { Text("Open Settings…") }.controlSize(.small)
                    }
                    if message.id == assistant.messages.last?.id {
                        Button("Retry") { assistant.retry(ws: ws) }
                            .controlSize(.small)
                            .disabled(assistant.isStreaming)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AssistantMarkdown.segments(message.text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .prose(let s):
                        AssistantProseView(text: s)
                    case .code(let lang, let code, let complete):
                        AssistantCodeCard(ws: ws, language: lang, code: code, complete: complete)
                    }
                }
                if let note = message.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AssistantProseView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AssistantMarkdown.proseBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    inline(t).font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 2)
                case .listItem(let marker, let t, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        inline(t)
                    }
                    .padding(.leading, CGFloat(indent) * 12)
                case .quote(let t):
                    inline(t)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                case .paragraph(let t):
                    inline(t)
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> some View {
        let attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        return Text(attr)
            
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SQL cards

private struct AssistantCodeCard: View {
    let ws: WorkspaceState
    let language: String
    let code: String
    let complete: Bool
    @State private var copied = false

    private var runnable: Bool { AssistantMarkdown.isRunnable(language) }
    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(language.isEmpty ? (runnable ? "SQL" : "CODE") : language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !complete { ProgressView().controlSize(.mini).padding(.trailing, 4) }
                cardButton(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                if runnable {
                    cardButton("Insert into editor", symbol: "text.insert") { insert() }
                        .disabled(!complete)
                    cardButton("Run in new tab", symbol: "play.fill") {
                        ws.newQueryTab(sql: trimmed, title: "Assistant", run: true)
                    }
                    .disabled(!complete || !ws.isConnected)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6))
            ScrollView(.horizontal) {
                Text(highlighted)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func cardButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private func insert() {
        if let q = ws.selectedQueryTab {
            q.request(.insert(trimmed))
        } else {
            ws.newQueryTab(sql: trimmed, title: "Assistant")
        }
    }

    private var highlighted: AttributedString {
        guard runnable, language.lowercased() != "redis", code.utf16.count < 50_000 else { return AttributedString(code) }
        let ns = NSMutableAttributedString(string: code)
        let str = code as NSString
        for t in SQLTokenizer.tokenize(code) {
            let color: NSColor?
            switch t.kind {
            case .comment: color = .systemGray
            case .string: color = .systemRed
            case .number: color = .systemOrange
            case .quotedIdentifier: color = .systemTeal
            case .parameter: color = .systemPink
            case .word:
                let w = str.substring(with: t.range).uppercased()
                color = SQLKeywords.keywordSet.contains(w) ? .systemBlue : SQLKeywords.functionSet.contains(w) ? .systemPurple : nil
            default: color = nil
            }
            if let color { ns.addAttribute(.foregroundColor, value: color, range: t.range) }
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(code)
    }
}

// MARK: - Input field (⌘↩ sends; plain ↩ inserts a newline)

struct AssistantInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let old = scroll.documentView as! NSTextView
        let tv = SubmitTextView(frame: old.frame, textContainer: old.textContainer)
        tv.autoresizingMask = old.autoresizingMask
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = old.minSize
        tv.maxSize = old.maxSize
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        tv.onSubmit = { context.coordinator.parent.onSubmit() }
        tv.string = text
        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        tv.placeholder = placeholder
        tv.needsDisplay = true
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantInputField
        weak var textView: SubmitTextView?
        var lastFocusRequest: Int

        init(_ parent: AssistantInputField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var placeholder = ""

        private func isSubmit(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return (event.keyCode == 36 || event.keyCode == 76) && flags.contains(.command) && !flags.contains(.shift)
        }

        // Intercept ⌘↩ before the main menu's "Run Statement" sees it — only while this field has focus.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, isSubmit(event) {
                onSubmit?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if isSubmit(event) { onSubmit?(); return }
            super.keyDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty && !placeholder.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.placeholderTextColor,
                ]
                let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                                     y: textContainerInset.height)
                (placeholder as NSString).draw(at: origin, withAttributes: attrs)
            }
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }
    }
}
