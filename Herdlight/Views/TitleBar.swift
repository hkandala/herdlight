import SwiftUI

/// The row in the title bar line: sidebar toggle, session picker, the tabs while the sidebar is hidden, ⌘ and +.
struct TitleBar: View {
    /// AppKit owns the traffic lights; the row starts after them.
    static let lights: CGFloat = 78
    /// The compact toolbar's height, so the row centers on the traffic lights.
    static let height: CGFloat = 40
    /// Where the session picker button starts: after the 28 pt sidebar toggle and the row's 4 pt spacing.
    static let picker = lights + 32

    let store: HostStore
    @Binding var sidebar: Bool
    @Binding var picking: Bool

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "sidebar.left", help: "Toggle Sidebar") {
                withAnimation(.snappy) { sidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityIdentifier("titlebar.sidebar")
            SessionPicker(store: store, open: $picking)
            if !sidebar, store.state == .live, let workspace = store.selectedWorkspace {
                TabBar(workspace: workspace)
            }
            Spacer(minLength: 0)
            // ponytail: no-op until the command palette
            IconButton(symbol: "command", help: "Commands") {}
            // ponytail: no-op until new tabs
            IconButton(symbol: "plus", help: "New Tab") {}
        }
        .padding(.leading, Self.lights)
        .padding(.trailing, gap)
        .frame(height: Self.height)
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
    @State private var hovered: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer {
                    HStack(spacing: 2) {
                        ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                            if index > 0 {
                                // Only between two flat capsules.
                                let quiet = [tab.id, workspace.tabs[index - 1].id].contains {
                                    $0 == workspace.selectedTabID || $0 == hovered
                                }
                                Divider().frame(height: 16).opacity(quiet ? 0 : 1)
                            }
                            TabCapsule(tab: tab, workspace: workspace, glass: glass)
                                .onHover { hovered = $0 ? tab.id : hovered == tab.id ? nil : hovered }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            // Capsules fade out at the edges instead of being cut.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
            }
            .onAppear { proxy.scrollTo(workspace.selectedTabID) }
            .onChange(of: workspace.selectedTabID) { withAnimation { proxy.scrollTo(workspace.selectedTabID) } }
        }
    }
}

/// One tab; its own view, so a status change redraws this capsule only (design D6).
private struct TabCapsule: View {
    let tab: HostStore.Tab
    let workspace: HostStore.Workspace
    let glass: Namespace.ID

    var body: some View {
        let selected = tab.id == workspace.selectedTabID
        Button {
            withAnimation(.snappy) { workspace.selectedTabID = tab.id }
        } label: {
            HStack(spacing: 8) {
                IconTile()
                Text(tab.label).lineLimit(1)
                StatusGlyph(status: tab.status)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
        }
        .buttonStyle(ChromeStyle(radius: 15))
        .glassEffect(selected ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID(selected ? "marker" : tab.id, in: glass)
        .id(tab.id)
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
