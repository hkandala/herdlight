import XCTest

/// Live terminals (phase 4), checked through herdr: `pane.read`, `pane.get` and a second
/// `control` stream from the helper. Session one's t1 is p1 | (p2 / p3), t2 holds p4.
extension HerdlightUITests {
    func testCardsAttachAtTheirSize() async throws {
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await expectPTYSize("w1:p1", terminal)
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

    func testResizingTheWindowResizesThePTY() async throws {
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await expectPTYSize("w1:p1", terminal)
        let before = terminal.value as? String
        // Window > Zoom fills the screen (a drag on the corner does not resize the window under
        // XCUITest); a second Zoom restores it.
        let zoom = { @MainActor [app] in
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuItems["Zoom"].click()
        }
        zoom()
        addTeardownBlock(zoom)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""),
                                                object: terminal)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 3), .completed)
        try await expectPTYSize("w1:p1", terminal)
    }

    func testScrollingMovesTheViewport() async throws {
        let terminal = element("terminal.w1:p1")
        XCTAssertTrue(terminal.waitForExistence(timeout: connect))
        try await waitForPrompt("w1:p1")
        try await Self.call(one, "pane.send_text", ["pane_id": "w1:p1", "text": "seq 1 500\r"])
        try await waitFor("w1:p1") { $0.contains("\n500\n") }
        // Negative is up, toward older lines.
        terminal.scroll(byDeltaX: 0, deltaY: -100)
        var offset = 0
        for _ in 0 ..< 20 where offset == 0 {
            try await Task.sleep(for: .milliseconds(100))
            let pane = try await Self.call(one, "pane.get", ["pane_id": "w1:p1"])["pane"] as? [String: Any]
            offset = (pane?["scroll"] as? [String: Any])?["offset_from_bottom"] as? Int ?? 0
        }
        XCTAssertGreaterThan(offset, 0)
    }

    func testSwitchingTabsReleasesTheOldPanes() async throws {
        XCTAssertTrue(element("terminal.w1:p1").waitForExistence(timeout: connect))
        let old = try await terminalID("w1:p1"), new = try await terminalID("w1:p4")
        // The app controls p1, so a second controller is refused.
        try await waitForControl(old) { $0.contains("already has an attached client") }

        element("tab.w1:t2").click()
        XCTAssertTrue(element("terminal.w1:p4").waitForExistence(timeout: 2))
        try await waitForControl(old) { $0.contains("terminal.frame") }
        try await waitForControl(new) { $0.contains("already has an attached client") }
    }

    // MARK: Helpers

    /// `stty size` in the pane prints the grid the card shows (its accessibility value).
    private func expectPTYSize(_ pane: String, _ terminal: XCUIElement) async throws {
        try await waitForPrompt(pane)
        var size: String?
        for _ in 0 ..< 30 {
            let grid = try XCTUnwrap(terminal.value as? String)
            try await Self.call(one, "pane.send_text", ["pane_id": pane, "text": "clear; stty size\r"])
            try await Task.sleep(for: .milliseconds(300))
            size = try await read(pane).split(separator: "\n").map(String.init).first { $0 == grid }
            if size != nil {
                break
            }
        }
        XCTAssertNotNil(size, "stty size never matched the card's grid \(terminal.value ?? "nil")")
    }

    private func waitForPrompt(_ pane: String) async throws {
        try await waitFor(pane) { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func waitFor(_ pane: String, _ done: (String) -> Bool) async throws {
        var text = ""
        for _ in 0 ..< 50 {
            text = try await read(pane)
            if done(text) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("pane \(pane) never showed it:\n\(text)")
    }

    private func read(_ pane: String) async throws -> String {
        let read = try await Self.call(one, "pane.read", ["pane_id": pane, "source": "visible"])["read"]
        return try XCTUnwrap((read as? [String: Any])?["text"] as? String)
    }

    private func terminalID(_ pane: String) async throws -> String {
        let pane = try await Self.call(one, "pane.get", ["pane_id": pane])["pane"] as? [String: Any]
        return try XCTUnwrap(pane?["terminal_id"] as? String)
    }

    /// A `control` stream from the helper, released at once, until its output passes `done`.
    private func waitForControl(_ terminal: String, _ done: (String) -> Bool) async throws {
        let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_HELPER"])
        var request = try URLRequest(url: XCTUnwrap(URL(string: "\(helper)/\(one)/control")))
        request.httpMethod = "POST"
        request.httpBody = Data(terminal.utf8)
        var text = ""
        for _ in 0 ..< 20 {
            text = try await String(decoding: URLSession.shared.data(for: request).0, as: UTF8.self)
            if done(text) {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("control of \(terminal) printed: \(text)")
    }
}
