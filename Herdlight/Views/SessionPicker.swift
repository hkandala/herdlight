import HerdrKit
import SwiftUI

/// The title-bar button with the session and its machine; it opens the session list.
struct SessionPicker: View {
    @Binding var store: HostStore
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "macbook").font(.system(size: 15)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.session).font(.system(size: 13, weight: .semibold))
                    Text("This Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
        .buttonStyle(ChromeStyle())
        .accessibilityIdentifier("titlebar.session-picker")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SessionList(store: $store, open: $open)
        }
    }
}

/// herdr's sessions on this Mac, filtered as you type. Running ones are selectable.
private struct SessionList: View {
    @Binding var store: HostStore
    @Binding var open: Bool
    @State private var filter = ""

    var body: some View {
        // Numbered before filtering, so ⌘n stays with its session.
        let sessions = store.sessions.enumerated().filter {
            filter.isEmpty || $0.element.name.localizedCaseInsensitiveContains(filter)
        }
        VStack(alignment: .leading, spacing: 2) {
            FilterField(prompt: "Filter or create…", text: $filter, identifier: "sessions.filter")
                .onSubmit {
                    if let first = sessions.first(where: \.element.running) {
                        pick(first.element.name)
                    }
                }
                .padding(.bottom, 4)
            Label("This Mac", systemImage: "laptopcomputer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
            ForEach(sessions, id: \.element.name) { index, session in
                let current = session.name == store.session
                Button { pick(session.name) } label: {
                    row(current ? "checkmark" : nil, session.name, index < 9 ? "⌘\(index + 1)" : "")
                }
                .buttonStyle(ChromeStyle(selected: current))
                .disabled(!session.running)
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil)
                .accessibilityIdentifier("session.\(session.name)")
            }
            Divider().padding(.vertical, 4)
            // ponytail: no-op until sessions can be created
            Button {} label: { row("rectangle.stack.badge.plus", "New Session", "⇧⌘N") }
                .buttonStyle(ChromeStyle())
            Divider().padding(.vertical, 4)
            // ponytail: no-op until remote hosts
            Button {} label: { row("network", "Add Remote Host…", "") }
                .buttonStyle(ChromeStyle())
        }
        .padding(8)
        .frame(width: 270)
    }

    private func row(_ symbol: String?, _ title: String, _ shortcut: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol ?? "circle").opacity(symbol == nil ? 0 : 1).frame(width: 18)
            Text(title)
            Spacer()
            Text(shortcut).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private func pick(_ session: String) {
        if session != store.session {
            store = HostStore(session: session)
        }
        open = false
    }
}
