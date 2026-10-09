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
                            SplitLayout(node: tree, store: store).padding(gap)
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
            PaneCard(id: paneID, pane: store.pane(paneID))
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

/// An opaque placeholder card; phase 4 puts the terminal in it.
private struct PaneCard: View {
    let id: String
    let pane: HostStore.Pane?

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.card)
            .strokeBorder(.white.opacity(0.06))
            .overlay {
                VStack(spacing: 4) {
                    Text(pane?.label ?? "terminal")
                    Text(id).monospaced().foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pane.\(id)")
    }
}
