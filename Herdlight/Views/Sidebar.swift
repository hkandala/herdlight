import SwiftUI

/// herdr's workspaces as sections with their tabs as rows, and a filter at the bottom.
struct Sidebar: View {
    let store: HostStore
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.workspaces) { workspace in
                        let tabs = shown(workspace)
                        if !tabs.isEmpty {
                            header(workspace)
                            ForEach(tabs) { row($0, in: workspace) }
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            HStack(spacing: 2) {
                FilterField(prompt: "Filter", text: $filter, identifier: "sidebar.filter")
                    .padding(.trailing, 4)
                // ponytail: no-op until sessions can be created
                IconButton(symbol: "rectangle.stack.badge.plus", help: "New Session") {}
                // ponytail: no-op until remote hosts
                IconButton(symbol: "network", help: "Add Remote Host") {}
            }
            .padding(8)
        }
        .frame(width: 240)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    /// The tabs whose label matches the filter; all of them when the workspace's label matches.
    private func shown(_ workspace: HostStore.Workspace) -> [HostStore.Tab] {
        if filter.isEmpty || workspace.label.localizedCaseInsensitiveContains(filter) {
            return workspace.tabs
        }
        return workspace.tabs.filter { $0.label.localizedCaseInsensitiveContains(filter) }
    }

    private func header(_ workspace: HostStore.Workspace) -> some View {
        Button { store.selectedWorkspaceID = workspace.id } label: {
            HStack {
                Text(workspace.label)
                Spacer()
                StatusGlyph(status: workspace.status)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, workspace.id == store.workspaces.first?.id ? 2 : 12)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.\(workspace.id)")
    }

    private func row(_ tab: HostStore.Tab, in workspace: HostStore.Workspace) -> some View {
        let selected = workspace.id == store.selectedWorkspaceID && tab.id == workspace.selectedTabID
        return Button {
            store.selectedWorkspaceID = workspace.id
            workspace.selectedTabID = tab.id
        } label: {
            HStack(spacing: 8) {
                IconTile()
                Text(tab.label).lineLimit(1)
                Spacer(minLength: 0)
                StatusGlyph(status: tab.status)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 7)
            .frame(height: 32)
        }
        .buttonStyle(ChromeStyle(selected: selected, radius: 10))
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
