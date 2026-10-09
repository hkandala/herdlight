import HerdrKit
import SwiftUI

/// ⌘K: a floating glass panel to jump to a session, workspace or tab. Type to filter, arrows to move, Enter to
/// jump, Esc to close.
struct Palette: View {
    @Binding var store: HostStore
    @Binding var open: Bool
    @State private var filter = ""
    @State private var index = 0

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let jump: () -> Void
    }

    var body: some View {
        let items = filtered
        let index = min(index, items.count - 1)
        VStack(alignment: .leading, spacing: 2) {
            FilterField(prompt: "Jump to a session, workspace or tab", text: $filter, identifier: "palette.filter",
                        autofocus: true)
                // Here, not onSubmit: a field's submit action is not refreshed when only the index changes, so ↓
                // Enter took the first row. Each handler reads the list and the index as they are now.
                .onKeyPress(.return) {
                    let items = filtered
                    if !items.isEmpty {
                        jump(items[min(self.index, items.count - 1)])
                    }
                    return .handled
                }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                            Button { jump(item) } label: {
                                MenuRow(symbol: item.symbol, title: item.title, detail: item.detail,
                                        selected: offset == index)
                            }
                            .buttonStyle(ChromeStyle(selected: offset == index, tint: .accentColor))
                            .accessibilityIdentifier("palette.\(item.id)")
                            .accessibilityAddTraits(offset == index ? .isSelected : [])
                        }
                        if items.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: index) {
                    if items.indices.contains(index) {
                        proxy.scrollTo(items[index].id)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 480)
        // A little darker than the session list: it floats over terminal text.
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .onChange(of: filter) { self.index = 0 }
        .task { await store.loadSessions() }
        #if os(macOS)
            .onExitCommand { open = false }
        #endif
    }

    private var filtered: [Item] {
        items.filter { "\($0.title) \($0.detail)".matches(filter) }
    }

    /// Tabs first (the usual jump), then workspaces, then the other running sessions.
    private var items: [Item] {
        let tabs = store.workspaces.flatMap { workspace in
            workspace.tabs.map { tab in
                Item(id: "tab.\(tab.id)", symbol: "apple.terminal", title: tab.label, detail: workspace.label) {
                    store.selectedWorkspaceID = workspace.id
                    workspace.selectedTabID = tab.id
                }
            }
        }
        let workspaces = store.workspaces.map { workspace in
            Item(id: "workspace.\(workspace.id)", symbol: "square.stack", title: workspace.label,
                 detail: "Workspace") { store.selectedWorkspaceID = workspace.id }
        }
        let sessions = store.sessions.filter { $0.running && $0.name != store.session }.map { session in
            Item(id: "session.\(session.name)", symbol: "macbook", title: session.name, detail: "Session") {
                store = HostStore(session: session.name)
            }
        }
        return tabs + workspaces + sessions
    }

    private func move(_ step: Int) -> KeyPress.Result {
        index = max(0, min(index + step, filtered.count - 1))
        return .handled
    }

    private func jump(_ item: Item) {
        item.jump()
        open = false
    }
}
