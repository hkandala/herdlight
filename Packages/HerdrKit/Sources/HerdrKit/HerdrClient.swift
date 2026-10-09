import Foundation

/// The oldest herdr release this kit works with.
public let herdrVersion = "0.9.3"

public enum HerdrError: Error, Equatable, Sendable {
    /// No herdr binary on the machine.
    case notFound
    /// herdr is there but too old or lacks the API bridge.
    case unsupported(String)
    /// herdr did not answer within 10 s.
    case timeout
    /// herdr answered with an error.
    case herdr(code: String, message: String)
    /// The command failed or printed something we cannot read.
    case failed(String)
}

extension HerdrError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound: "herdr is not installed on this Mac"
        case let .unsupported(message), let .failed(message): message
        case .timeout: "herdr did not answer"
        case let .herdr(code, message): "\(message) (\(code))"
        }
    }
}

/// What `HerdrClient.updates()` delivers.
public enum Update: Sendable {
    case snapshot(Snapshot)
    case error(HerdrError)
}

/// Talks to one herdr session: requests over `remote-api-bridge`, one events stream, paced snapshots.
public actor HerdrClient {
    public nonisolated let session: String
    nonisolated let herdr: String
    nonisolated let exec: any Exec
    nonisolated let timeout: Duration
    private let debounce = Duration.milliseconds(100)
    private let maxWait = Duration.milliseconds(500)

    private var out: AsyncStream<Update>.Continuation?
    /// No good snapshot since the start or the last failure.
    private var stale = true
    private var reading = false
    private var readAgain = false
    private var firstEvent: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var events: Task<Void, Never>?
    /// Agent panes of the open events stream; nil when no stream is open.
    private var subscribed: [String]?

    /// `herdr` is the path from `locate(exec:)`; `timeout` bounds each request.
    public init(herdr: String, session: String, exec: any Exec, timeout: Duration = .seconds(10)) {
        self.herdr = herdr
        self.session = session
        self.exec = exec
        self.timeout = timeout
    }

    /// Finds the herdr binary and checks that it has the API bridge.
    public static func locate(exec: any Exec) async throws -> String {
        let find = #"command -v herdr || for p in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr "#
            + #"/usr/local/bin/herdr; do [ -x "$p" ] && echo "$p" && break; done"#
        let path = try await output(exec, ["sh", "-c", find])
        guard !path.isEmpty else { throw HerdrError.notFound }
        guard try await output(exec, [path, "--session", "default", "remote-api-bridge", "--check"])
            == "herdr-api-bridge-v1"
        else {
            throw HerdrError.unsupported("\(path) has no remote-api-bridge; herdr \(herdrVersion) or newer needed")
        }
        return path
    }

    // MARK: Requests

    /// Sends one request through a new `remote-api-bridge` run and decodes its `result`.
    public nonisolated func call<Result: Decodable & Sendable>(
        _ method: String,
        _ params: [String: any Sendable] = [:],
    ) async throws -> Result {
        let request: [String: Any] = ["id": "1", "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw HerdrError.failed("\(method): params are not JSON")
        }
        let line = try String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let channel = try await exec.run(bridge)
        channel.write(line)
        let reply = try await withTimeout(timeout, onTimeout: channel.terminate) {
            await channel.lines.first { _ in true }
        }
        channel.closeInput()
        guard let reply else {
            let (status, stderr) = await channel.exit()
            throw HerdrError.failed("herdr exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let decoded = try decode(Reply<Result>.self, reply)
        if let error = decoded.error {
            throw HerdrError.herdr(code: error.code, message: error.message)
        }
        guard let result = decoded.result else { throw HerdrError.failed("\(method): no result") }
        return result
    }

    /// Checks that the server answers and is new enough.
    public nonisolated func ping() async throws {
        let pong: Pong = try await call("ping")
        // Leading digits per part, so 0.9.4-rc1 counts as 0.9.4.
        let numbers = { (version: String) in
            version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let have = numbers(pong.version), need = numbers(herdrVersion)
        if have.lexicographicallyPrecedes(need) {
            throw HerdrError.unsupported("herdr \(pong.version) is too old; \(herdrVersion) or newer needed")
        }
    }

    /// Every session herdr knows on this machine, running or not.
    public nonisolated func sessions() async throws -> [Session] {
        let list = try await Self.output(exec, [herdr, "--session", session, "session", "list", "--json"])
        return try decode(SessionList.self, list).sessions
    }

    /// The program the pane runs besides its shell; nil when only the shell runs, so a close loses nothing
    /// (design D41).
    public nonisolated func program(_ paneID: String) async throws -> String? {
        try await (call("pane.process_info", ["pane_id": paneID]) as ProcessInfoResult).processInfo.program
    }

    /// One `session.snapshot`, with every tab's split tree.
    public nonisolated func snapshot() async throws -> Snapshot {
        var snapshot = try await (call("session.snapshot") as SnapshotResult).snapshot
        for layout in snapshot.layouts {
            if let tree = SplitNode(layout) {
                snapshot.trees[layout.tabID] = tree
            } else {
                let export: ExportResult = try await call("layout.export", ["tab_id": layout.tabID])
                snapshot.trees[layout.tabID] = export.layout.root
            }
        }
        return snapshot
    }

    // MARK: Updates

    /// Snapshots as herdr changes, paced, until the stream is dropped. Call once per client.
    public func updates() -> AsyncStream<Update> {
        precondition(out == nil, "updates() is called once per client")
        let (stream, out) = AsyncStream<Update>.makeStream()
        self.out = out
        out.onTermination = { _ in Task { await self.stop() } }
        keepalive = Task { await self.keepAlive() }
        return stream
    }

    /// Reads a snapshot now, without the debounce (after the app's own write).
    public func refresh() {
        timer?.cancel()
        timer = nil
        firstEvent = nil
        read()
    }

    private func stop() {
        out = nil
        for task in [timer, keepalive, events] {
            task?.cancel()
        }
    }

    /// An event arrived: read after 100 ms of quiet, but at most 500 ms after the first event.
    private func changed() {
        if reading {
            readAgain = true
            return
        }
        let now = ContinuousClock.now
        let first = firstEvent ?? now
        firstEvent = first
        timer?.cancel()
        timer = Task { [self, deadline = min(now + debounce, first + maxWait)] in
            try? await Task.sleep(until: deadline)
            // Also covers a timer cancelled while it waited for the actor.
            if !Task.isCancelled {
                refresh()
            }
        }
    }

    private func read() {
        guard out != nil else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        Task { [self] in
            do {
                let snapshot = try await snapshot()
                stale = false
                out?.yield(.snapshot(snapshot))
                let agentPanes = snapshot.agents.map(\.paneID).sorted()
                if out != nil, agentPanes != subscribed {
                    subscribe(agentPanes)
                }
            } catch {
                stale = true
                out?.yield(.error(error as? HerdrError ?? .failed("\(error)")))
            }
            reading = false
            if readAgain {
                readAgain = false
                read()
            }
        }
    }

    /// (Re)opens the one events stream. Every line on it means "read the snapshot again".
    private func subscribe(_ agentPanes: [String]) {
        events?.cancel()
        subscribed = agentPanes
        let types = [
            "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
            "workspace.moved", "workspace.reordered", "workspace.closed",
            "tab.created", "tab.closed", "tab.renamed", "tab.moved",
            "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.exited", "pane.agent_detected",
            "layout.updated",
        ]
        // No *.focused: the app ignores herdr's focus. Each agent entry makes herdr poll that pane
        // every 100 ms, so plain shells are left out.
        let subscriptions = types.map { ["type": $0] }
            + agentPanes.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        let params = ["subscriptions": subscriptions]
        // Only strings: serializing cannot fail.
        let data = (try? JSONSerialization.data(withJSONObject: ["id": "events", "method": "events.subscribe",
                                                                 "params": params])) ?? Data()
        let request = String(decoding: data, as: UTF8.self)
        events = Task { [self] in
            do {
                let channel = try await exec.run(bridge)
                channel.write(request)
                for await line in channel.lines {
                    let message = try? JSONDecoder().decode(EventLine.self, from: Data(line.utf8))
                    // events_lost, pane_not_found: start over.
                    if message?.error != nil {
                        break
                    }
                    // The `result` line is subscription_started: catch up on what came before it.
                    if message?.result != nil {
                        refresh()
                    } else {
                        changed()
                    }
                }
                channel.terminate()
            } catch {}
            // The stream ended on its own: wait a little, then a fresh snapshot opens it again.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            subscribed = nil
            refresh()
        }
    }

    /// Pings now and every 30 s. The first good ping starts the reads, so a herdr that is too old
    /// never delivers a snapshot; a stale session reads again once it answers.
    private func keepAlive() async {
        repeat {
            do {
                try await ping()
                if stale {
                    refresh()
                }
            } catch let HerdrError.unsupported(message) {
                out?.yield(.error(.unsupported(message)))
                out?.finish()
                return
            } catch {
                stale = true
                out?.yield(.error(error as? HerdrError ?? .failed("\(error)")))
            }
        } while await (try? Task.sleep(for: .seconds(30))) != nil
    }

    private nonisolated var bridge: [String] {
        [herdr, "--session", session, "remote-api-bridge"]
    }

    /// A command's whole stdout, trimmed.
    static func output(_ exec: any Exec, _ argv: [String]) async throws -> String {
        let channel = try await exec.run(argv)
        channel.closeInput()
        return try await withTimeout(.seconds(10), onTimeout: channel.terminate) {
            await channel.lines.reduce("") { $0 + $1 + "\n" }
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    } catch {
        throw HerdrError.failed("unreadable reply from herdr: \(error)")
    }
}

struct Reply<Result: Decodable>: Decodable {
    let result: Result?
    let error: ReplyError?
}

struct ReplyError: Decodable {
    let code: String
    let message: String
}

private struct EventLine: Decodable {
    struct Present: Decodable {}
    let result: Present?
    let error: ReplyError?
}

private struct Pong: Decodable {
    let version: String
}

private struct SessionList: Decodable {
    let sessions: [Session]
}

struct SnapshotResult: Decodable {
    let snapshot: Snapshot
}

struct ExportResult: Decodable {
    struct Layout: Decodable { let root: SplitNode }
    let layout: Layout
}

/// Runs body; past the deadline, calls onTimeout (which must make body end) and throws `.timeout`.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    onTimeout: @escaping @Sendable () -> Void,
    _ body: @escaping @Sendable () async throws -> T,
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: body)
        group.addTask {
            try await Task.sleep(for: duration)
            throw HerdrError.timeout
        }
        defer { group.cancelAll() }
        do {
            guard let value = try await group.next() else { throw HerdrError.timeout }
            return value
        } catch {
            onTimeout()
            throw error
        }
    }
}
