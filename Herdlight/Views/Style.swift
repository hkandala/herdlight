import HerdrKit
import SwiftUI

extension Color {
    /// Opaque near-black, so no wallpaper shows through (design D33).
    static let window = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x12 / 255)
    static let card = Color(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1C / 255)
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
