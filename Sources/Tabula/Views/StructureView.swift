import SwiftUI

// STUB — replaced by the structure-editor implementation.
struct StructureView: View {
    @Bindable var tab: TableTabState
    var body: some View {
        List(tab.columns) { c in
            HStack { Text(c.name); Spacer(); Text(c.type).foregroundStyle(.secondary) }
        }
    }
}

struct CreateTableSheet: View {
    let ws: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack { Text("Create table — coming soon"); Button("Close") { dismiss() } }.padding().frame(width: 400, height: 200)
    }
}
