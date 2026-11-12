import Foundation
import SwiftUI
import Observation

// STUB — replaced by the metrics dashboard implementation.
@MainActor
@Observable
final class DashboardState {
    weak var workspace: WorkspaceState?
    init(workspace: WorkspaceState) { self.workspace = workspace }
    func refreshAll() async {}
}

struct DashboardView: View {
    @Bindable var state: DashboardState
    var body: some View { Text("Metrics dashboard — coming soon").foregroundStyle(.secondary) }
}
