import Foundation

/// One `herdr terminal session control|observe` run: herdr's rendering of a pane comes out as
/// frames, commands go in as NDJSON. Only `control` takes commands; `observe` only watches.
public struct TerminalStream: Sendable {
    public enum Event: Sendable, Equatable {
        case frame(Frame)
        /// The last event: the stream is over.
        case closed(Closed)
    }

    public struct Frame: Sendable, Equatable {
        public let seq: Int
        /// The real PTY size on a `control` stream.
        public let width: Int
        public let height: Int
        /// A full repaint: the first frame and the first after each resize.
        public let full: Bool
        /// ANSI bytes, herdr's own rendering of the visible screen (no input modes).
        public let bytes: Data
    }

    /// Why a stream ended, from herdr's reason text (design: how a stream ends).
    public enum Closed: Sendable, Equatable {
        /// Another client controls the pane.
        case held
        /// Another client took the pane with `--takeover`.
        case takenOver
        /// The terminal is not found or has exited.
        case gone
        /// We released it.
        case detached
        /// herdr is replacing itself; open again after a moment.
        case liveUpdate
        /// Anything else, with herdr's text: a failed handshake, a stopped server.
        case failed(String)

        init(reason: String) {
            self = if reason.contains("already has an attached client") {
                .held
            } else if reason.contains("taken over") {
                .takenOver
            } else if reason.contains("not found") || reason.contains("exited") {
                .gone
            } else if reason.contains("detached") {
                .detached
            } else if reason.contains("live update") {
                .liveUpdate
            } else {
                .failed(reason)
            }
        }
    }

    public enum MouseAction: String, Sendable { case down, up, drag, move } // swiftlint:disable:this identifier_name
    public enum MouseButton: String, Sendable { case left, middle, right }

    /// Frames until one `.closed`, then the end. Dropping the iteration kills the run.
    public let events: AsyncStream<Event>
    let channel: Channel

    init(_ channel: Channel) {
        self.channel = channel
        events = AsyncStream { continuation in
            let reader = Task {
                for await line in channel.lines {
                    switch Self.event(line) {
                    case let .closed(reason)?:
                        continuation.yield(.closed(reason))
                        continuation.finish()
                        return
                    case let event?:
                        continuation.yield(event)
                    case nil:
                        break
                    }
                }
                // No `terminal.closed`: the CLI failed (exit 1, reason on stderr) or was killed.
                let (status, stderr) = await channel.exit()
                let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.yield(.closed(.failed(text.isEmpty ? "herdr exited \(status)" : text)))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                channel.terminate()
            }
        }
    }

    /// One stdout line as an event; nil for lines we do not know.
    static func event(_ line: String) -> Event? {
        struct Line: Decodable {
            let type: String
            let seq: Int?, width: Int?, height: Int?, full: Bool?
            let bytes: String?, reason: String?
        }
        guard let line = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return nil }
        switch line.type {
        case "terminal.frame":
            guard let width = line.width, let height = line.height,
                  let bytes = line.bytes.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            return .frame(Frame(seq: line.seq ?? 0, width: width, height: height, full: line.full ?? false,
                                bytes: bytes))
        case "terminal.closed":
            return .closed(Closed(reason: line.reason ?? ""))
        default:
            return nil
        }
    }

    // MARK: Commands (control only)

    /// Bytes for the PTY, unchanged. A whole bracketed paste (`ESC[200~…ESC[201~`) is re-framed by
    /// herdr for the app's own paste mode.
    public func input(_ text: String) {
        send(["type": "terminal.input", "text": text])
    }

    public func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        send(["type": "terminal.resize", "cols": cols, "rows": rows,
              "cell_width_px": cellWidth, "cell_height_px": cellHeight])
    }

    /// A wheel at a cell, up when `lines` is negative: herdr sends it to a mouse app or moves the
    /// pane's viewport.
    public func scroll(lines: Int, column: Int, row: Int, modifiers: Int) {
        send(["type": "terminal.scroll", "direction": lines < 0 ? "up" : "down", "lines": abs(lines),
              "column": column, "row": row, "modifiers": modifiers])
    }

    /// 0-based cells; modifiers are crossterm bits (1 shift, 2 ctrl, 4 alt). herdr encodes the event
    /// for the app's mouse mode and drops it when the app has none.
    public func mouse(_ action: MouseAction, _ button: MouseButton, column: Int, row: Int, modifiers: Int) {
        send(["type": "terminal.mouse", "action": action.rawValue, "button": button.rawValue,
              "column": column, "row": row, "modifiers": modifiers])
    }

    /// Lets go of the pane; herdr answers `detached` and the run ends.
    public func release() {
        send(["type": "terminal.release"])
        channel.closeInput()
    }

    private func send(_ command: [String: any Sendable]) {
        channel.write(Self.line(command))
    }

    /// Sorted keys, so tests can compare lines.
    static func line(_ command: [String: any Sendable]) -> String {
        // Only strings and numbers: serializing cannot fail.
        let data = (try? JSONSerialization.data(withJSONObject: command, options: .sortedKeys)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public extension HerdrClient {
    /// Opens a pane's terminal by its `terminal_id`, so the stream survives the pane moving.
    /// `--session` wins over `HERDR_SOCKET_PATH` and `HERDR_SESSION` (phase 2 findings).
    nonisolated func terminal(
        _ terminalID: String,
        cols: Int,
        rows: Int,
        observe: Bool = false,
        takeover: Bool = false,
    ) async throws -> TerminalStream {
        var argv = [herdr, "--session", session, "terminal", "session", observe ? "observe" : "control",
                    terminalID, "--cols", "\(cols)", "--rows", "\(rows)"]
        if takeover, !observe {
            argv.append("--takeover")
        }
        return try await TerminalStream(exec.run(argv))
    }
}
