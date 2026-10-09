import HerdrKit
import SwiftUI

@main
struct HerdlightApp: App {
    var body: some Scene {
        #if os(macOS)
            Window("Herdlight", id: "main") {
                ContentView()
            }
        #else
            WindowGroup {
                ContentView()
            }
        #endif
    }
}

struct ContentView: View {
    var body: some View {
        Group {
            #if os(macOS)
                NavigationSplitView {
                    List {
                        Text("Herdlight")
                    }
                    .accessibilityIdentifier("sidebar")
                } detail: {
                    ContentUnavailableView(
                        "No session",
                        systemImage: "terminal",
                        description: Text("For herdr \(herdrVersion)"),
                    )
                }
            #else
                ContentUnavailableView("Herdlight for iOS is coming", systemImage: "iphone")
            #endif
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
