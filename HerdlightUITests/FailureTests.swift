import XCTest

/// Failure paths (phase 6): a session that stops, a pane closed in herdr, session switches and quit. A takeover is
/// in TerminalTests.
/// Streams are counted through the helper (`pgrep` on the session's `terminal session` runs).
extension HerdlightUITests {
    func testStoppedSessionSaysSoAndComesBackWhenStartedAgain() async throws {
        let five = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_SESSION5"])
        let snapshot = try await Self.call(five, "session.snapshot", [:])["snapshot"] as? [String: Any]
        if (snapshot?["workspaces"] as? [Any] ?? []).isEmpty {
            try await Self.call(five, "workspace.create", ["label": "five", "cwd": "/tmp", "focus": false])
        }
        app.terminate()
        app.launchArguments = ["-session", five, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await poll("its stream") { () async throws -> Bool? in try await streams(five).count == 1 ? true : nil }

        try await Self.post("\(five)/stop", Data())
        // The "not running" page: its Start button.
        XCTAssertTrue(element("detail.start").waitForExistence(timeout: 10))
        XCTAssertFalse(terminal.exists)
        keepScreenshot("not running")
        try await poll("no stream") { () async throws -> Bool? in try await streams(five).isEmpty ? true : nil }

        // Started in a terminal, not by the app: the app finds it again within seconds, with one stream.
        try await Self.post("\(five)/start", Data())
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        try await poll("one stream again") { () async throws -> Bool? in
            try await streams(five).count == 1 ? true : nil
        }
    }

    func testPaneClosedInHerdrDropsItsCardAndStream() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, first) = try await newTab("gone")
        let second = try await split(first)
        element("tab.\(tab)").click()
        let doomed = try await terminalID(second)
        try await poll("its stream") { () async throws -> Bool? in
            try await streams(one).contains { $0.contains(doomed) } ? true : nil
        }

        try await Self.call(one, "pane.close", ["pane_id": second])
        XCTAssertTrue(element("pane.\(second)").waitForNonExistence(timeout: 3))
        try await poll("its stream to end") { () async throws -> Bool? in
            try await streams(one).contains { $0.contains(doomed) } ? nil : true
        }
        XCTAssertTrue(element("pane.\(first)").exists)
    }

    func testSwitchingSessionsAndQuittingLeaveNoStreams() async throws {
        let two = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_SESSION2"])
        XCTAssertTrue(element("terminal.w1:p1").waitForExistence(timeout: connect))
        XCTAssertTrue(element("tab.w1:t1").isSelected)
        // t1's three cards stream; the other session's one card once it shows.
        try await expectStreams(3, 0, two)
        for _ in 0 ..< 3 {
            pickSession(two)
            XCTAssertTrue(element("workspace.w2").waitForNonExistence(timeout: connect))
            try await expectStreams(0, 1, two)
            pickSession(one)
            XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
            try await expectStreams(3, 0, two)
        }

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        try await expectStreams(0, 0, two)
    }

    private func pickSession(_ name: String) {
        openSessions()
        element("session.\(name)").click()
    }

    private func expectStreams(_ inOne: Int, _ inTwo: Int, _ two: String) async throws {
        try await poll("\(inOne) streams on one, \(inTwo) on two") { () async throws -> Bool? in
            let counts = try await (streams(one).count, streams(two).count)
            return counts == (inOne, inTwo) ? true : nil
        }
    }

    /// The session's `terminal session` runs, any client's, as `pid argv` lines.
    private func streams(_ session: String) async throws -> [String] {
        let (data, status) = try await Self.post("\(session)/streams", Data())
        XCTAssertEqual(status, 200)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
