import Foundation
import HerdrKit
import Observation

/// The live model of one herdr session. Snapshots land on stable objects keyed by id; Observation
/// skips fields that did not change, so one status change redraws one row (design D6).
@MainActor @Observable
final class HostStore {
    enum State: Equatable {
        case connecting, live
        case failed(HerdrError)
    }

    @MainActor @Observable
    final class Workspace: Identifiable {
        let id: String
        var label = ""
        var status = AgentStatus.idle
        var tabs: [Tab] = []
        /// The app's own selection, never herdr's focus. Starts at herdr's active tab.
        var selectedTabID: String?

        init(id: String) {
            self.id = id
        }
    }

    @MainActor @Observable
    final class Tab: Identifiable {
        let id: String
        var label = ""
        var status = AgentStatus.idle
        var tree: SplitNode?

        init(id: String) {
            self.id = id
        }
    }

    @MainActor @Observable
    final class Pane: Identifiable {
        let id: String
        var label: String?
        var cwd: String?
        /// The tab's focused pane, as herdr has it.
        var focused = false
        var tabID = ""
        var terminalID: String?

        init(id: String) {
            self.id = id
        }
    }

    let session: String
    private(set) var state = State.connecting
    /// Every session herdr knows on this Mac, for the session picker.
    private(set) var sessions: [Session] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var panes: [Pane] = []
    var selectedWorkspaceID: String?
    /// The last failed write, shown for a few seconds.
    private(set) var notice: String?
    /// A split in flight; the buttons wait for it.
    private(set) var splitting = false
    @ObservationIgnored private var client: HerdrClient?
    #if os(macOS)
        let terminals = PaneViewRegistry()
        /// The tab whose terminal last got the keyboard from the app.
        @ObservationIgnored private var keyboardTabID: String?
    #endif

    init(session: String) {
        self.session = session
    }

    /// "This Mac" for the default session, "This Mac · ‹session›" for the others.
    static func name(_ session: String) -> String {
        session == "default" ? "This Mac" : "This Mac · \(session)"
    }

    func pane(_ id: String) -> Pane? {
        panes.first { $0.id == id }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedTab: Tab? {
        selectedWorkspace.flatMap { workspace in workspace.tabs.first { $0.id == workspace.selectedTabID } }
    }

    /// The selected tab's terminals (terminal id → pane id): the ones that stream.
    var shownTerminals: [String: String] {
        Dictionary(panes.compactMap { pane in
            pane.tabID == selectedTab?.id ? pane.terminalID.map { ($0, pane.id) } : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    #if os(macOS)
        /// Streams the selected tab's terminals, releases the others, drops those of closed panes.
        func showTerminals() {
            terminals.show(shownTerminals, alive: Set(panes.compactMap(\.terminalID)))
            // A tab shown for the first time since it was selected gives the keyboard to herdr's
            // focused pane; later snapshots leave it where the user clicked.
            guard let tab = selectedTab, tab.id != keyboardTabID else { return }
            let tabPanes = panes.filter { $0.tabID == tab.id }
            if let terminalID = tabPanes.first(where: \.focused)?.terminalID ?? tabPanes.compactMap(\.terminalID)
                .first
            {
                keyboardTabID = tab.id
                terminals.focus(terminalID)
            }
        }
    #endif

    /// False only when herdr lists the session as stopped (or not at all).
    var isRunning: Bool {
        sessions.isEmpty || sessions.contains { $0.name == session && $0.running }
    }

    /// Follows the session until the calling task is cancelled.
    func run(exec: any Exec) async {
        var loadedSessions = false
        do {
            let client = try await HerdrClient(herdr: HerdrClient.locate(exec: exec), session: session, exec: exec)
            self.client = client
            defer { self.client = nil }
            #if os(macOS)
                terminals.client = client
                defer { terminals.closeAll() }
            #endif
            for await update in await client.updates() {
                switch update {
                case let .snapshot(snapshot):
                    apply(snapshot)
                    #if os(macOS)
                        // Also retries a terminal whose stream failed.
                        showTerminals()
                    #endif
                    state = .live
                    // After the first snapshot, so the picker never delays the layout.
                    if !loadedSessions {
                        loadedSessions = true
                        sessions = await (try? client.sessions()) ?? []
                    }
                case let .error(error):
                    // First, to tell "not running" from other failures without a flash of the other text.
                    sessions = await (try? client.sessions()) ?? sessions
                    state = .failed(error)
                }
            }
        } catch {
            state = .failed(error as? HerdrError ?? .failed("\(error)"))
        }
    }

    /// The one write v0 makes. No focus change; the snapshot after it draws the new pane.
    func split(_ paneID: String, _ direction: SplitNode.Direction) async {
        guard let client, !splitting else { return }
        splitting = true
        notice = nil
        do {
            let _: Created = try await client.call("pane.split", ["target_pane_id": paneID,
                                                                  "direction": direction.rawValue, "focus": false])
            splitting = false
            await client.refresh()
        } catch {
            splitting = false
            let text = error.localizedDescription
            notice = text
            // Shown for a few seconds, unless a newer one replaced it.
            try? await Task.sleep(for: .seconds(4))
            if notice == text {
                notice = nil
            }
        }
    }

    /// herdr's session list again, for the picker: a session started since shows up.
    func loadSessions() async {
        guard let client else { return }
        sessions = await (try? client.sessions()) ?? sessions
    }

    private func apply(_ snapshot: Snapshot) {
        let tabs = Dictionary(grouping: snapshot.tabs, by: \.workspaceID)
        reuse(self, \.workspaces, snapshot.workspaces, Workspace.init(id:)) { workspace, new in
            workspace.label = new.label
            workspace.status = new.agentStatus
            reuse(workspace, \.tabs, tabs[new.id] ?? [], Tab.init(id:)) { tab, new in
                tab.label = new.label
                tab.status = new.agentStatus
                tab.tree = snapshot.trees[new.id]
            }
            if !workspace.tabs.contains(where: { $0.id == workspace.selectedTabID }) {
                workspace.selectedTabID = workspace.tabs.contains { $0.id == new.activeTabID }
                    ? new.activeTabID : workspace.tabs.first?.id
            }
        }
        let focused = snapshot.focusedPaneIDs
        reuse(self, \.panes, snapshot.panes, Pane.init(id:)) { pane, new in
            pane.label = new.label
            pane.cwd = new.cwd
            pane.focused = focused.contains(new.id)
            pane.tabID = new.tabID
            pane.terminalID = new.terminalID
        }
        if selectedWorkspace == nil {
            selectedWorkspaceID = workspaces.contains { $0.id == snapshot.focusedWorkspaceID }
                ? snapshot.focusedWorkspaceID : workspaces.first?.id
        }
    }
}

/// Any reply: only success matters.
private nonisolated struct Created: Decodable, Sendable {}

/// Keeps the object of each id that stays, makes the new ones, and replaces the list only when its
/// ids changed, so views of the list redraw only then.
@MainActor
private func reuse<Owner: AnyObject, Object: Identifiable<String>, Item: Identifiable<String>>(
    _ owner: Owner,
    _ list: ReferenceWritableKeyPath<Owner, [Object]>,
    _ items: [Item],
    _ make: (String) -> Object,
    _ update: (Object, Item) -> Void,
) {
    let old = Dictionary(owner[keyPath: list].map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let new = items.map { item in
        let object = old[item.id] ?? make(item.id)
        update(object, item)
        return object
    }
    if new.map(\.id) != owner[keyPath: list].map(\.id) {
        owner[keyPath: list] = new
    }
}
