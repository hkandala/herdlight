import SwiftUI

/// One glass capsule per tab of the workspace; the selected one is tinted.
struct TabBar: View {
    let workspace: HostStore.Workspace

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
                        TabCapsule(tab: tab, selected: tab.id == workspace.selectedTabID) {
                            withAnimation { workspace.selectedTabID = tab.id }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .padding(gap)
        #if os(macOS)
            // The title bar is hidden, so the bar's empty space moves the window.
            .gesture(WindowDragGesture())
        #endif
    }
}

private struct TabCapsule: View {
    let tab: HostStore.Tab
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Text(tab.label)
                StatusGlyph(status: tab.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected ? .regular.tint(.white.opacity(0.18)).interactive() : .regular.interactive(),
            in: .capsule,
        )
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
