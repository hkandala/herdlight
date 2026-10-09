#if os(macOS)
    import HerdrKit

    /// Owns every pane's terminal of one session, keyed by `terminal_id`, so SwiftUI never destroys
    /// one while the strip scrolls. Streams run for the selected tab only (design: what streams).
    /// ponytail: no 24-surface LRU; a terminal stays until the session switches, add the LRU when
    /// sessions with many panes show up.
    @MainActor
    final class PaneViewRegistry {
        var client: HerdrClient?
        private var terminals: [String: PaneTerminal] = [:]

        /// The pane's terminal, made on first use.
        func terminal(_ terminalID: String, pane paneID: String) -> PaneTerminal? {
            if let terminal = terminals[terminalID] {
                // A moved pane keeps its terminal under a new pane id.
                terminal.paneID = paneID
                return terminal
            }
            guard let client else { return nil }
            let terminal = PaneTerminal(terminalID: terminalID, paneID: paneID, client: client)
            terminals[terminalID] = terminal
            return terminal
        }

        /// Streams these terminals (terminal id → pane id) and releases every other one. Drops the
        /// terminals not in `alive` (their panes closed).
        func show(_ shown: [String: String], alive: Set<String>) {
            for (terminalID, terminal) in terminals where !alive.contains(terminalID) {
                terminal.close()
                terminals[terminalID] = nil
            }
            for (terminalID, terminal) in terminals where shown[terminalID] == nil {
                terminal.hide()
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
