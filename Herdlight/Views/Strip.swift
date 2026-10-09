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
        #if os(macOS)
            .onAppear { SwipeRouter.install() }
        #endif
    }
}

#if os(macOS)
    /// The app's one scroll monitor (design D35). Each gesture picks its axis on its first move: a sideways one goes
    /// to the scroll view under the pointer (the strip, over a card), so a terminal never sees it; any other goes to
    /// the view under the pointer as usual. Its momentum follows. A wheel (Shift for sideways) picks per event.
    @MainActor
    private enum SwipeRouter {
        /// Where the current sideways gesture goes; nil while it goes the usual way.
        private weak static var target: NSScrollView?
        private static var picked = false
        private static var monitor: Any?

        static func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { route(event) } ? nil : event
            }
        }

        /// Whether the event went to a scroll view.
        private static func route(_ event: NSEvent) -> Bool {
            let wheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if event.phase == .mayBegin || event.phase == .began {
                picked = false
                target = nil
            }
            if wheel || !picked, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                picked = !wheel
                target = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.window?.contentView?.hitTest(event.locationInWindow)?.enclosingScrollView : nil
            }
            target?.scrollWheel(with: event)
            return target != nil
        }
    }
#endif

/// The 8 pt gap between cards is the one fixed size; it is also where dividers go later.
let gap: CGFloat = 8

/// herdr's split tree: each split divides its rectangle by the ratio, minus the gap. Both children get an exact
/// size, so no card's content can push its neighbor out of the page.
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
                let total = max(0, (right ? geometry.size.width : geometry.size.height) - gap)
                // A NaN or out-of-range ratio from herdr must not break the layout.
                let size = total * (ratio.isNaN ? 0.5 : min(max(ratio, 0), 1))
                let stack = right ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                let width = geometry.size.width, height = geometry.size.height
                stack {
                    SplitLayout(node: first, store: store)
                        .frame(width: right ? size : width, height: right ? height : size)
                    SplitLayout(node: second, store: store)
                        .frame(width: right ? total - size : width, height: right ? height : total - size)
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
        #if os(macOS)
            let terminal = pane?.terminalID.flatMap { store.terminals.terminal($0, pane: id) }
            // The card that has the keyboard is lit; herdr's focus until a terminal exists.
            let lit = terminal?.hasKeyboard ?? pane?.focused ?? true
        #else
            let lit = pane?.focused ?? true
        #endif
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                    // A path keeps its end, a label its start.
                    .truncationMode(pane?.label == nil ? .head : .tail)
                Spacer(minLength: 0)
                // Only on hover, so the hidden buttons take no width from a narrow card.
                if hovering {
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
                        IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom", quiet: true) {}
                        // ponytail: no-op until panes can be closed
                        IconButton(symbol: "xmark", help: "Close", quiet: true) {}
                    }
                    .disabled(store.splitting)
                }
            }
            .fontWeight(.medium)
            .padding(.leading, 12)
            .padding(.trailing, 4)
            // A card narrower than its header cuts the header (the card clips) instead of growing.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            Group {
                #if os(macOS)
                    if let terminal {
                        TerminalCard(terminal: terminal).padding([.horizontal, .bottom], gap)
                    }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The card's element is its background: a container would merge into a one-pane page's.
        .background {
            shape.fill(Color.card).accessibilityElement().accessibilityLabel(title)
                .accessibilityIdentifier("pane.\(id)")
                // The split buttons show on hover only; VoiceOver splits from the card.
                .accessibilityAction(named: "Split Right") { Task { await store.split(id, .right) } }
                .accessibilityAction(named: "Split Down") { Task { await store.split(id, .down) } }
        }
        .overlay {
            // Cards without the keyboard are a little darker, a hovered one less so; the terminal's text
            // keeps its own contrast.
            if !lit {
                shape.fill(.black.opacity(hovering ? 0.08 : 0.15)).allowsHitTesting(false)
            }
        }
        .overlay(shape.strokeBorder(Color.hairline))
        .clipShape(shape)
        .onHover { hovering = $0 }
    }
}
