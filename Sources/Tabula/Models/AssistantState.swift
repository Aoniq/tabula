import Foundation
import SwiftUI
import Observation

// STUB — replaced by the AI assistant implementation.
@MainActor
@Observable
final class AssistantState {
    init() {}
}

struct AssistantView: View {
    let ws: WorkspaceState
    var body: some View { Text("AI assistant — coming soon").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct AssistantSettingsView: View {
    var body: some View { Form { Text("AI settings — coming soon") } }
}
