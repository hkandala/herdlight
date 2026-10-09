import HerdrKit
import SwiftUI

/// One full-size page per tab of the workspace, paged sideways, bound to the selected tab.
struct Strip: View {
    @Bindable var workspace: HostStore.Workspace
    let store: HostStore

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(workspace.tabs) { tab in
                    Group {
                        if let tree = tab.tree {
                            SplitLayout(node: tree, store: store).padding([.horizontal, .bottom], gap)
                        } else {
                            Text("No layout for this tab").foregroundStyle(.secondary)
                        }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("page.\(tab.id)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $workspace.selectedTabID, anchor: .leading)
        .scrollIndicators(.never)
        // A new workspace starts a new strip at its selected tab.
        .id(workspace.id)
    }
}

/// The 8 pt gap between cards is the one fixed size; it is also where dividers go later.
let gap: CGFloat = 8

/// herdr's split tree: each split divides its rectangle by the ratio, minus the gap.
private struct SplitLayout: View {
    let node: SplitNode
    let store: HostStore

    var body: some View {
        switch node {
        case let .leaf(paneID):
            PaneCard(id: paneID, store: store)
        case let .split(direction, ratio, first, second):
            GeometryReader { geometry in
                let right = direction == .right
                let size = max(0, ((right ? geometry.size.width : geometry.size.height) - gap) * ratio)
                let stack = right ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                stack {
                    SplitLayout(node: first, store: store)
                        .frame(width: right ? size : nil, height: right ? nil : size)
                    SplitLayout(node: second, store: store)
                }
            }
        }
    }
}

/// A frosted card with a header; phase 4 puts the terminal in its body.
private struct PaneCard: View {
    let id: String
    let store: HostStore
    @State private var hovering = false

    var body: some View {
        let pane = store.pane(id)
        let title = pane?.label ?? pane?.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "terminal"
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal").foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    IconButton(symbol: "rectangle.split.2x1", help: "Split Right") {
                        Task { await store.split(id, .right) }
                    }
                    .accessibilityIdentifier("pane.\(id).split-right")
                    IconButton(symbol: "rectangle.split.1x2", help: "Split Down") {
                        Task { await store.split(id, .down) }
                    }
                    .accessibilityIdentifier("pane.\(id).split-down")
                    // ponytail: no-op until zoom
                    IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom") {}
                    // ponytail: no-op until panes can be closed
                    IconButton(symbol: "xmark", help: "Close") {}
                }
                .opacity(hovering ? 1 : 0)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 34)
            // The terminal's slot.
            Text(id).monospaced().foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(pane?.focused ?? true || hovering ? 1 : 0.6)
        // The card's element is its background: a container would merge into a one-pane page's.
        .background {
            shape.fill(Color.card).accessibilityElement().accessibilityLabel(title)
                .accessibilityIdentifier("pane.\(id)")
        }
        .overlay(shape.strokeBorder(Color.hairline))
        .onHover { hovering = $0 }
    }
}
