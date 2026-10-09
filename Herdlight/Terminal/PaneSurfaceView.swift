#if os(macOS)
    import AppKit
    import GhosttyTerminal
    import HerdrKit
    import SwiftUI

    /// libghostty's view with herdr's input path. herdr's frames carry none of the app's input
    /// modes (cursor keys, kitty keyboard, mouse), so libghostty would encode keys and clicks for
    /// a plain terminal. Keys whose bytes depend on those modes go to herdr by name, clicks and the
    /// wheel go as cells; herdr encodes them for the app (phase 4 findings).
    final class PaneSurfaceView: AppTerminalView {
        weak var terminal: PaneTerminal?
        /// libghostty's grid and cell size, for cells under the pointer. The in-memory session's own
        /// sizes carry no cell size.
        private(set) var metrics: TerminalGridMetrics?
        private var dragged: (column: Int, row: Int)?
        private var scrolled: CGFloat = 0

        /// Asked for the keyboard before it was in a window.
        var wantsKeyboard = false
        /// Took the keyboard.
        var onKeyboard: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            delegate = self
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("Terminal")
        }

        /// Gives this terminal the keyboard, now or once it is in a window.
        func takeKeyboard() {
            wantsKeyboard = window == nil
            window?.makeFirstResponder(self)
        }

        /// SwiftUI moves the view to a new host when the layout changes (a split); leaving the
        /// window drops the first responder, so it takes the keyboard back once it is in again.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window?.firstResponder === self {
                wantsKeyboard = true
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsKeyboard, let window {
                wantsKeyboard = false
                // After SwiftUI's update: focus asked for mid-update is dropped.
                DispatchQueue.main.async { window.makeFirstResponder(self) }
            }
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            terminal?.hasKeyboard = became
            if became {
                onKeyboard?()
            }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                terminal?.hasKeyboard = false
            }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            if !hasMarkedText(), let key = Self.herdrKey(event) {
                terminal?.keys([key])
            } else {
                super.keyDown(with: event)
            }
        }

        // Clicks go to herdr and to libghostty, for local selection and Copy in a plain shell.
        // ponytail: in a mouse app a drag also draws libghostty's highlight; select locally only on
        // Shift+drag if that noise bothers users.
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            mouse(.down, .left, event)
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            mouse(.drag, .left, event)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            mouse(.up, .left, event)
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
            mouse(.down, .right, event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            super.rightMouseDragged(with: event)
            mouse(.drag, .right, event)
        }

        override func rightMouseUp(with event: NSEvent) {
            super.rightMouseUp(with: event)
            mouse(.up, .right, event)
        }

        /// Middle clicks skip libghostty, which could paste its selection as typed input.
        override func otherMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            mouse(.down, .middle, event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            mouse(.drag, .middle, event)
        }

        override func otherMouseUp(with event: NSEvent) {
            mouse(.up, .middle, event)
        }

        override func scrollWheel(with event: NSEvent) {
            // Sideways belongs to the strip (phase 5 adds the axis lock).
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
                nextResponder?.scrollWheel(with: event)
                return
            }
            guard let cell = cell(event), let metrics else { return }
            // Trackpads report points, wheels report lines.
            scrolled += event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY * scale / CGFloat(metrics.cellHeightPixels) : event.scrollingDeltaY
            let lines = Int(scrolled)
            scrolled -= CGFloat(lines)
            if lines != 0 {
                // A positive delta shows older lines: up.
                terminal?.scroll(lines: -lines, column: cell.column, row: cell.row, modifiers: modifiers(event))
            }
        }

        private func mouse(_ action: TerminalStream.MouseAction, _ button: TerminalStream.MouseButton,
                           _ event: NSEvent)
        {
            // Back and forward buttons are other buttons too, not middle clicks.
            guard button != .middle || event.buttonNumber == 2, let cell = cell(event) else { return }
            if action == .drag, let dragged, dragged == cell {
                return
            }
            dragged = action == .up ? nil : cell
            terminal?.mouse(action, button, column: cell.column, row: cell.row, modifiers: modifiers(event))
        }

        private var scale: CGFloat {
            window?.backingScaleFactor ?? 2
        }

        /// The 0-based cell under the pointer. No padding (see `PaneTerminal.controller`).
        private func cell(_ event: NSEvent) -> (column: Int, row: Int)? {
            guard let metrics, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            let column = Int(point.x * scale) / Int(metrics.cellWidthPixels)
            let row = Int((bounds.height - point.y) * scale) / Int(metrics.cellHeightPixels)
            return (min(max(column, 0), Int(metrics.columns) - 1), min(max(row, 0), Int(metrics.rows) - 1))
        }

        /// crossterm bits: 1 shift, 2 ctrl, 4 alt.
        private func modifiers(_ event: NSEvent) -> Int {
            let flags = event.modifierFlags
            return (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
                | (flags.contains(.option) ? 4 : 0)
        }

        private static let names: [UInt16: String] = [
            36: "enter", 76: "enter", 48: "tab", 51: "backspace", 53: "esc",
            123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        ]

        /// The US character of each letter, digit and symbol key (kVK_ANSI_*), for Ctrl chords on
        /// layouts whose letters are not Latin.
        private static let ansi: [UInt16: String] = {
            var keys = [UInt16: String](uniqueKeysWithValues: zip(
                0...,
                "asdfhgzxcv_bqweryt123465=97-80]ou[ip_lj'k;\\,/nm.",
            )
            .filter { $0.1 != "_" }
            .map { (UInt16($0.0), String($0.1)) })
            keys[49] = "space"
            keys[50] = "`"
            return keys
        }()

        /// herdr's name (`pane.send_keys`) for a key whose bytes depend on the app's input modes:
        /// arrows, Esc, F-keys, any of them with modifiers, Ctrl chords; plus macOS line editing
        /// (Cmd+←/→/⌫, Option+←/→), which `keybind = clear` took from libghostty. nil leaves the
        /// key to libghostty: text, IME, dead keys, Option characters, other Cmd keys, and plain
        /// Enter, Tab and Backspace, which are the same bytes in every mode and stay off the slower
        /// bridge path. Home, End, Page Up/Down and Delete have no herdr names; libghostty sends
        /// them as xterm does.
        /// ponytail: Option types characters (Ghostty's default); add an option-as-alt setting when asked.
        static func herdrKey(_ event: NSEvent) -> String? {
            let flags = event.modifierFlags
            let control = flags.contains(.control), option = flags.contains(.option), shift = flags.contains(.shift)
            let named = names[event.keyCode]
            if flags.contains(.command) {
                guard !control, !option else { return nil }
                return ["left": "ctrl+a", "right": "ctrl+e", "backspace": "ctrl+u"][named ?? ""]
            }
            if option, !control, !shift, let word = ["left": "alt+b", "right": "alt+f"][named ?? ""] {
                return word
            }
            let prefix = (control ? "ctrl+" : "") + (option ? "alt+" : "")
            if let named {
                if !control, !option, !shift, ["enter", "tab", "backspace"].contains(named) {
                    return nil
                }
                return prefix + (shift && named != "esc" ? "shift+" : "") + named
            }
            // The layout's letter (Dvorak, AZERTY), else the key's US character (Ctrl+С on a Russian
            // layout is Ctrl+C). Shift is dropped, as xterm does: Ctrl+Shift+C is Ctrl+C.
            guard control else { return nil }
            if let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1,
               letter.first?.isASCII == true, letter.first?.isLetter == true
            {
                return prefix + letter
            }
            return ansi[event.keyCode].map { prefix + $0 }
        }
    }

    extension PaneSurfaceView {
        override func accessibilityIdentifier() -> String {
            terminal.map { "terminal.\($0.paneID)" } ?? ""
        }

        /// The grid as `stty size` prints it (rows, columns), for e2e tests.
        /// ponytail: grid size until VoiceOver gets the screen text (design: accessibility).
        override func accessibilityValue() -> Any? {
            metrics.map { "\($0.rows) \($0.columns)" }
        }
    }

    extension PaneSurfaceView: TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate {
        func terminalDidResize(_ size: TerminalGridMetrics) {
            metrics = size
        }

        /// A new surface starts focused (a filled cursor) until it first loses the keyboard, and
        /// libghostty-spm has no public way to set a surface's focus; resigning is the one that
        /// tells the surface it is not focused.
        func terminalDidAttachSurface(_: TerminalSurface) {
            if window?.firstResponder !== self {
                _ = resignFirstResponder()
            }
        }

        func terminalDidDetachSurface() {}
    }

    /// Shows a pane's terminal view. The registry owns the view; the newest host adopts it, so a page
    /// SwiftUI rebuilds while the strip scrolls never destroys the surface (design: making the strip
    /// work).
    struct TerminalHost: NSViewRepresentable {
        let terminal: PaneTerminal

        func makeNSView(context _: Context) -> NSView {
            let host = NSView()
            let view = terminal.view
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
            return host
        }

        func updateNSView(_: NSView, context _: Context) {}
    }

    /// A card's terminal, with what to do when it does not stream.
    struct TerminalCard: View {
        let terminal: PaneTerminal

        var body: some View {
            TerminalHost(terminal: terminal)
                // A new terminal in the same spot (panes swapped) needs a new host to adopt it.
                .id(ObjectIdentifier(terminal))
                .overlay(alignment: .bottom) {
                    switch terminal.state {
                    case .watching:
                        Button("In use elsewhere · Take back", action: terminal.takeBack)
                            .buttonStyle(.glass)
                            .padding(gap)
                    case let .failed(text):
                        VStack {
                            Text("Restart herdr on This Mac")
                            Text(text).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(gap)
                    case .idle, .live:
                        EmptyView()
                    }
                }
        }
    }
#endif
