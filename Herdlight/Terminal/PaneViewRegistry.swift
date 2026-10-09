#if os(macOS)
    import GhosttyTerminal
    import HerdrKit

    /// Owns every pane's terminal of one session, keyed by `terminal_id`, so SwiftUI never destroys
    /// one while the strip scrolls. The selected tab's terminals stream and draw; those of recently
    /// shown tabs keep streaming without drawing, up to `live` of them, so coming back to a tab
    /// resizes nothing (design: what streams).
    @MainActor
    final class PaneViewRegistry {
        /// The design's bound on live terminal surfaces.
        static let live = 24
        var client: HerdrClient?
        /// A terminal took the keyboard (its terminal id).
        var onKeyboard: ((String) -> Void)?
        private var terminals: [String: PaneTerminal] = [:]
        /// Streaming terminals, the most recently shown last.
        private var recent: [String] = []

        /// The pane's terminal, made on first use.
        func terminal(_ terminalID: String, pane paneID: String) -> PaneTerminal? {
            if let terminal = terminals[terminalID] {
                // A moved pane keeps its terminal under a new pane id.
                terminal.paneID = paneID
                return terminal
            }
            guard let client else { return nil }
            let terminal = PaneTerminal(terminalID: terminalID, paneID: paneID, client: client)
            terminal.view.onKeyboard = { [weak self] in self?.onKeyboard?(terminalID) }
            terminals[terminalID] = terminal
            return terminal
        }

        /// Streams and draws these terminals (terminal id → pane id); the others stop drawing, and
        /// past the `live` most recently shown they let go. Drops the terminals not in `alive`
        /// (their panes closed).
        func show(_ shown: [String: String], alive: Set<String>) {
            for (terminalID, terminal) in terminals where !alive.contains(terminalID) {
                terminal.close()
                terminals[terminalID] = nil
            }
            recent = recent.filter { alive.contains($0) && shown[$0] == nil } + Array(shown.keys)
            // Only hidden ones go: a tab with more than `live` panes keeps them all.
            // ponytail: an evicted terminal keeps its surface (its last image) until its pane closes
            // or the session switches.
            while recent.count > Self.live, let terminalID = recent.first, shown[terminalID] == nil {
                recent.removeFirst()
                terminals[terminalID]?.hide()
            }
            for (terminalID, terminal) in terminals {
                terminal.view.setSurfaceVisible(shown[terminalID] != nil)
            }
            for (terminalID, paneID) in shown {
                terminal(terminalID, pane: paneID)?.show()
            }
        }

        /// Gives the keyboard to this terminal. A view that left the window with the keyboard
        /// would take it back when its tab returns; this one wins instead.
        func focus(_ terminalID: String) {
            terminals.values.forEach { $0.view.wantsKeyboard = false }
            terminals[terminalID]?.view.takeKeyboard()
        }

        /// Releases everything: the session switches or its store stops.
        func closeAll() {
            terminals.values.forEach { $0.close() }
            terminals = [:]
            client = nil
        }
    }
#endif
