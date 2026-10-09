import SwiftUI

/// herdr's workspaces as sections with their tabs as rows, and a filter at the bottom.
struct Sidebar: View {
    let store: HostStore
    @State private var filter = ""

    var body: some View {
        let sections = store.workspaces.map { ($0, shown($0)) }.filter { !$0.1.isEmpty }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.0.id) { workspace, tabs in
                        WorkspaceHeader(workspace: workspace, store: store)
                        ForEach(tabs) { TabRow(tab: $0, workspace: workspace, store: store) }
                    }
                    if sections.isEmpty, !store.workspaces.isEmpty {
                        Text("No matching tabs").foregroundStyle(.secondary).padding(8)
                    }
                }
                .padding([.horizontal, .bottom], 8)
            }
            .scrollIndicators(.never)
            HStack(spacing: 2) {
                FilterField(prompt: "Filter", text: $filter, identifier: "sidebar.filter")
                #if os(macOS)
                    .onExitCommand { filter = "" }
                #endif
                    .padding(.trailing, 4)
                // ponytail: no-op until sessions can be created
                IconButton(symbol: "rectangle.stack.badge.plus", help: "New Session") {}
                // ponytail: no-op until remote hosts
                IconButton(symbol: "network", help: "Add Remote Host") {}
            }
            .padding(8)
        }
        // On the window background, as in the reference: only the pane cards are frosted.
        .frame(width: 240)
    }

    /// The tabs whose label matches the filter; all of them when the workspace's label matches.
    private func shown(_ workspace: HostStore.Workspace) -> [HostStore.Tab] {
        filter.isEmpty || workspace.label.matches(filter) ? workspace.tabs : workspace.tabs
            .filter { $0.label.matches(filter) }
    }
}

/// A section header; clicking it selects the workspace at its own selected tab.
private struct WorkspaceHeader: View {
    let workspace: HostStore.Workspace
    let store: HostStore

    var body: some View {
        Button { store.selectedWorkspaceID = workspace.id } label: {
            HStack {
                Text(workspace.label)
                Spacer()
                StatusGlyph(status: workspace.status)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.\(workspace.id)")
    }
}

/// One tab; its own view, so a status change redraws this row only (design D6).
private struct TabRow: View {
    let tab: HostStore.Tab
    let workspace: HostStore.Workspace
    let store: HostStore

    var body: some View {
        let selected = workspace.id == store.selectedWorkspaceID && tab.id == workspace.selectedTabID
        Button {
            store.selectedWorkspaceID = workspace.id
            workspace.selectedTabID = tab.id
        } label: {
            HStack(spacing: 8) {
                IconTile()
                Text(tab.label).lineLimit(1)
                Spacer(minLength: 0)
                StatusGlyph(status: tab.status)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
        }
        .buttonStyle(ChromeStyle(selected: selected, radius: 10))
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
