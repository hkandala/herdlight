import XCTest

/// Live terminals (phase 4), checked through herdr: `pane.read`, `pane.get` and a second
/// `control` stream from the helper. Session one's t1 is p1 | (p2 / p3), t2 holds p4.
extension HerdlightUITests {
    func testCardsAttachAtTheirSize() async throws {
        XCTAssertTrue(element("terminal.w1:p1").waitForExistence(timeout: connect))
        for pane in ["w1:p1", "w1:p2", "w1:p3"] {
            try await expectPTYSize(pane)
        }
        keepScreenshot("terminals")
    }

    func testKeysGoToTheClickedCard() async throws {
        let terminal = element("terminal.w1:p2")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await waitForPrompt("w1:p2")
        terminal.click()
        // The shell prints 42; the command line has no 42, so a match is the output.
        app.typeText("echo hl-$((40+2))")
        app.typeKey(.return, modifierFlags: [])
        try await waitFor("w1:p2") { $0.contains("\nhl-42") }
        let other = try await read("w1:p1")
        XCTAssertFalse(other.contains("hl-42"))

        // Up arrow (a herdr key) brings the command back.
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        try await waitFor("w1:p2") { $0.components(separatedBy: "\nhl-42").count == 3 }
    }

    func testResizingACardResizesThePTY() async throws {
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await expectPTYSize("w1:p1")
        let before = terminal.value as? String
        // Hiding the sidebar widens the cards. Not the window: CI's window already fills the screen
        // (Zoom changes nothing there), and a drag on its corner does not resize it under XCUITest.
        element("titlebar.sidebar").click()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""),
                                                object: terminal)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 3), .completed)
        try await expectPTYSize("w1:p1")
    }

    func testScrollingMovesTheViewport() async throws {
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await waitForPrompt("w1:p1")
        try await Self.call(one, "pane.send_text", ["pane_id": "w1:p1", "text": "seq 1 500\r"])
        try await waitFor("w1:p1") { $0.contains("\n500\n") }
        // The wheel goes where the pointer is. Which sign is up depends on the Mac's natural
        // scrolling setting (up for negative here, down on CI), so try both; at the bottom, down
        // does nothing.
        terminal.hover()
        var delta = -100.0
        try await poll("the viewport to move", times: 10) { () async throws -> Int? in
            terminal.scroll(byDeltaX: 0, deltaY: delta)
            delta = -delta
            try await Task.sleep(for: .milliseconds(300))
            let pane = try await Self.call(one, "pane.get", ["pane_id": "w1:p1"])["pane"] as? [String: Any]
            let offset = (pane?["scroll"] as? [String: Any])?["offset_from_bottom"] as? Int ?? 0
            return offset > 0 ? offset : nil
        }
        // Up and down do not page the strip.
        XCTAssertTrue(element("tab.w1:t1").isSelected)
        keepScreenshot("vertical scroll")
    }

    /// A sideways scroll over a terminal pages the strip, and the new tab's panes attach.
    func testSwipingOverACardPagesToTheNextTab() async throws {
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await waitForPrompt("w1:p1")
        keepScreenshot("before the swipe")
        // Which sign goes right follows the natural scrolling setting (see testScrollingMovesTheViewport); toward
        // the first tab nothing moves, so try both.
        let width = Double(terminal.frame.width)
        var delta = -width
        try await poll("the swipe to select the second tab", times: 6) { () async throws -> Bool? in
            terminal.hover()
            terminal.scroll(byDeltaX: delta, deltaY: 0)
            delta = -delta
            try await Task.sleep(for: .milliseconds(700))
            return element("tab.w1:t2").isSelected ? true : nil
        }
        keepScreenshot("after the swipe")
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "second", timeout: 2))
        try await expectPTYSize("w1:p4")
    }

    func testSwitchingTabsKeepsTheLastTabAttached() async throws {
        XCTAssertTrue(element("terminal.w1:p1").waitForExistence(timeout: connect))
        let old = try await terminalID("w1:p1"), new = try await terminalID("w1:p4")
        // The app controls p1 (its PTY has the card's size), so a second controller is refused. A
        // probe before the app attached would win, and the app would only watch.
        try await expectPTYSize("w1:p1")
        try await waitForControl(old) { $0.contains("already has an attached client") }
        let rows = try await viewportRows("w1:p1")

        element("tab.w1:t2").click()
        XCTAssertTrue(element("terminal.w1:p4").waitForExistence(timeout: 2))
        try await expectPTYSize("w1:p4")
        try await waitForControl(new) { $0.contains("already has an attached client") }
        // The last tab stays attached at its size, so coming back to it resizes nothing.
        try await waitForControl(old) { $0.contains("already has an attached client") }
        let away = try await viewportRows("w1:p1")
        XCTAssertEqual(away, rows)

        element("tab.w1:t1").click()
        XCTAssertTrue(element("terminal.w1:p1").waitForExistence(timeout: 2))
        try await waitForControl(old) { $0.contains("already has an attached client") }
        let back = try await viewportRows("w1:p1")
        XCTAssertEqual(back, rows)
    }

    func testEachTabKeepsItsKeyboardCard() async throws {
        let terminal = element("terminal.w1:p2")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await waitForPrompt("w1:p2")
        terminal.click()
        XCTAssertTrue(hasKeyboard(terminal))
        element("tab.w1:t2").click()
        XCTAssertTrue(hasKeyboard(element("terminal.w1:p4")))
        element("tab.w1:t1").click()
        // Back on t1, the keyboard is on p2 again, not on herdr's focused p1.
        XCTAssertTrue(hasKeyboard(terminal))
        app.typeText("echo hl-$((40+3))")
        app.typeKey(.return, modifierFlags: [])
        try await waitFor("w1:p2") { $0.contains("\nhl-43") }
        let other = try await read("w1:p1")
        XCTAssertFalse(other.contains("hl-43"))
    }

    // MARK: Helpers

    /// `stty size` in the pane prints the grid its card shows (the terminal's accessibility value).
    private func expectPTYSize(_ pane: String) async throws {
        let terminal = element("terminal.\(pane)")
        try await waitForPrompt(pane)
        try await poll("stty size in \(pane) to match its card", times: 30) { () async throws -> String? in
            guard terminal.exists, let grid = terminal.value as? String, !grid.isEmpty else { return nil }
            try await Self.call(one, "pane.send_text", ["pane_id": pane, "text": "clear; stty size\r"])
            try await Task.sleep(for: .milliseconds(200))
            return try await read(pane).split(separator: "\n").contains { $0 == grid } ? grid : nil
        }
    }

    private func waitForPrompt(_ pane: String) async throws {
        try await waitFor(pane) { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func waitFor(_ pane: String, _ done: (String) -> Bool) async throws {
        try await poll("pane \(pane) to show it") { () async throws -> String? in
            let text = try await read(pane)
            return done(text) ? text : nil
        }
    }

    private func read(_ pane: String) async throws -> String {
        let read = try await Self.call(one, "pane.read", ["pane_id": pane, "source": "visible"])["read"]
        return try XCTUnwrap((read as? [String: Any])?["text"] as? String)
    }

    private func viewportRows(_ pane: String) async throws -> Int {
        let pane = try await Self.call(one, "pane.get", ["pane_id": pane])["pane"] as? [String: Any]
        return try XCTUnwrap((pane?["scroll"] as? [String: Any])?["viewport_rows"] as? Int)
    }

    private func terminalID(_ pane: String) async throws -> String {
        let pane = try await Self.call(one, "pane.get", ["pane_id": pane])["pane"] as? [String: Any]
        return try XCTUnwrap(pane?["terminal_id"] as? String)
    }

    /// A `control` stream from the helper, released at once, until its output passes `done`.
    private func waitForControl(_ terminal: String, _ done: (String) -> Bool) async throws {
        try await poll("control of \(terminal)", times: 20) { () async throws -> String? in
            let text = try await String(decoding: Self.post("\(one)/control", Data(terminal.utf8)).data, as: UTF8.self)
            return done(text) ? text : nil
        }
    }

    /// `probe` every 100 ms until it gives a value; the test fails after `times` tries.
    @discardableResult
    private func poll<Value>(_ what: String, times: Int = 50,
                             _ probe: () async throws -> Value?) async throws -> Value
    {
        for _ in 0 ..< times {
            if let value = try await probe() {
                return value
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("waited for \(what)")
        throw CancellationError()
    }
}
