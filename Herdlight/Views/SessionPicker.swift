import HerdrKit
import SwiftUI

/// The title-bar button with the session's name; it opens the session list.
struct SessionPicker: View {
    let store: HostStore
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").fontWeight(.medium).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(store.session).fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .buttonStyle(ChromeStyle(selected: open))
        .accessibilityIdentifier("titlebar.session-picker")
    }
}

/// herdr's sessions on this Mac, filtered as you type: running ones, and stopped ones on request (picking one
/// starts it). A glass panel under the picker button, not a popover: the reference has no arrow, and SwiftUI's
/// popover always draws one.
struct SessionList: View {
    @Binding var store: HostStore
    @Binding var open: Bool
    @State private var filter = ""
    @State private var showStopped = false
    /// The rows' own height: the list is as tall as its rows, up to about ten of them, then scrolls.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        // ⌘1…⌘9 go to the first nine running sessions, numbered before filtering so each keeps its number.
        let numbers = Dictionary(store.sessions.filter(\.running).prefix(9).enumerated().map { ($1.name, $0 + 1) },
                                 uniquingKeysWith: { first, _ in first })
        let sessions = shown, target = target, typedNew = typedNew
        VStack(alignment: .leading, spacing: 2) {
            FilterField(prompt: "Filter or create…", text: $filter, identifier: "sessions.filter", autofocus: true)
                // As in the palette: the handler reads the list as it is now.
                .onKeyPress(.return) {
                    if let session = shown.first(where: { $0.name == self.target }) {
                        pick(session)
                    } else if let name = self.typedNew {
                        create(name)
                    }
                    return .handled
                }
                .padding(.bottom, 4)
            HStack {
                // No host header over no rows; the toggle stays, it may reveal a match.
                if !sessions.isEmpty {
                    Label("This Mac", systemImage: "laptopcomputer")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show stopped", isOn: $showStopped)
                #if os(macOS)
                    .toggleStyle(.checkbox)
                #endif
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sessions.show-stopped")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sessions, id: \.name) { session in
                        let current = session.name == store.session
                        let lit = target.map { $0 == session.name } ?? current
                        let number = numbers[session.name]
                        Button { pick(session) } label: {
                            MenuRow(symbol: current ? "checkmark" : nil, title: session.name,
                                    detail: number.map { "⌘\($0)" } ?? (session.running ? "" : "stopped"),
                                    selected: lit)
                                .foregroundStyle(session.running ? .primary : .secondary)
                        }
                        .buttonStyle(ChromeStyle(selected: lit, tint: .accentColor))
                        .keyboardShortcut(number.map { KeyboardShortcut(KeyEquivalent(Character("\($0)"))) })
                        .accessibilityIdentifier("session.\(session.name)")
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(rowsHeight, 320))
            Divider().padding(.horizontal, 4).padding(.vertical, 4)
            // ⇧⌘N is the menu's; the row only shows it.
            Button { create(typedNew ?? store.sessions.newName) } label: {
                MenuRow(symbol: "rectangle.stack.badge.plus", title: typedNew.map { "New Session “\($0)”" }
                    ?? "New Session", detail: typedNew == nil ? "⇧⌘N" : "")
            }
            .buttonStyle(ChromeStyle())
            .accessibilityIdentifier("sessions.new")
            Divider().padding(.horizontal, 4).padding(.vertical, 4)
            // ponytail: no-op until remote hosts
            Button {} label: { MenuRow(symbol: "network", title: "Add Remote Host…") }
                .buttonStyle(ChromeStyle())
        }
        .padding(8)
        .frame(width: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .task { await store.loadSessions() }
    }

    /// The rows: running sessions, then stopped ones on request, that pass the filter.
    private var shown: [Session] {
        let sessions = store.sessions.filter {
            ($0.running || showStopped || $0.name == store.session) && $0.name.matches(filter)
        }
        return sessions.filter(\.running) + sessions.filter { !$0.running }
    }

    /// The row Enter picks, lit while a filter is typed.
    private var target: String? {
        filter.isEmpty ? nil : (shown.first(where: \.running) ?? shown.first)?.name
    }

    /// A typed name no session has yet: New Session makes it.
    private var typedNew: String? {
        let typed = filter.trimmingCharacters(in: .whitespaces)
        return Session.isValidName(typed) && !store.sessions.contains { $0.name == typed } ? typed : nil
    }

    /// Starts a new session and switches to it.
    private func create(_ name: String) {
        store = HostStore(session: name, start: true)
        open = false
    }

    /// Switches to the session; a stopped one starts (design D47).
    private func pick(_ session: Session) {
        if session.name != store.session {
            store = HostStore(session: session.name, start: !session.running)
        }
        open = false
    }
}

extension [Session] {
    /// A readable name no session has yet, like the references' `lunar-ridge`.
    var newName: String {
        let first = ["amber", "brisk", "calm", "early", "lunar", "misty", "quiet", "sunny"]
        let second = ["cedar", "dune", "grove", "harbor", "meadow", "peak", "ridge", "river"]
        let names = first.flatMap { word in second.map { "\(word)-\($0)" } }
        return names.shuffled().first { name in !contains { $0.name == name } } ?? "session-\(count + 1)"
    }
}
