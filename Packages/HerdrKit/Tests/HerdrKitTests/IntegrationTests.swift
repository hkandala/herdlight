import Foundation
@testable import HerdrKit
import Synchronization
import Testing

private let script = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "scripts/herdr-session.sh").path

@discardableResult
private func shell(_ argv: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = argv
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Any result we do not read.
private struct Ignored: Decodable {}

/// Counts `events.subscribe` requests, so a test can tell a read caused by an event from one after
/// the stream reopened.
private final class SubscribeCounter: Exec {
    let base: ProcessExec
    let subscribes = Mutex(0)

    init(_ base: ProcessExec) {
        self.base = base
    }

    func run(_ argv: [String]) async throws -> Channel {
        let channel = try await base.run(argv)
        return Channel(
            lines: channel.lines,
            write: { line in
                if line.contains("events.subscribe") {
                    self.subscribes.withLock { $0 += 1 }
                }
                channel.write(line)
            },
            closeInput: channel.closeInput,
            terminate: channel.terminate,
            exit: channel.exit,
        )
    }
}

@Test(.enabled(if: shell("which", "herdr") == 0, "herdr is not on PATH"))
func `talks to a throwaway herdr session`() async throws {
    let session = "hl-e2e-\(UUID().uuidString.prefix(6).lowercased())"
    try #require(shell(script, "up", session) == 0)
    defer { shell(script, "down", session) }

    let exec = await SubscribeCounter(ProcessExec())
    let client = try await HerdrClient(herdr: HerdrClient.locate(exec: exec), session: session, exec: exec)
    try await client.ping()
    #expect(try await client.sessions().contains { $0.name == session && $0.running })
    let _: Ignored = try await client.call("workspace.create", ["cwd": "/tmp", "focus": false])

    let updates = await client.updates()
    let found = try await withTimeout(.seconds(10), onTimeout: {}, { () -> Snapshot? in
        var reads = 0
        for await case let .snapshot(snapshot) in updates {
            reads += 1
            // The second read follows the open events stream, so the next one comes from an event.
            if reads == 2 {
                let _: Ignored = try await client.call(
                    "tab.create",
                    ["workspace_id": "w1", "cwd": "/tmp", "focus": false],
                )
            }
            if snapshot.tabs.count == 2 {
                return snapshot
            }
        }
        return nil
    })
    let snapshot = try #require(found)
    // Still the first events stream: the event caused the read, not a reopened stream. A reopen
    // reads before it subscribes again, so wait past its 1 s backoff before counting.
    try await Task.sleep(for: .milliseconds(1500))
    #expect(exec.subscribes.withLock { $0 } == 1)
    withExtendedLifetime(updates) {}
    let tab = try #require(snapshot.tabs.last)
    #expect(tab.workspaceID == "w1")
    let pane = try #require(snapshot.panes.first { $0.tabID == tab.id })
    #expect(snapshot.trees[tab.id] == SplitNode.leaf(paneID: pane.id))
}

@Test func `output of fast commands always ends`() async throws {
    let exec = await ProcessExec()
    try await withThrowingTaskGroup(of: [String].self) { group in
        for _ in 0 ..< 30 {
            group.addTask {
                let channel = try await exec.run(["sh", "-c", "echo hi"])
                channel.closeInput()
                return try await withTimeout(.seconds(5), onTimeout: channel.terminate) {
                    await channel.lines.reduce(into: []) { $0.append($1) }
                }
            }
        }
        for try await lines in group {
            #expect(lines == ["hi"])
        }
    }
}

@Test func `terminate stops the readers when a grandchild keeps the pipes open`() async throws {
    let exec = await ProcessExec()
    let channel = try await exec.run(["sh", "-c", "sleep 8 & echo hi"])
    #expect(await channel.lines.first { _ in true } == "hi")
    channel.terminate()
    // stderr is still open in `sleep`; without stopping its reader, this waits 8 s.
    _ = try await withTimeout(.seconds(5), onTimeout: {}, { await channel.exit() })
}

private struct Created: Decodable {
    struct Pane: Decodable {
        let pane_id: String // swiftlint:disable:this identifier_name
        let terminal_id: String // swiftlint:disable:this identifier_name
    }

    let root_pane: Pane // swiftlint:disable:this identifier_name
}

private struct Read: Decodable {
    struct Text: Decodable { let text: String }
    let read: Text
}

/// How a stream ends, past its frames.
private func closedReason(_ events: inout AsyncStream<TerminalStream.Event>.Iterator) async -> TerminalStream.Closed? {
    while let event = await events.next() {
        if case let .closed(reason) = event {
            return reason
        }
    }
    return nil
}

@Test(.enabled(if: shell("which", "herdr") == 0, "herdr is not on PATH"))
func `controls a throwaway terminal`() async throws {
    let session = "hl-e2e-\(UUID().uuidString.prefix(6).lowercased())"
    try #require(shell(script, "up", session) == 0)
    defer { shell(script, "down", session) }

    let exec = await ProcessExec()
    let client = try await HerdrClient(herdr: HerdrClient.locate(exec: exec), session: session, exec: exec)
    let pane = try await (client.call("workspace.create", ["cwd": "/tmp", "focus": false]) as Created).root_pane
    let terminal = pane.terminal_id

    try await withTimeout(.seconds(20), onTimeout: {}, {
        let control = try await client.terminal(terminal, cols: 60, rows: 12)
        var events = control.events.makeAsyncIterator()
        guard case let .frame(first)? = await events.next() else { throw HerdrError.failed("no first frame") }
        #expect(first.full && first.width == 60 && first.height == 12)

        control.input("echo hl-$((6*7)); stty size\r")
        var text = ""
        for _ in 0 ..< 50 where !text.contains("12 60") {
            try await Task.sleep(for: .milliseconds(100))
            text = try await (client.call("pane.read", ["pane_id": pane.pane_id, "source": "visible"]) as Read)
                .read.text
        }
        #expect(text.contains("hl-42"))
        #expect(text.contains("12 60"))

        control.resize(cols: 70, rows: 15, cellWidth: 8, cellHeight: 17)
        var resized: TerminalStream.Frame?
        while resized == nil, case let .frame(frame)? = await events.next() {
            resized = frame.full ? frame : nil
        }
        #expect(resized?.width == 70 && resized?.height == 15)

        // Held: a second controller is refused, a watcher is not.
        let second = try await client.terminal(terminal, cols: 60, rows: 12)
        #expect(await second.events.first { _ in true } == .closed(.held))
        let watcher = try await client.terminal(terminal, cols: 60, rows: 12, observe: true)
        guard case let .frame(watched)? = await watcher.events.first(where: { _ in true }) else {
            throw HerdrError.failed("no observe frame")
        }
        #expect(watched.full && watched.width == 60)

        // Taken over: a controller with --takeover wins, the first one hears it.
        let taker = try await client.terminal(terminal, cols: 60, rows: 12, takeover: true)
        #expect(await closedReason(&events) == .held)
        taker.release()
        var takerEvents = taker.events.makeAsyncIterator()
        #expect(await closedReason(&takerEvents) == .ended)
    })
}
