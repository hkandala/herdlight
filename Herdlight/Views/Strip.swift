import HerdrKit
import SwiftUI

/// One full-size page per tab of the workspace, paged sideways. The selection follows the page in view when the
/// scroll stops; a new selection (a click, a key) scrolls there, so the tab marker moves the same way either time.
struct Strip: View {
    let workspace: HostStore.Workspace
    let store: HostStore
    /// The page in view, as the scroll view has it.
    @State private var position = ScrollPosition(idType: String.self)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            #if os(macOS)
                .background(StripAnchor(store: store))
            #endif
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition($position, anchor: .leading)
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Double.self) {
            // To a thousandth, so a page at rest is a whole number (one lit tab) despite rounding.
            ($0.contentOffset.x / max($0.containerSize.width, 1) * 1000).rounded() / 1000
        } action: {
            store.page = $1
        }
        .onScrollPhaseChange { _, phase in
            // Not a page of the workspace that was shown before a switch.
            if phase == .idle, let shown = position.viewID(type: String.self),
               workspace.tabs.contains(where: { $0.id == shown })
            {
                workspace.selectedTabID = shown
            }
        }
        // One strip for every workspace: a new one jumps to its selected tab, a new tab in the same one scrolls.
        .onChange(of: [workspace.id, workspace.selectedTabID], initial: true) { old, new in
            guard let target = workspace.selectedTabID, position.viewID(type: String.self) != target else { return }
            let animate = old != new && old.first == new.first && !reduceMotion
            withAnimation(animate ? .smooth : nil) { position.scrollTo(id: target, anchor: .leading) }
            if old.first != new.first {
                // Another workspace's pages lay out in this same update, and a scroll to one of them can miss (a
                // new workspace came up blank): scroll again once they have.
                Task { position.scrollTo(id: target, anchor: .leading) }
            }
        }
    }
}

#if os(macOS)
    /// The app's one scroll monitor (design D35). A gesture picks its axis once it moved 4 pt: a sideways one goes to
    /// the scroll view under the pointer (the strip, over a card), so a terminal never sees it; any other goes to the
    /// view under the pointer as usual. Its momentum follows. A wheel picks per event; Shift makes it sideways.
    @MainActor
    enum SwipeRouter {
        /// Once, at launch.
        static func install() {
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { route(event) } ? nil : event
            }
        }

        /// The strip, for wheel clicks; it registers itself.
        fileprivate weak static var strip: StripAnchor.Anchor?
        /// Where the current sideways gesture goes; nil while it goes the usual way.
        private weak static var target: NSScrollView?
        private static var picked = false
        private static var moved = 0.0
        private static var wheeled = Date.distantPast

        /// Whether the event went to a scroll view or turned the strip.
        private static func route(_ event: NSEvent) -> Bool {
            let deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
            if event.phase.isEmpty, event.momentumPhase.isEmpty {
                return wheel(event, sideways: abs(deltaX) > abs(deltaY) ? deltaX : 0)
            }
            if event.phase == .began {
                picked = false
                target = nil
                moved = 0
            }
            if !picked {
                moved += abs(deltaX) + abs(deltaY)
                if moved >= 4 {
                    picked = true
                    target = abs(deltaX) > abs(deltaY) ? scrollView(event) : nil
                }
            }
            target?.scrollWheel(with: event)
            return target != nil
        }

        /// A sideways wheel step goes to the scroll view under the pointer; over the strip, a burst of line steps
        /// (a mouse, which would only nudge a paged strip) turns one page.
        private static func wheel(_ event: NSEvent, sideways deltaX: CGFloat) -> Bool {
            guard deltaX != 0, let scrollView = scrollView(event) else { return false }
            if !event.hasPreciseScrollingDeltas, let strip, strip.enclosingScrollView === scrollView {
                if Date.now.timeIntervalSince(wheeled) > 0.3 {
                    strip.step(deltaX > 0 ? -1 : 1)
                }
                wheeled = .now
            } else {
                scrollView.scrollWheel(with: event)
            }
            return true
        }

        private static func scrollView(_ event: NSEvent) -> NSScrollView? {
            event.window?.contentView?.hitTest(event.locationInWindow)?.enclosingScrollView
        }
    }

    /// Marks the strip's scroll view for the router, with the page turn for wheels.
    private struct StripAnchor: NSViewRepresentable {
        let store: HostStore

        func makeNSView(context _: Context) -> Anchor {
            Anchor(step: store.step)
        }

        func updateNSView(_ view: Anchor, context _: Context) {
            view.step = store.step
        }

        final class Anchor: NSView {
            var step: (Int) -> Void

            init(step: @escaping (Int) -> Void) {
                self.step = step
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                nil
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window != nil {
                    SwipeRouter.strip = self
                }
            }

            override func hitTest(_: NSPoint) -> NSView? {
                nil
            }
        }
    }
#endif

/// herdr's split tree: each split divides its rectangle by the ratio, minus the gap. Both children get an exact
/// size, so no card's content can push its neighbor out of the page. A zoomed card (design D11) fills the page:
/// each split above it stacks its sides, the zoomed side at full size, the other hidden at its own size. The same
/// views stay, so no terminal view changes host and only the zoomed one resizes.
private struct SplitLayout: View {
    let node: SplitNode
    let store: HostStore
    /// The size without zoom, for a split above the zoomed card: it fills the page, its parts keep their size.
    var natural: CGSize?

    var body: some View {
        switch node {
        case let .leaf(paneID):
            PaneCard(id: paneID, store: store)
        case let .split(direction, ratio, first, second):
            GeometryReader { geometry in
                let right = direction == .right
                let base = natural ?? geometry.size
                let total = max(0, (right ? base.width : base.height) - gap)
                // A NaN or out-of-range ratio from herdr must not break the layout.
                let size = total * (ratio.isNaN ? 0.5 : min(max(ratio, 0), 1))
                let sizes = right
                    ? (CGSize(width: size, height: base.height), CGSize(width: total - size, height: base.height))
                    : (CGSize(width: base.width, height: size), CGSize(width: base.width, height: total - size))
                let zoomed = store.zoomedPaneID.map { (first.contains($0), second.contains($0)) } ?? (false, false)
                let stack = zoomed.0 || zoomed.1 ? AnyLayout(ZStackLayout())
                    : right ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                stack {
                    side(first, sizes.0, zoomed: zoomed.0, away: zoomed.1, page: geometry.size)
                    side(second, sizes.1, zoomed: zoomed.1, away: zoomed.0, page: geometry.size)
                }
            }
        }
    }

    /// One side of a split: its own size, the whole rectangle when it holds the zoomed card, or hidden under it.
    private func side(_ node: SplitNode, _ size: CGSize, zoomed: Bool, away: Bool, page: CGSize) -> some View {
        SplitLayout(node: node, store: store, natural: zoomed ? size : nil)
            .frame(width: zoomed ? page.width : size.width, height: zoomed ? page.height : size.height)
            // Under the zoomed side (zIndex), which covers it, so its terminal views get no clicks.
            .opacity(away ? 0 : 1)
            .zIndex(away ? 0 : 1)
            .transformEnvironment(\.zoomedAway) { $0 = $0 || away }
    }
}

extension EnvironmentValues {
    /// The card is under a zoomed card: hidden, but there, so its terminal keeps its size.
    @Entry var zoomedAway = false
}

private extension SplitNode {
    func contains(_ paneID: String) -> Bool {
        switch self {
        case let .leaf(id): id == paneID
        case let .split(_, _, first, second): first.contains(paneID) || second.contains(paneID)
        }
    }
}

/// A translucent card: a header with the pane's title and buttons, and its terminal.
private struct PaneCard: View {
    let id: String
    let store: HostStore
    @State private var hovering = false
    @Environment(\.zoomedAway) private var zoomedAway

    var body: some View {
        let pane = store.pane(id)
        let title = pane?.title ?? "terminal"
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let zoomed = store.zoomedPaneID == id
        #if os(macOS)
            let terminal = pane?.terminalID.flatMap { store.terminals.terminal($0, pane: id) }
            // The card that has the keyboard is lit; herdr's focus until a terminal exists.
            let lit = terminal?.hasKeyboard ?? pane?.focused ?? true
        #else
            let lit = pane?.focused ?? true
        #endif
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Clicks pass through to the header's double-click.
                Image(systemName: "apple.terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                    .allowsHitTesting(false)
                Text(title)
                    .lineLimit(1)
                    // A path keeps its end, a label its start.
                    .truncationMode(pane?.label == nil ? .head : .tail)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                // Only on hover (and while zoomed, so Restore stays in sight); hidden, they take no width from a
                // narrow card.
                if hovering || zoomed {
                    HStack(spacing: 0) {
                        IconButton(symbol: "rectangle.split.2x1", help: "Split Right") {
                            Task { await store.split(id, .right) }
                        }
                        .accessibilityIdentifier("pane.\(id).split-right")
                        IconButton(symbol: "rectangle.split.1x2", help: "Split Down") {
                            Task { await store.split(id, .down) }
                        }
                        .accessibilityIdentifier("pane.\(id).split-down")
                        let zoom = zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                        IconButton(symbol: zoom, help: zoomed ? "Restore" : "Zoom") { store.zoom(id) }
                            .accessibilityIdentifier("pane.\(id).zoom")
                        IconButton(symbol: "xmark", help: "Close") { Task { await store.close(pane: id) } }
                            .accessibilityIdentifier("pane.\(id).close")
                    }
                    .disabled(store.writing)
                }
            }
            .fontWeight(.medium)
            .padding(.leading, 12)
            .padding(.trailing, 4)
            // A card narrower than its header cuts the header (the card clips) instead of growing.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            // Behind the header, so its buttons still take their own clicks.
            .background { Color.clear.contentShape(.rect).onTapGesture(count: 2) { store.zoom(id) } }
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
                .accessibilityAction(named: zoomed ? "Restore" : "Zoom") { store.zoom(id) }
                .accessibilityAction(named: "Close") { Task { await store.close(pane: id) } }
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
        .accessibilityHidden(zoomedAway)
    }
}
