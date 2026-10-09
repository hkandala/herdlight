import HerdrKit
import SwiftUI

@main
struct HerdlightApp: App {
    #if os(macOS)
        init() {
            SwipeRouter.install()
        }
    #endif

    var body: some Scene {
        #if os(macOS)
            Window("Herdlight", id: "main") {
                ContentView()
            }
            .windowToolbarStyle(.unifiedCompact)
            .defaultSize(width: 1200, height: 760)
            // Content never grows the window (the title-bar tabs would, when the sidebar hides).
            .windowResizability(.contentMinSize)
            .commands { TabCommands() }
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
        @State private var fullScreen = false

        var body: some View {
            VStack(spacing: 0) {
                TitleBar(store: store, fullScreen: fullScreen, sidebar: $sidebar, picking: $picking)
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
                                .padding(.leading, TitleBar.inset(fullScreen: fullScreen) + TitleBar.picker)
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
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
                fullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
                fullScreen = false
            }
            .navigationTitle(store.selectedTab?.label ?? HostStore.name(store.session))
            .preferredColorScheme(.dark)
            // The menu's ⌘1…⌘9 tabs step aside while the session list has its own ⌘1…⌘9.
            .focusedSceneValue(\.store, picking ? nil : store)
            // A new store (session switch) cancels the old one's run, which drops its client.
            .task(id: ObjectIdentifier(store)) { await store.run(exec: exec.value) }
            // Here, not in the detail: a failed or empty session must release its terminals too.
            .onChange(of: store.shownTerminals) { store.showTerminals() }
        }
    }

    extension FocusedValues {
        @Entry var store: HostStore?
    }

    /// In the Window menu: the selected workspace's tabs on ⌘1…⌘9, and ⇧⌘[ / ⇧⌘] for the one before or after.
    private struct TabCommands: Commands {
        @FocusedValue(\.store) private var store

        var body: some Commands {
            CommandGroup(after: .windowArrangement) {
                let workspace = store?.selectedWorkspace
                let tabs = workspace?.tabs ?? []
                Divider()
                Button("Show Previous Tab") { store?.step(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(tabs.count < 2)
                Button("Show Next Tab") { store?.step(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(tabs.count < 2)
                Divider()
                ForEach(Array(tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                    // The workspace when the key is pressed: the menu may be older than a workspace switch.
                    Button(tab.label) {
                        if let workspace = store?.selectedWorkspace, workspace.tabs.indices.contains(index) {
                            workspace.selectedTabID = workspace.tabs[index].id
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
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
