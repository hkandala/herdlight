import Foundation
@testable import HerdrKit
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

@Test(.enabled(if: shell("which", "herdr") == 0, "herdr is not on PATH"))
func `talks to a throwaway herdr session`() async throws {
    let session = "hl-e2e-\(UUID().uuidString.prefix(6).lowercased())"
    try #require(shell(script, "up", session) == 0)
    defer { shell(script, "down", session) }

    let exec = await ProcessExec()
    let client = try await HerdrClient(herdr: HerdrClient.locate(exec: exec), session: session, exec: exec)
    try await client.ping()
    #expect(try await client.sessions().contains { $0.name == session && $0.running })
    let _: Ignored = try await client.call("workspace.create", ["cwd": "/tmp", "focus": false])

    let updates = await client.updates()
    let snapshot = try await withTimeout(.seconds(10), onTimeout: {}, { () -> Snapshot? in
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
    let tab = try #require(snapshot?.tabs.last)
    #expect(tab.workspaceID == "w1")
    let pane = try #require(snapshot?.panes.first { $0.tabID == tab.id })
    #expect(snapshot?.trees[tab.id] == SplitNode.leaf(paneID: pane.id))
}
