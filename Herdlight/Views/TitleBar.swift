import SwiftUI

/// The row in the title bar line: sidebar toggle, session picker, the tabs while the sidebar is hidden, ⌘ and +.
struct TitleBar: View {
    @Binding var store: HostStore
    @Binding var sidebar: Bool

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "sidebar.left", help: "Toggle Sidebar") {
                withAnimation(.snappy) { sidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityIdentifier("titlebar.sidebar")
            SessionPicker(store: $store)
            if !sidebar, store.isLive, let workspace = store.selectedWorkspace {
                TabBar(workspace: workspace)
            }
            Spacer(minLength: 0)
            // ponytail: no-op until the command palette
            IconButton(symbol: "command", help: "Commands") {}
            // ponytail: no-op until new tabs
            IconButton(symbol: "plus", help: "New Tab") {}
        }
        // AppKit owns the traffic lights; this clears them.
        .padding(.leading, 78)
        .padding(.trailing, gap)
        .frame(height: 40)
        .contentShape(.rect)
        #if os(macOS)
            // The title bar is hidden, so the row's empty space moves the window.
            .gesture(WindowDragGesture())
        #endif
    }
}

/// The workspace's tabs as capsules; one glass marker morphs to the selected one.
private struct TabBar: View {
    let workspace: HostStore.Workspace
    @Namespace private var glass

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer {
                HStack(spacing: 2) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        if index > 0 {
                            let quiet = [tab.id, workspace.tabs[index - 1].id].contains(workspace.selectedTabID)
                            Rectangle().fill(Color.white.opacity(quiet ? 0 : 0.15)).frame(width: 1, height: 16)
                        }
                        capsule(tab)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func capsule(_ tab: HostStore.Tab) -> some View {
        let selected = tab.id == workspace.selectedTabID
        return Button {
            withAnimation(.snappy) { workspace.selectedTabID = tab.id }
        } label: {
            HStack(spacing: 8) {
                IconTile()
                Text(tab.label).lineLimit(1)
                Spacer(minLength: 0)
                StatusGlyph(status: tab.status)
            }
            .font(.system(size: 13))
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(width: 200, height: 30)
        }
        .buttonStyle(ChromeStyle(radius: 15))
        .glassEffect(selected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(selected ? "marker" : tab.id, in: glass)
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
