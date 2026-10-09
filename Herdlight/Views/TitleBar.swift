import SwiftUI

/// The row in the title bar line: sidebar toggle, session picker, the tabs while the sidebar is hidden, ⌘ and +.
struct TitleBar: View {
    /// The compact toolbar's height, so the row centers on the traffic lights.
    static let height: CGFloat = 40
    /// The session picker button starts this far into the row: the 28 pt sidebar toggle and the row's 4 pt spacing.
    static let picker: CGFloat = 32

    /// Where the row starts: after the traffic lights, which AppKit owns; full screen has none.
    static func inset(fullScreen: Bool) -> CGFloat {
        fullScreen ? gap : 78
    }

    let store: HostStore
    let fullScreen: Bool
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
                TabBar(workspace: workspace, page: store.page)
            }
            Spacer(minLength: 0)
            // ponytail: no-op until the command palette
            IconButton(symbol: "command", help: "Commands") {}
            // ponytail: no-op until new tabs
            IconButton(symbol: "plus", help: "New Tab") {}
        }
        .padding(.leading, Self.inset(fullScreen: fullScreen))
        .padding(.trailing, gap)
        .frame(height: Self.height)
        .contentShape(.rect)
        #if os(macOS)
            // The title bar is hidden, so the row's empty space moves the window.
            .gesture(WindowDragGesture())
        #endif
    }
}

/// The workspace's tabs as capsules on one glass marker that follows the strip's scroll offset: between two
/// capsules while the strip is between their pages. The tabs whose pages are in view are lit.
private struct TabBar: View {
    let workspace: HostStore.Workspace
    let page: Double
    @State private var hovered: String?
    /// Each capsule's frame in the bar, for the marker.
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        let tabs = workspace.tabs
        // Pages floor(x/w) through ceil((x+w)/w) − 1, that is floor(page)...ceil(page).
        let lit = Int(page.rounded(.down)) ... Int(page.rounded(.up))
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        if index > 0 {
                            // Only between two flat capsules.
                            let quiet = lit.contains(index) || lit.contains(index - 1)
                                || [tab.id, tabs[index - 1].id].contains(hovered)
                            Divider().frame(height: 16).opacity(quiet ? 0 : 1)
                        }
                        TabCapsule(tab: tab, workspace: workspace, lit: lit.contains(index))
                            .onHover { hovered = $0 ? tab.id : hovered == tab.id ? nil : hovered }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: {
                                frames[tab.id] = $0
                            }
                    }
                }
                .background(alignment: .topLeading) { marker(tabs) }
                .coordinateSpace(.named("tabs"))
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
            .onAppear {
                if let id = workspace.selectedTabID {
                    proxy.scrollTo(id)
                }
            }
            .onChange(of: workspace.selectedTabID) {
                if let id = workspace.selectedTabID {
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// The marker: the capsule frame of the page in view, blended toward the next one by the scroll's fraction.
    private func marker(_ tabs: [HostStore.Tab]) -> some View {
        let page = min(max(page, 0), Double(max(tabs.count - 1, 0)))
        let index = Int(page), fraction = page - Double(index)
        let frame = { tabs.indices.contains($0) ? frames[tabs[$0].id] : nil }
        let from = frame(index) ?? .zero, next = frame(index + 1) ?? from
        return Color.clear
            .frame(width: from.width + (next.width - from.width) * fraction, height: from.height)
            .glassEffect(.regular, in: .capsule)
            .offset(x: from.minX + (next.minX - from.minX) * fraction, y: from.minY)
            .allowsHitTesting(false)
    }
}

/// One tab; its own view, so a status change redraws this capsule only (design D6).
private struct TabCapsule: View {
    let tab: HostStore.Tab
    let workspace: HostStore.Workspace
    /// Its page is in view.
    let lit: Bool

    var body: some View {
        let selected = tab.id == workspace.selectedTabID
        // The strip scrolls to the new selection and the marker follows, as during a swipe.
        Button { workspace.selectedTabID = tab.id } label: {
            HStack(spacing: 8) {
                IconTile()
                Text(tab.label).lineLimit(1).foregroundStyle(lit ? .primary : .secondary)
                StatusGlyph(status: tab.status)
            }
            // As in the reference: the tile sits in from the capsule's round end, more than above and below it.
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
        }
        .buttonStyle(ChromeStyle(radius: 14))
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(lit ? "in view" : "")
    }
}
