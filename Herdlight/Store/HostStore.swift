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

        /// What the card header shows: the label, else the directory.
        var title: String {
            label ?? cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "terminal"
        }
    }

    /// A close waiting for the user's yes (design D41).
    enum Close {
        /// The pane and the program running in it.
        case pane(String, program: String)
        case tab(String)

        var isTab: Bool {
            if case .tab = self {
                true
            } else {
                false
            }
        }
    }

    let session: String
    /// Start the session's server first: it is stopped or new.
    private let start: Bool
    private(set) var state = State.connecting
    /// Every session herdr knows on this Mac, for the session picker.
    private(set) var sessions: [Session] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var panes: [Pane] = []
    var selectedWorkspaceID: String?
    /// The strip's scroll offset in pages (1.5 = halfway from the second tab to the third), for the tab marker. One
    /// strip shows every workspace, so one number.
    var page = 0.0
    /// The last failed write, shown for a few seconds.
    private(set) var notice: String?
    /// A write in flight; the buttons wait for it.
    private(set) var writing = false
    var closing: Close?
    /// The app's own zoom (design D11): this card fills its tab's page.
    var zoomedPaneID: String?
    /// A tab this app just made, selected once a snapshot shows it.
    @ObservationIgnored private var arriving: String?
    @ObservationIgnored private var client: HerdrClient?
    #if os(macOS)
        let terminals = PaneViewRegistry()
        /// The tab whose terminal last got the keyboard from the app.
        @ObservationIgnored private var keyboardTabID: String?
        /// The terminal that last had the keyboard in each tab: the app's own, like the selection.
        @ObservationIgnored private var keyboardTerminals: [String: String] = [:]
    #endif

    init(session: String, start: Bool = false) {
        self.session = session
        self.start = start
        #if os(macOS)
            terminals.onKeyboard = { [weak self] terminalID in
                guard let self, let tabID = panes.first(where: { $0.terminalID == terminalID })?.tabID else { return }
                keyboardTerminals[tabID] = terminalID
            }
        #endif
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

    /// Selects the tab before or after the selected one, round the ends.
    func step(_ offset: Int) {
        guard let workspace = selectedWorkspace, !workspace.tabs.isEmpty else { return }
        let tabs = workspace.tabs
        let index = tabs.firstIndex { $0.id == workspace.selectedTabID } ?? 0
        workspace.selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// The card keys go to: the terminal with the keyboard, else herdr's focused pane of the selected tab.
    var keyboardPane: Pane? {
        #if os(macOS)
            if let id = terminals.keyboardPaneID, let pane = pane(id) {
                return pane
            }
        #endif
        return panes.first { $0.tabID == selectedTab?.id && $0.focused }
    }

    /// The selected tab's terminals (terminal id → pane id): the ones that stream.
    var shownTerminals: [String: String] {
        Dictionary(panes.compactMap { pane in
            pane.tabID == selectedTab?.id ? pane.terminalID.map { ($0, pane.id) } : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    #if os(macOS)
        /// Streams the selected tab's terminals (see the registry), drops those of closed panes.
        func showTerminals() {
            let alive = Set(panes.compactMap(\.terminalID))
            terminals.show(shownTerminals, alive: alive)
            // A newly selected tab gives the keyboard back to the card it had; herdr's focused pane
            // only picks it the first time a tab is shown. Later snapshots leave it alone, unless the
            // card with the keyboard closed: then the tab's next card takes it.
            if let tab = selectedTab, let gone = keyboardTerminals[tab.id], !alive.contains(gone) {
                keyboardTerminals[tab.id] = nil
                focusKeyboardCard()
            } else if selectedTab?.id != keyboardTabID {
                focusKeyboardCard()
            }
        }

        /// Gives the keyboard to the selected tab's card: the one it last had, else herdr's focused pane.
        func focusKeyboardCard() {
            guard let tab = selectedTab else { return }
            let tabPanes = panes.filter { $0.tabID == tab.id && $0.terminalID != nil }
            let pane = tabPanes.first { $0.terminalID == keyboardTerminals[tab.id] }
                ?? tabPanes.first(where: \.focused) ?? tabPanes.first
            if let pane, let terminalID = pane.terminalID {
                keyboardTabID = tab.id
                // Made now if its card has not drawn yet (a tab just jumped to); it takes the keyboard once it is in
                // the window.
                _ = terminals.terminal(terminalID, pane: pane.id)
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
                if start {
                    try await client.startServer()
                    // A new server has no workspace yet.
                    if try await client.snapshot().workspaces.isEmpty {
                        let _: Created = try await client.call("workspace.create", ["cwd": NSHomeDirectory(),
                                                                                    "focus": false])
                    }
                }
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
        if let id = zoomedPaneID, pane(id) == nil {
            zoomedPaneID = nil
        }
        if let id = arriving, let workspace = workspaces.first(where: { $0.tabs.contains { $0.id == id } }) {
            arriving = nil
            selectedWorkspaceID = workspace.id
            workspace.selectedTabID = id
        }
        if selectedWorkspace == nil {
            selectedWorkspaceID = workspaces.contains { $0.id == snapshot.focusedWorkspaceID }
                ? snapshot.focusedWorkspaceID : workspaces.first?.id
        }
    }
}

/// Writes: each is one herdr call, then a snapshot read (design: writes are herdr calls).
extension HostStore {
    /// A split restores a zoomed layout first, as tmux does: the new pane shows.
    func split(_ paneID: String, _ direction: SplitNode.Direction) async {
        zoomedPaneID = nil
        await write("pane.split", ["target_pane_id": paneID, "direction": direction.rawValue, "focus": false])
    }

    /// A new tab in the selected workspace, in the keyboard card's directory.
    func newTab() async {
        guard let workspace = selectedWorkspace else { return }
        var cwd = keyboardPane?.cwd
        // Asked now: a `cd` sends no event, so the snapshot's cwd may be old.
        if let pane = keyboardPane, let fresh = try? await client?.pane(pane.id).cwd {
            cwd = fresh
        }
        await write("tab.create", ["workspace_id": workspace.id, "cwd": cwd ?? NSHomeDirectory(), "focus": false])
    }

    func newWorkspace() async {
        await write("workspace.create", ["cwd": NSHomeDirectory(), "focus": false])
    }

    /// Closes a pane that runs only its shell; asks first when anything else runs (design D41).
    func close(pane paneID: String) async {
        guard let client else { return }
        let program: String?
        do {
            program = try await client.program(paneID)
        } catch {
            // Unknown: ask.
            program = "A program"
        }
        if let program {
            closing = .pane(paneID, program: program)
        } else {
            await write("pane.close", ["pane_id": paneID])
        }
    }

    /// The user said yes.
    func close(_ close: Close) async {
        switch close {
        case let .pane(id, _): await write("pane.close", ["pane_id": id])
        case let .tab(id): await write("tab.close", ["tab_id": id])
        }
    }

    /// Zooms the card, or restores the layout when it is the zoomed one. The zoomed card gets the keyboard.
    func zoom(_ paneID: String) {
        zoomedPaneID = zoomedPaneID == paneID ? nil : paneID
        #if os(macOS)
            if zoomedPaneID != nil, let terminalID = pane(paneID)?.terminalID {
                terminals.focus(terminalID)
            }
        #endif
    }

    /// One write. No focus change; the snapshot after it draws the result, and selects a tab it made.
    private func write(_ method: String, _ params: [String: any Sendable]) async {
        guard let client else { return }
        guard !writing else {
            // A confirmed close must not vanish silently.
            await show("Busy, try again")
            return
        }
        writing = true
        notice = nil
        do {
            let created: Created = try await client.call(method, params)
            writing = false
            arriving = created.tab?.id ?? arriving
            await client.refresh()
        } catch {
            writing = false
            await show(error.localizedDescription)
        }
    }

    /// A notice for a few seconds, unless a newer one replaced it.
    private func show(_ text: String) async {
        notice = text
        try? await Task.sleep(for: .seconds(4))
        if notice == text {
            notice = nil
        }
    }
}

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
