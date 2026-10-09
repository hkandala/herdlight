import HerdrKit
import SwiftUI

@main
struct HerdlightApp: App {
    var body: some Scene {
        #if os(macOS)
            Window("Herdlight", id: "main") {
                ContentView()
            }
            .windowStyle(.hiddenTitleBar)
        #else
            WindowGroup {
                ContentUnavailableView("Herdlight for iOS is coming", systemImage: "iphone")
                    .preferredColorScheme(.dark)
            }
        #endif
    }
}

#if os(macOS)
    /// One for the app's life: it reads the login shell's environment once.
    private let exec = Task { await ProcessExec() }

    struct ContentView: View {
        /// `-session <name>` on the command line lands in UserDefaults.
        @State private var store = HostStore(session: UserDefaults.standard.string(forKey: "session") ?? "default")

        var body: some View {
            NavigationSplitView {
                Sidebar(store: $store)
            } detail: {
                Detail(store: store)
            }
            .navigationTitle(store.selectedTab?.label ?? HostStore.name(store.session))
            .containerBackground(Color.window, for: .window)
            .preferredColorScheme(.dark)
            // A new store (session switch) cancels the old one's run, which drops its client.
            .task(id: ObjectIdentifier(store)) { await store.run(exec: exec.value) }
        }
    }

    /// The selected workspace's tabs, or why there is nothing to show.
    private struct Detail: View {
        let store: HostStore

        var body: some View {
            switch store.state {
            case .connecting:
                ProgressView("Connecting to \(HostStore.name(store.session))")
            case .live:
                if let workspace = store.selectedWorkspace {
                    VStack(spacing: 0) {
                        TabBar(workspace: workspace)
                        Strip(workspace: workspace, store: store)
                    }
                    // The tab bar takes the empty title bar line next to the sidebar.
                    .ignoresSafeArea(edges: .top)
                } else {
                    message("No workspaces", "Create one in herdr:",
                            "herdr --session \(store.session) workspace create")
                }
            case .failed(.notFound):
                message("herdr is not installed", "Install it in a terminal:",
                        "curl -fsSL https://herdr.dev/install.sh | sh")
            case let .failed(.unsupported(text)):
                message("herdr is too old", text + ". Update it in a terminal:", "herdr update")
            case .failed where !store.isRunning:
                message("\(HostStore.name(store.session)) is not running", "Start it in a terminal:",
                        "herdr --session \(store.session) server")
            case let .failed(error):
                message("No answer from herdr", error.localizedDescription, nil)
            }
        }

        /// Plain text with the command to run: the app never starts herdr on This Mac (design D39).
        private func message(_ title: String, _ text: String, _ command: String?) -> some View {
            ContentUnavailableView {
                Label(title, systemImage: "terminal")
            } description: {
                Text(text)
                if let command {
                    Text(command).monospaced().textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("detail.message")
        }
    }
#endif
