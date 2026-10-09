#if os(macOS)
    import AppKit
    import GhosttyTerminal
    import HerdrKit
    import Observation

    /// One pane's live terminal: herdr's frames drawn by a libghostty surface (host-managed
    /// backend), with keys, clicks and the wheel going back to herdr.
    @MainActor @Observable
    final class PaneTerminal {
        enum State: Equatable {
            /// No stream: not on the selected tab, released, or the pane is gone.
            case idle
            case live
            /// Another client controls the pane: watch until the user acts (design D8).
            case watching
            case failed(String)
        }

        enum Input {
            /// Bytes from libghostty: typed text, IME, pastes.
            case text(String)
            /// herdr logical keys, encoded by herdr for the app's input modes.
            case keys([String])
        }

        private(set) var state = State.idle
        /// The surface's last grid, for cells under the pointer.
        @ObservationIgnored private(set) var grid: InMemoryTerminalViewport?
        @ObservationIgnored let view = PaneSurfaceView(frame: .zero)
        @ObservationIgnored var paneID: String
        @ObservationIgnored private let terminalID: String
        @ObservationIgnored private let client: HerdrClient
        @ObservationIgnored private let session: InMemoryTerminalSession
        @ObservationIgnored private var pending: [Input] = []
        @ObservationIgnored private var draining: Task<Void, Never>?
        @ObservationIgnored private var tasks: [Task<Void, Never>] = []
        @ObservationIgnored private var run: Task<Void, Never>?
        @ObservationIgnored private var resizing: Task<Void, Never>?
        @ObservationIgnored private var stream: TerminalStream?
        @ObservationIgnored private var observing = false
        @ObservationIgnored private var shown = false
        /// A stream is on its way to its first frame; input waits for it.
        @ObservationIgnored private var opening = false
        /// Counts streams, so a stream that is ending cannot change the state of the next one.
        @ObservationIgnored private var generation = 0
        @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?

        /// `keybind = clear`: app shortcuts reach the menu. Transparent, so the card shows through.
        /// No padding, so cells map from the view's origin; no scrollback, herdr keeps it.
        private static let controller = TerminalController {
            $0.withCustom("keybind", "clear")
            $0.withBackgroundOpacity(0)
            $0.withWindowPaddingX(0)
            $0.withWindowPaddingY(0)
            $0.withCustom("window-padding-balance", "false")
            $0.withCustom("scrollback-limit", "0")
        }

        init(terminalID: String, paneID: String, client: HerdrClient) {
            self.terminalID = terminalID
            self.paneID = paneID
            self.client = client
            // libghostty writes on its own IO thread; a stream keeps the order.
            let (texts, text) = AsyncStream<String>.makeStream()
            let (sizes, size) = AsyncStream<InMemoryTerminalViewport>.makeStream()
            session = InMemoryTerminalSession(
                write: { text.yield(String(decoding: $0, as: UTF8.self)) },
                resize: { size.yield($0) },
                suppressesPixelOnlyResizes: true,
            )
            // Pastes leave libghostty framed, and herdr frames them again for the app's own mode.
            session.receive("\u{1B}[?2004h")
            view.terminal = self
            view.controller = Self.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            tasks = [
                Task { for await text in texts {
                    enqueue(.text(text))
                } },
                Task { for await size in sizes {
                    resized(size)
                } },
            ]
        }

        /// The card is on the selected tab: stream it.
        func show() {
            guard !shown else { return }
            shown = true
            open()
        }

        /// The card left the selected tab: let go (design: what streams). It keeps its last image.
        func hide() {
            shown = false
            end()
        }

        /// The session is going away.
        func close() {
            hide()
            tasks.forEach { $0.cancel() }
            draining?.cancel()
            pending = []
            wake()
        }

        /// Take back: control with `--takeover`.
        func takeBack() {
            open(takeover: true)
        }

        func keys(_ keys: [String]) {
            enqueue(.keys(keys))
        }

        func mouse(_ action: TerminalStream.MouseAction, _ button: TerminalStream.MouseButton,
                   column: Int, row: Int, modifiers: Int)
        {
            if state == .watching, action == .down {
                takeBack()
            } else if state == .live {
                stream?.mouse(action, button, column: column, row: row, modifiers: modifiers)
            }
        }

        func scroll(lines: Int, column: Int, row: Int, modifiers: Int) {
            if state == .live {
                stream?.scroll(lines: lines, column: column, row: row, modifiers: modifiers)
            }
        }

        // MARK: Stream

        private func open(observe: Bool = false, takeover: Bool = false) {
            guard shown, let grid else { return }
            end()
            observing = observe
            opening = true
            let generation = generation
            let previous = run
            run = Task {
                // The last stream ends first, so herdr never sees two of ours on one pane.
                await previous?.value
                let stream: TerminalStream
                do {
                    stream = try await client.terminal(terminalID, cols: Int(grid.columns), rows: Int(grid.rows),
                                                       observe: observe, takeover: takeover)
                } catch {
                    if generation == self.generation {
                        state = .failed(error.localizedDescription)
                        wake()
                    }
                    return
                }
                if generation == self.generation {
                    self.stream = stream
                }
                // A cancelled task ends the iteration at once, which kills the run.
                for await event in stream.events where generation == self.generation {
                    switch event {
                    case let .frame(frame):
                        session.receive(frame.bytes)
                        if opening {
                            state = observe ? .watching : .live
                            // The card may have changed size while the stream opened.
                            if !observe, let now = self.grid, frame.width != now.columns || frame.height != now.rows {
                                sendSize()
                            }
                            wake()
                        }
                    case let .closed(reason):
                        self.stream = nil
                        closed(reason, observe: observe)
                    }
                }
            }
        }

        /// Ends the current stream: a controller releases (and its run drains), a watcher stops.
        private func end() {
            generation += 1
            if let stream, !observing {
                stream.release()
            } else {
                run?.cancel()
            }
            stream = nil
            state = .idle
            wake()
        }

        private func closed(_ reason: TerminalStream.Closed, observe: Bool) {
            state = .idle
            switch reason {
            case .held, .takenOver:
                // Watch; never take back by itself. A new task: `open` waits for this run to end.
                Task { open(observe: true) }
            case .liveUpdate:
                // ponytail: one retry after 1 s; the design also pings and checks the version.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    open(observe: observe)
                }
            case .gone, .detached:
                // Gone: the next snapshot drops the card.
                break
            case let .failed(text):
                state = .failed(text)
            }
            wake()
        }

        // MARK: Size and input

        /// libghostty's grid for the card's size. Sent to herdr once the size settles.
        private func resized(_ size: InMemoryTerminalViewport) {
            let first = grid == nil
            grid = size
            if first, shown {
                open()
                return
            }
            resizing?.cancel()
            resizing = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if state == .watching {
                    // observe cannot resize: watch again at the new size.
                    open(observe: true)
                } else if state == .live {
                    sendSize()
                }
            }
        }

        private func sendSize() {
            guard let grid else { return }
            stream?.resize(cols: Int(grid.columns), rows: Int(grid.rows),
                           cellWidth: Int(grid.cellWidthPixels), cellHeight: Int(grid.cellHeightPixels))
        }

        /// Input goes out in order, one at a time: a key waits for herdr's answer before the next
        /// text goes out. A bridge call takes about 60 ms, more than a held key's repeat, so what
        /// piles up meanwhile goes as one call. ponytail: keys (main thread) and libghostty's text
        /// (its IO thread) are ordered only as they arrive here, microseconds apart; enough for typing.
        private func enqueue(_ input: Input) {
            switch (pending.last, input) {
            case let (.keys(old)?, .keys(new)):
                pending[pending.count - 1] = .keys(old + new)
            case let (.text(old)?, .text(new)):
                pending[pending.count - 1] = .text(old + new)
            default:
                pending.append(input)
            }
            if draining == nil {
                draining = Task {
                    while !pending.isEmpty {
                        await send(pending.removeFirst())
                    }
                    draining = nil
                }
            }
        }

        private func send(_ input: Input) async {
            if state == .watching {
                takeBack()
            }
            // Typed before the first frame (after a take back): wait for it.
            if opening {
                await withCheckedContinuation { waiter = $0 }
            }
            guard state == .live, let stream else { return }
            switch input {
            case let .text(text):
                stream.input(text)
            case let .keys(keys):
                _ = try? await client.call("pane.send_keys", ["pane_id": paneID, "keys": keys]) as Done
            }
        }

        private func wake() {
            opening = false
            waiter?.resume()
            waiter = nil
        }
    }

    /// Any reply we do not read.
    private nonisolated struct Done: Decodable {}
#endif
