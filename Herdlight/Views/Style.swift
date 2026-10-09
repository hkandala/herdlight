import HerdrKit
import SwiftUI

extension Color {
    /// Over the frosted window: dark, so the desktop shows through only softly.
    static let tint = Color.black.opacity(0.4)
    static let card = Color.black.opacity(0.3)
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
    }
}

/// Rows, buttons and capsules: flat at rest, a soft fill under the pointer, a raised pill when selected.
struct ChromeStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, radius: radius)
    }

    struct Chrome: View {
        let configuration: Configuration
        let selected: Bool
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let fill = selected ? 0.13 : configuration.isPressed ? 0.1 : hovering && enabled ? 0.06 : 0
            configuration.label
                .contentShape(shape)
                .background(.white.opacity(fill), in: shape)
                .overlay(shape.strokeBorder(Color.hairline.opacity(selected ? 1 : 0)))
                .shadow(color: .black.opacity(selected ? 0.35 : 0), radius: 3, y: 1)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// An SF Symbol button for the title bar, the sidebar and card headers.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ChromeStyle(radius: 7))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The filter field of the sidebar and the session picker.
struct FilterField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityIdentifier(identifier)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.white.opacity(0.07), in: .capsule)
    }
}
