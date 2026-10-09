import HerdrKit
import SwiftUI

/// The title-bar button with the session and its machine; it opens the session list.
struct SessionPicker: View {
    let store: HostStore
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "macbook").imageScale(.large).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.session).fontWeight(.semibold)
                    Text("This Mac").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(ChromeStyle(selected: open))
        .accessibilityIdentifier("titlebar.session-picker")
    }
}

/// herdr's sessions on this Mac, filtered as you type. Running ones are selectable. A glass panel under the
/// picker button, not a popover: the reference has no arrow, and SwiftUI's popover always draws one.
struct SessionList: View {
    @Binding var store: HostStore
    @Binding var open: Bool
    @State private var filter = ""

    var body: some View {
        // ⌘1…⌘9 go to the first nine running sessions, numbered before filtering so each keeps its number.
        let numbers = Dictionary(uniqueKeysWithValues: store.sessions.filter(\.running).prefix(9).enumerated()
            .map { ($1.name, $0 + 1) })
        let sessions = store.sessions.filter { $0.name.matches(filter) }
        VStack(alignment: .leading, spacing: 2) {
            FilterField(prompt: "Filter or create…", text: $filter, identifier: "sessions.filter", autofocus: true)
                .onSubmit {
                    // ponytail: no match creates nothing until sessions can be created
                    if let first = sessions.first(where: \.running) {
                        pick(first.name)
                    }
                }
                .padding(.bottom, 4)
            Label("This Mac", systemImage: "laptopcomputer")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sessions, id: \.name) { session in
                        let current = session.name == store.session
                        let number = numbers[session.name]
                        Button { pick(session.name) } label: {
                            row(current ? "checkmark" : nil, session.name, number.map { "⌘\($0)" } ?? "", current)
                        }
                        .buttonStyle(ChromeStyle(selected: current, tint: .accentColor))
                        .disabled(!session.running)
                        .keyboardShortcut(number.map { KeyboardShortcut(KeyEquivalent(Character("\($0)"))) })
                        .accessibilityIdentifier("session.\(session.name)")
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.never)
            // As tall as the rows, up to about ten of them.
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.horizontal, 4).padding(.vertical, 4)
            // ponytail: no-op until sessions can be created
            Button {} label: { row("rectangle.stack.badge.plus", "New Session", "⇧⌘N") }
                .buttonStyle(ChromeStyle())
            Divider().padding(.horizontal, 4).padding(.vertical, 4)
            // ponytail: no-op until remote hosts
            Button {} label: { row("network", "Add Remote Host…", "") }
                .buttonStyle(ChromeStyle())
        }
        .padding(8)
        .frame(width: 220)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .task { await store.loadSessions() }
        #if os(macOS)
            .onExitCommand { open = false }
        #endif
    }

    private func row(_ symbol: String?, _ title: String, _ shortcut: String, _ current: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol ?? "circle").opacity(symbol == nil ? 0 : 1).frame(width: 18)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer()
            // Readable on the accent pill too.
            Text(shortcut).foregroundStyle(.white.opacity(current ? 0.75 : 0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func pick(_ session: String) {
        if session != store.session {
            store = HostStore(session: session)
        }
        open = false
    }
}
