import Foundation
@testable import HerdrKit
import Synchronization
import Testing

/// Answers bridge requests like herdr. `answer` handles plain calls (nil: never answer); without
/// it, `session.snapshot` answers after `readDelay` with `agents`, and `events.subscribe` streams
/// stay open for the test to push lines into.
final class FakeExec: Exec {
    struct State {
        var argv: [[String]] = []
        var written: [String] = []
        var reads = 0
        var readTimes: [ContinuousClock.Instant] = []
        var inFlight = 0
        var maxInFlight = 0
        var terminated = 0
        var agents: [String] = []
        var subscribes: [String] = []
        var events: AsyncStream<String>.Continuation?
    }

    let state = Mutex(State())
    let readDelay: Duration
    let answer: (@Sendable (String) -> String?)?

    init(readDelay: Duration = .zero, answer: (@Sendable (String) -> String?)? = nil) {
        self.readDelay = readDelay
        self.answer = answer
    }

    subscript<T: Sendable>(_ key: KeyPath<State, T> & Sendable) -> T {
        state.withLock { $0[keyPath: key] }
    }

    func run(_ argv: [String]) async throws -> Channel {
        state.withLock { $0.argv.append(argv) }
        let (lines, reply) = AsyncStream<String>.makeStream()
        return Channel(
            lines: lines,
            write: { self.handle($0, reply) },
            closeInput: {},
            terminate: {
                self.state.withLock { $0.terminated += 1 }
                reply.finish()
            },
            exit: { (1, "no server") },
        )
    }

    private func handle(_ line: String, _ reply: AsyncStream<String>.Continuation) {
        state.withLock { $0.written.append(line) }
        if let answer {
            if let text = answer(line) {
                reply.yield(text)
                reply.finish()
            }
        } else if line.contains("events.subscribe") {
            state.withLock {
                $0.subscribes.append(line)
                $0.events = reply
            }
            reply.yield(#"{"id":"events","result":{"type":"subscription_started"}}"#)
        } else if line.contains("session.snapshot") {
            Task {
                let agents = state.withLock {
                    $0.reads += 1
                    $0.readTimes.append(.now)
                    $0.inFlight += 1
                    $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
                    return $0.agents
                }
                try? await Task.sleep(for: readDelay)
                state.withLock { $0.inFlight -= 1 }
                let entries = agents.map { #"{"pane_id":"\#($0)","agent_status":"idle"}"# }
                reply.yield(#"{"id":"1","result":{"snapshot":{"workspaces":[],"tabs":[],"panes":[],"layouts":[],"#
                    + #""agents":[\#(entries.joined(separator: ","))]}}}"#)
                reply.finish()
            }
        } else if line.contains("ping") {
            reply.yield(#"{"id":"1","result":{"type":"pong","version":"0.9.3","protocol":22}}"#)
            reply.finish()
        }
    }

    /// Pushes one line on the open events stream.
    func event(_ line: String = #"{"event":"tab_created","data":{}}"#) {
        _ = state.withLock { $0.events }?.yield(line)
    }
}

/// Polls until the condition holds or the timeout passes.
func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func client(_ exec: FakeExec) -> HerdrClient {
    HerdrClient(herdr: "/bin/herdr", session: "s", exec: exec, timeout: .seconds(1))
}

// MARK: Requests

@Test func `call writes one request line and decodes the result`() async throws {
    struct Created: Decodable {
        let tab: [String: String]
    }
    let exec = FakeExec { _ in #"{"id":"1","result":{"type":"tab_created","tab":{"tab_id":"w1:t2"}}}"# }
    let created: Created = try await client(exec).call("tab.create", ["workspace_id": "w1", "focus": false])
    #expect(created.tab["tab_id"] == "w1:t2")
    #expect(exec[\.argv] == [["/bin/herdr", "--session", "s", "remote-api-bridge"]])
    let request = try #require(JSONSerialization.jsonObject(with: Data(exec[\.written][0].utf8)) as? [String: Any])
    #expect(request["method"] as? String == "tab.create")
    #expect(request["params"] as? [String: AnyHashable] == ["workspace_id": "w1", "focus": false])
}

@Test func `herdr errors, timeouts and old versions throw typed errors`() async throws {
    let failing = client(FakeExec { _ in #"{"id":"1","error":{"code":"pane_not_found","message":"pane x"}}"# })
    await #expect(throws: HerdrError.herdr(code: "pane_not_found", message: "pane x")) {
        try await failing.ping()
    }
    let silent = FakeExec { _ in nil }
    await #expect(throws: HerdrError.timeout) { try await client(silent).ping() }
    #expect(silent[\.terminated] == 1)
    let old = client(FakeExec { _ in #"{"id":"1","result":{"type":"pong","version":"0.9.2","protocol":21}}"# })
    await #expect(throws: HerdrError.unsupported("herdr 0.9.2 is too old; 0.9.3 or newer needed")) {
        try await old.ping()
    }
}
