import HerdrKit
import SwiftUI

@main
struct HerdlightApp: App {
    #if os(macOS)
        init() {
            SwipeRouter.install()
            // One window; no tab bar or tab menu items of AppKit's own.
            NSWindow.allowsAutomaticWindowTabbing = false
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
            .commands {
                TabCommands()
                ActionCommands()
            }
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
        @State private var palette = false

        var body: some View {
            VStack(spacing: 0) {
                TitleBar(store: store, fullScreen: fullScreen, sidebar: $sidebar, picking: $picking, palette: $palette)
                HStack(spacing: 0) {
                    if sidebar {
                        Sidebar(store: store)
                            .padding([.leading, .bottom], gap)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Detail(store: $store)
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
                if palette {
                    Color.clear.contentShape(.rect).onTapGesture { palette = false }
                        .overlay(alignment: .top) { Palette(store: $store, open: $palette).padding(.top, 96) }
                }
            }
            .confirmationDialog(dialog?.title ?? "", isPresented: Binding { store.closing != nil } set: {
                if !$0 {
                    store.closing = nil
                }
            }, titleVisibility: .visible, presenting: store.closing) { close in
                Button(close.isTab ? "Close Tab" : "Close Pane", role: .destructive) {
                    Task { await store.close(close) }
                }
            } message: { _ in
                Text(dialog?.message ?? "")
            }
            // The title bar row takes the hidden title bar's line.
            .ignoresSafeArea(edges: .top)
            .containerBackground(for: .window) { Frosted().overlay(Color.tint) }
            .toolbar { ToolbarSpacer(.flexible) }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // In full screen the empty toolbar would cover the title row; it shows on hover only.
            .windowToolbarFullScreenVisibility(.onHover)
            .background(FullScreenReader(fullScreen: $fullScreen))
            .navigationTitle(store.selectedTab?.label ?? HostStore.name(store.session))
            .preferredColorScheme(.dark)
            // The menu's ⌘1…⌘9 tabs step aside while the session list has its own ⌘1…⌘9.
            .focusedSceneValue(\.store, picking ? nil : $store)
            .focusedSceneValue(\.palette, $palette)
            // The palette and the session list never show together; a closed palette gives the keys back.
            .onChange(of: palette) {
                if palette {
                    picking = false
                } else {
                    store.focusKeyboardCard()
                }
            }
            // A new store (session switch) cancels the old one's run, which drops its client.
            .task(id: ObjectIdentifier(store)) { await store.run(exec: exec.value) }
            // Here, not in the detail: a failed or empty session must release its terminals too.
            .onChange(of: store.shownTerminals) { store.showTerminals() }
        }

        /// The close dialog's text (design D41): a close ends processes on every device and cannot be undone.
        private var dialog: (title: String, message: String)? {
            switch store.closing {
            case let .tab(id):
                let tab = store.workspaces.flatMap(\.tabs).first { $0.id == id }
                let count = store.panes.count { $0.tabID == id }
                return ("Close the tab “\(tab?.label ?? id)”?",
                        "Its \(count == 1 ? "pane" : "\(count) panes") and everything running in "
                            + "\(count == 1 ? "it" : "them") will end, here and in every herdr client. "
                            + "This cannot be undone.")
            case let .pane(id, program):
                let pane = store.pane(id)
                return ("Close “\(pane?.label ?? pane?.cwd.map { ($0 as NSString).lastPathComponent } ?? id)”?",
                        "\(program) is running in it and will end, here and in every herdr client. "
                            + "This cannot be undone.")
            case nil:
                return nil
            }
        }
    }

    extension FocusedValues {
        /// The window's store, for the menu commands.
        @Entry var store: Binding<HostStore>?
        @Entry var palette: Binding<Bool>?
    }

    /// The menu bar's actions on the window's store; the shortcuts work wherever the keyboard is.
    private struct ActionCommands: Commands {
        @FocusedBinding(\.store) private var store
        @FocusedBinding(\.palette) private var palette

        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { Task { await store?.newTab() } }
                    .keyboardShortcut("t")
                    .disabled(store?.selectedWorkspace == nil)
                Button("New Session") {
                    if let sessions = store?.sessions {
                        store = HostStore(session: sessions.newName, start: true)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store == nil)
            }
            // ⌘W closes the keyboard card, ⇧⌘W the window (design: keyboard).
            CommandGroup(replacing: .saveItem) {
                Button("Close Pane") {
                    if let store, let pane = store.keyboardPane {
                        Task { await store.close(pane: pane.id) }
                    }
                }
                .keyboardShortcut("w")
                .disabled(store?.keyboardPane == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Command Palette") { palette?.toggle() }
                    .keyboardShortcut("k")
                    .disabled(palette == nil)
                Button("Zoom Pane") {
                    guard let store else { return }
                    if let zoomed = store.zoomedPaneID, store.pane(zoomed)?.tabID == store.selectedTab?.id {
                        store.zoom(zoomed)
                    } else if let pane = store.keyboardPane {
                        store.zoom(pane.id)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(store?.keyboardPane == nil)
            }
        }
    }

    /// In the Window menu: the selected workspace's tabs on ⌘1…⌘9, and ⇧⌘[ / ⇧⌘] for the one before or after.
    private struct TabCommands: Commands {
        @FocusedBinding(\.store) private var store

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

    /// Whether this view's window is in full screen (or on its way in), from its style and its notifications.
    private struct FullScreenReader: NSViewRepresentable {
        @Binding var fullScreen: Bool

        func makeNSView(context _: Context) -> Reader {
            Reader()
        }

        func updateNSView(_ reader: Reader, context _: Context) {
            reader.changed = { fullScreen = $0 }
        }

        final class Reader: NSView {
            var changed: (Bool) -> Void = { _ in }
            private var observers: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                guard let window else { return }
                let notifications = [NSWindow.willEnterFullScreenNotification: true,
                                     NSWindow.willExitFullScreenNotification: false]
                for (name, value) in notifications {
                    let center = NotificationCenter.default
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.changed(value) }
                    })
                }
                // After SwiftUI's update, which may not change state.
                let full = window.styleMask.contains(.fullScreen)
                DispatchQueue.main.async { [weak self] in self?.changed(full) }
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
        @Binding var store: HostStore

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
                message("\(HostStore.name(store.session)) is not running", "Start it here, or in a terminal:",
                        "herdr --session \(store.session) server", start: true)
            case let .failed(error):
                message("No answer from herdr", error.localizedDescription, nil)
            }
        }

        /// What is wrong and the command that fixes it; a stopped session also gets a Start button (design D47).
        private func message(_ title: String, _ text: String, _ command: String?, start: Bool = false) -> some View {
            ContentUnavailableView {
                Label(title, systemImage: "terminal")
            } description: {
                Text(text)
                if let command {
                    Text(command).monospaced().textSelection(.enabled)
                }
            } actions: {
                if start {
                    Button("Start \(store.session)") { store = HostStore(session: store.session, start: true) }
                        .accessibilityIdentifier("detail.start")
                }
            }
            .accessibilityIdentifier("detail.message")
        }
    }
#endif
