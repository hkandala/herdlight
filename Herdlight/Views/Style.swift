import HerdrKit
import SwiftUI

extension Color {
    /// Over the frosted window: dark, so the desktop shows through only softly.
    static let tint = Color.black.opacity(0.4)
    /// Lighter than the window, so cards float on it.
    static let card = Color.white.opacity(0.04)
    static let hairline = Color.white.opacity(0.09)
}

/// ◔ working, ▲ needs you; nothing when idle. Static: no animation, so nothing redraws while agents work.
struct StatusGlyph: View {
    let status: AgentStatus

    var body: some View {
        switch status {
        case .working:
            Text("◔").foregroundStyle(.blue).accessibilityLabel("working")
        case .blocked:
            Text("▲").foregroundStyle(Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255))
                .accessibilityLabel("needs you")
        default:
            EmptyView()
        }
    }
}

/// The small terminal tile on tabs and rows.
struct IconTile: View {
    var body: some View {
        Text(">_")
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(Color(red: 0.6, green: 0.88, blue: 0.62))
            .frame(width: 22, height: 18)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.hairline))
            .accessibilityHidden(true)
    }
}

/// Rows, buttons and capsules: flat at rest, a soft fill under the pointer, a raised pill when selected.
struct ChromeStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 8
    /// The selected fill; a raised light pill when nil.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Chrome(style: self, configuration: configuration)
    }

    struct Chrome: View {
        let style: ChromeStyle
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
            let white = style.selected ? 0.16 : configuration.isPressed ? 0.1 : hovering && enabled ? 0.06 : 0
            configuration.label
                .contentShape(shape)
                .background(style.selected ? style.tint ?? .white.opacity(white) : .white.opacity(white), in: shape)
                .overlay(shape.strokeBorder(Color.hairline.opacity(style.selected ? 1 : 0)))
                .shadow(color: .black.opacity(style.selected ? 0.3 : 0), radius: 4, y: 1)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// A row of the session list and the palette: a symbol, a title, and a shortcut or hint on the right.
struct MenuRow: View {
    var symbol: String?
    let title: String
    var detail = ""
    /// On the accent pill.
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol ?? "circle").opacity(symbol == nil ? 0 : 1).frame(width: 18)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer()
            // Readable on the accent pill too.
            Text(detail).foregroundStyle(.white.opacity(selected ? 0.75 : 0.5)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// An SF Symbol button for the title bar, the sidebar and card headers.
struct IconButton: View {
    let symbol: String
    let help: String
    /// Dimmer, for controls that do nothing yet.
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .fontWeight(.medium)
                .foregroundStyle(quiet ? HierarchicalShapeStyle.tertiary : .secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ChromeStyle(radius: 7))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The filter field of the sidebar and the session list. Until clicked (or with `autofocus`) it is plain text,
/// so the window has no text field to hand the keyboard to at launch; keys belong to the panes.
struct FilterField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    var autofocus = false
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if editing || autofocus || !text.isEmpty {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .task {
                        // ponytail: focus asked for as the field appears is dropped (AppKit has not made it a
                        // key view yet); a short wait works. Upgrade: an AppKit field that takes first responder
                        // in viewDidMoveToWindow.
                        try? await Task.sleep(for: .milliseconds(100))
                        focused = true
                    }
                    .onChange(of: focused) { editing = focused }
                    .accessibilityIdentifier(identifier)
            } else {
                // A button, not a field: it can't take the keyboard at launch, and VoiceOver can press it.
                Button { editing = true } label: {
                    Text(prompt).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.07), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture { editing = true }
    }
}

extension String {
    /// Whether this label passes a typed filter: trimmed, case and accent blind, empty passes all.
    func matches(_ filter: String) -> Bool {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        return filter.isEmpty || localizedStandardContains(filter)
    }
}
