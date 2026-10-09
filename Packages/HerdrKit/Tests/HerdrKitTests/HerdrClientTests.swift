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

/// Starts updates and waits for the opening reads (one before and one after subscribing).
private func started(_ client: HerdrClient, _ exec: FakeExec) async -> AsyncStream<Update> {
    let updates = await client.updates()
    // At least two: timing on a loaded machine can add a read; the tests count from the reset below.
    #expect(await eventually { exec[\.subscribes].count == 1 && exec[\.reads] >= 2 && exec[\.inFlight] == 0 })
    // Start-up reads have settled once none came for 150 ms; a late one would count as the test's.
    var reads = -1
    while reads != exec[\.reads] {
        reads = exec[\.reads]
        try? await Task.sleep(for: .milliseconds(150))
    }
    exec.state.withLock {
        $0.reads = 0
        $0.readTimes = []
    }
    return updates
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
    let candidate = client(FakeExec { _ in #"{"id":"1","result":{"type":"pong","version":"0.9.4-rc1"}}"# })
    try await candidate.ping()
}

// MARK: Pacing

@Test func `a burst of events is debounced into one read`() async throws {
    let exec = FakeExec()
    let client = client(exec)
    let updates = await started(client, exec)
    let sent = ContinuousClock.now
    for _ in 0 ..< 3 {
        exec.event()
    }
    #expect(await eventually { exec[\.reads] == 1 })
    try? await Task.sleep(for: .milliseconds(300))
    #expect(exec[\.reads] == 1)
    #expect(try #require(exec[\.readTimes].last) - sent >= .milliseconds(100))
    withExtendedLifetime(updates) {}
}

@Test func `a steady flow of events still reads within the max wait`() async throws {
    let exec = FakeExec()
    let client = client(exec)
    let updates = await started(client, exec)
    let first = ContinuousClock.now
    for _ in 0 ..< 50 { // 1.5 s of events, 30 ms apart: the 100 ms debounce alone would never fire
        exec.event()
        try? await Task.sleep(for: .milliseconds(30))
    }
    // 500 ms max wait + slack for a loaded machine, still before the flow ends at 1.5 s.
    #expect(try #require(exec[\.readTimes].first) - first < .milliseconds(1400))
    withExtendedLifetime(updates) {}
}

@Test func `refresh reads at once, one at a time, with one trailing read`() async throws {
    let exec = FakeExec(readDelay: .milliseconds(300))
    let client = client(exec)
    let updates = await started(client, exec)
    let asked = ContinuousClock.now
    await client.refresh()
    #expect(await eventually { exec[\.inFlight] == 1 })
    #expect(try #require(exec[\.readTimes].first) - asked < .milliseconds(100)) // inside the debounce
    for _ in 0 ..< 5 {
        exec.event()
    }
    await client.refresh()
    #expect(await eventually { exec[\.reads] == 2 && exec[\.inFlight] == 0 })
    try? await Task.sleep(for: .milliseconds(400))
    #expect(exec[\.reads] == 2)
    #expect(exec[\.maxInFlight] == 1)
    withExtendedLifetime(updates) {}
}

@Test func `events stream reopens on agent changes, errors and exit`() async {
    let exec = FakeExec()
    let client = client(exec)
    let updates = await started(client, exec)
    #expect(!exec[\.subscribes][0].contains("agent_status_changed"))

    exec.state.withLock { $0.agents = ["w1:p1"] }
    exec.event()
    #expect(await eventually { exec[\.subscribes].count == 2 })
    #expect(exec[\.subscribes][1].contains(#""pane_id":"w1:p1""#))

    exec.event(#"{"id":"events","error":{"code":"events_lost","message":"lagged"}}"#)
    #expect(await eventually { exec[\.subscribes].count == 3 })

    exec.state.withLock { $0.events }?.finish()
    #expect(await eventually { exec[\.subscribes].count == 4 })
    withExtendedLifetime(updates) {}
}

@Test func `updates deliver snapshots and read errors`() async {
    var updates = await client(FakeExec()).updates().makeAsyncIterator()
    guard case .snapshot = await updates.next() else {
        Issue.record("expected a snapshot")
        return
    }
    let broken = client(FakeExec { _ in "not json" })
    var errors = await broken.updates().makeAsyncIterator()
    guard case .error(.failed) = await errors.next() else {
        Issue.record("expected an error")
        return
    }
}

@Test func `a herdr that is too old gets one error and no snapshot`() async {
    let exec = FakeExec { line in
        line.contains("ping")
            ? #"{"id":"1","result":{"type":"pong","version":"0.9.2"}}"#
            : #"{"id":"1","result":{"snapshot":{"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[]}}}"#
    }
    var updates: [Update] = []
    for await update in await client(exec).updates() {
        updates.append(update)
    }
    guard updates.count == 1, case .error(.unsupported) = updates[0] else {
        Issue.record("expected only .unsupported, got \(updates)")
        return
    }
}
