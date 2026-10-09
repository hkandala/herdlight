import HerdrKit
import SwiftUI

@main
struct HerdlightApp: App {
    var body: some Scene {
        #if os(macOS)
            Window("Herdlight", id: "main") {
                ContentView()
            }
            .windowToolbarStyle(.unifiedCompact)
            .defaultSize(width: 1200, height: 760)
            // Content never grows the window (the title-bar tabs would, when the sidebar hides).
            .windowResizability(.contentMinSize)
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
        @State private var sidebar = true
        @State private var picking = false

        var body: some View {
            VStack(spacing: 0) {
                TitleBar(store: store, sidebar: $sidebar, picking: $picking)
                HStack(spacing: 0) {
                    if sidebar {
                        Sidebar(store: store)
                            .padding([.leading, .bottom], gap)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Detail(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 4)
            }
            .overlay {
                if picking {
                    // A click outside the session list closes it.
                    Color.clear.contentShape(.rect).onTapGesture { picking = false }
                        .overlay(alignment: .topLeading) {
                            SessionList(store: $store, open: $picking)
                                .padding(.leading, TitleBar.picker)
                                .padding(.top, TitleBar.height + 4)
                        }
                }
            }
            // The title bar row takes the hidden title bar's line.
            .ignoresSafeArea(edges: .top)
            .containerBackground(for: .window) { Frosted().overlay(Color.tint) }
            .toolbar { ToolbarSpacer(.flexible) }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // In full screen the empty toolbar would cover the title row; it shows on hover only.
            .windowToolbarFullScreenVisibility(.onHover)
            .navigationTitle(store.selectedTab?.label ?? HostStore.name(store.session))
            .preferredColorScheme(.dark)
            // A new store (session switch) cancels the old one's run, which drops its client.
            .task(id: ObjectIdentifier(store)) { await store.run(exec: exec.value) }
        }
    }

    /// The window's frosted background. SwiftUI's materials blur only what is inside the window.
    private struct Frosted: NSViewRepresentable {
        func makeNSView(context _: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.material = .hudWindow
            // Blurred in an inactive window too, so the dark look holds.
            view.state = .active
            return view
        }

        func updateNSView(_: NSVisualEffectView, context _: Context) {}
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
                    Strip(workspace: workspace, store: store)
                        .overlay(alignment: .bottom) {
                            if let notice = store.notice {
                                Text(notice).padding(8).glassEffect().padding(gap * 2)
                                    .accessibilityIdentifier("detail.notice")
                            }
                        }
                        .onChange(of: store.shownTerminals, initial: true) { store.terminals.show($1) }
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
