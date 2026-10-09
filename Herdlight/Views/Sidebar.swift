import HerdrKit
import SwiftUI

/// The session picker and herdr's workspaces, in herdr's order.
struct Sidebar: View {
    @Binding var store: HostStore

    var body: some View {
        List(selection: $store.selectedWorkspaceID) {
            ForEach(store.workspaces) { WorkspaceRow(workspace: $0) }
        }
        .safeAreaInset(edge: .top) {
            Menu {
                ForEach(store.sessions, id: \.name) { session in
                    Button(HostStore.name(session.name)) {
                        if session.name != store.session {
                            store = HostStore(session: session.name)
                        }
                    }
                    .disabled(!session.running)
                }
            } label: {
                Label(HostStore.name(store.session), systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 10)
            .accessibilityIdentifier("sidebar.session-picker")
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 240)
    }
}

private struct WorkspaceRow: View {
    let workspace: HostStore.Workspace

    var body: some View {
        HStack {
            Text(workspace.label)
            Spacer()
            StatusGlyph(status: workspace.status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace.\(workspace.id)")
    }
}
