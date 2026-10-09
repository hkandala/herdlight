import XCTest

/// Actions (phase 4b): close, zoom, new tab, workspace and session, the palette. Session one's t1 is
/// p1 | (p2 / p3), t2 "second" holds p4; w2 is "beta".
extension HerdlightUITests {
    func testClosingAPaneAsksUnlessOnlyItsShellRuns() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, first) = try await newTab("close")
        let second = try await split(first)
        element("tab.\(tab)").click()
        try await waitForPrompt(second)

        // Something besides the shell runs: the app asks, and Cancel keeps the pane.
        try await Self.call(one, "pane.send_text", ["pane_id": second, "text": "sleep 100\r"])
        try await poll("sleep to run") { () async throws -> Bool? in
            try await foreground(second).contains("sleep") ? true : nil
        }
        hoverHeader(second)
        element("pane.\(second).close").click()
        let confirm = app.sheets.buttons["Close Pane"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        keepScreenshot("close pane dialog")
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("pane.\(second)").exists)

        // Only the shell: the card goes at once.
        try await Self.call(one, "pane.send_keys", ["pane_id": second, "keys": ["ctrl+c"]])
        try await poll("the shell to be back") { () async throws -> Bool? in
            try await foreground(second).contains("sleep") ? nil : true
        }
        hoverHeader(second)
        element("pane.\(second).close").click()
        XCTAssertTrue(element("pane.\(second)").waitForNonExistence(timeout: 3))
        XCTAssertFalse(confirm.exists)
        XCTAssertTrue(element("pane.\(first)").exists)
    }

    func testClosingTheKeyboardCardHandsKeysToItsNeighbor() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, left) = try await newTab("handoff")
        let right = try await split(left)
        element("tab.\(tab)").click()
        try await waitForPrompt(left)
        try await waitForPrompt(right)
        element("terminal.\(left)").click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("pane.\(left)").waitForNonExistence(timeout: 3))
        try await typeAndRead(right)
    }

    func testClosingATabAsksFirst() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, pane) = try await newTab("doomed", closeAfter: false)
        try await split(pane)
        let row = element("tab.\(tab)")
        row.hover()
        element("tab.\(tab).close").click()
        let confirm = app.sheets.buttons["Close Tab"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        XCTAssertTrue(app.sheets.staticTexts
            .matching(NSPredicate(format: "value CONTAINS '2 panes' OR label CONTAINS '2 panes'")).firstMatch
            .exists)
        keepScreenshot("close tab dialog")
        confirm.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        let snapshot = try await Self.call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
        XCTAssertFalse((snapshot?["tabs"] as? [[String: Any]] ?? []).contains { $0["tab_id"] as? String == tab })
    }

    func testPlusMakesATabAndSelectsIt() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let before = try await tabIDs()
        element("titlebar.new-tab").click()
        let tab = try await newTabID(after: before)
        addTeardownBlock { [one] in _ = try? await Self.call(one, "tab.close", ["tab_id": tab]) }
        XCTAssertTrue(tab.hasPrefix("w1:"))
        XCTAssertTrue(element("tab.\(tab)").wait(for: \.isSelected, toEqual: true, timeout: 3))
        XCTAssertTrue(element("page.\(tab)").wait(for: \.isHittable, toEqual: true, timeout: 3))
    }

    func testCommandTOpensInTheKeyboardCardsDirectoryAndCommandWClosesIt() async throws {
        XCTAssertTrue(element("terminal.w1:p2").waitForExistence(timeout: connect))
        try await waitForPrompt("w1:p2")
        try await Self.call(one, "pane.send_text", ["pane_id": "w1:p2", "text": "cd /usr\r"])
        element("terminal.w1:p2").click()

        // ⌘T: the new tab opens in /usr and has the keyboard; ⌘W there closes it (only its shell runs).
        var pane = try await commandT()
        try await waitForPrompt(pane)
        try await typeAndRead(pane)
        let tab = try await tabOf(pane)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element("tab.\(tab)").waitForNonExistence(timeout: 3))

        // After a zoom and a restore by double-click, ⌘T still knows the card.
        element("tab.w1:t1").click()
        let header = element("pane.w1:p2").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 17))
        header.doubleClick()
        XCTAssertTrue(element("pane.w1:p1").waitForNonExistence(timeout: 2))
        header.doubleClick()
        XCTAssertTrue(element("pane.w1:p1").waitForExistence(timeout: 2))
        pane = try await commandT()
        let created = try await tabOf(pane)
        addTeardownBlock { [one] in _ = try? await Self.call(one, "tab.close", ["tab_id": created]) }
    }

    /// ⌘T, then the new tab's pane once herdr has it; its cwd must be /usr.
    private func commandT() async throws -> String {
        let before = try await tabIDs()
        app.typeKey("t", modifierFlags: .command)
        let tab = try await newTabID(after: before)
        XCTAssertTrue(element("tab.\(tab)").wait(for: \.isSelected, toEqual: true, timeout: 3))
        let snapshot = try await Self.call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
        let pane = try XCTUnwrap((snapshot?["panes"] as? [[String: Any]])?.first { $0["tab_id"] as? String == tab })
        XCTAssertEqual(pane["cwd"] as? String, "/usr")
        return try XCTUnwrap(pane["pane_id"] as? String)
    }

    private func tabOf(_ pane: String) async throws -> String {
        let info = try await Self.call(one, "pane.get", ["pane_id": pane])["pane"] as? [String: Any]
        return try XCTUnwrap(info?["tab_id"] as? String)
    }

    func testNewWorkspaceAppearsSelected() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        // From the second tab, after the sidebar was hidden and shown: a new workspace once came up blank then.
        element("tab.w1:t2").click()
        element("titlebar.sidebar").click()
        XCTAssertTrue(element("sidebar.filter").waitForNonExistence(timeout: 2))
        element("titlebar.sidebar").click()
        XCTAssertTrue(element("sidebar.new-workspace").waitForExistence(timeout: 2))
        let before = try await tabIDs()
        element("sidebar.new-workspace").click()
        let tab = try await newTabID(after: before)
        let workspace = String(tab.prefix { $0 != ":" })
        addTeardownBlock { [one] in _ = try? await Self.call(one, "workspace.close", ["workspace_id": workspace]) }
        XCTAssertTrue(element("workspace.\(workspace)").waitForExistence(timeout: 3))
        // Only the selected workspace's pages are in the strip.
        XCTAssertTrue(element("page.\(tab)").waitForExistence(timeout: 3))
        XCTAssertFalse(element("page.w1:t1").exists)
        // Its card shows and has the keyboard.
        let pane = "\(workspace):p1"
        XCTAssertTrue(element("pane.\(pane)").wait(for: \.isHittable, toEqual: true, timeout: 3))
        try await waitForPrompt(pane)
        try await typeAndRead(pane)
    }

    func testZoomFillsThePageAndRestores() async throws {
        let card = element("pane.w1:p2")
        XCTAssertTrue(element("terminal.w1:p2").waitForExistence(timeout: connect))
        try await expectPTYSize("w1:p2")
        let page = element("page.w1:t1").frame, before = card.frame
        let neighbor = try XCTUnwrap(element("terminal.w1:p3").value as? String)
        hoverHeader("w1:p2")
        element("pane.w1:p2.zoom").click()
        XCTAssertTrue(element("pane.w1:p1").waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("pane.w1:p3").waitForNonExistence(timeout: 2))
        XCTAssertEqual(card.frame.width, page.width, accuracy: 2)
        try await expectPTYSize("w1:p2")
        keepScreenshot("zoom")
        // Clicks and keys reach the zoomed terminal, not a hidden one under it.
        element("terminal.w1:p2").click()
        app.typeText("echo hl-zoom-$((6*7))")
        app.typeKey(.return, modifierFlags: [])
        try await waitFor("w1:p2") { $0.contains("\nhl-zoom-42") }
        // The hidden cards keep their size.
        try await Self.call(one, "pane.send_text", ["pane_id": "w1:p3", "text": "clear; stty size\r"])
        try await waitFor("w1:p3") { $0.split(separator: "\n").contains { $0 == neighbor } }

        app.typeKey(.return, modifierFlags: [.command, .shift])
        XCTAssertTrue(element("pane.w1:p1").waitForExistence(timeout: 2))
        XCTAssertTrue(element("pane.w1:p3").exists)
        XCTAssertEqual(card.frame.width, before.width, accuracy: 2)
        try await expectPTYSize("w1:p2")
    }

    func testNewSessionFromTheFilterIsSelected() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_SESSION4"])
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        openSessions()
        app.typeText(name)
        XCTAssertTrue(element("sessions.new").label.contains(name))
        app.typeKey(.return, modifierFlags: [])

        // The app starts the server and makes its first workspace; session one's w2 goes.
        XCTAssertTrue(element("workspace.w2").waitForNonExistence(timeout: connect))
        XCTAssertTrue(element("workspace.w1").waitForExistence(timeout: connect))
        element("titlebar.session-picker").click()
        XCTAssertTrue(element("session.\(name)").wait(for: \.isSelected, toEqual: true, timeout: 3))
    }

    func testShowStoppedRevealsStoppedSessionsAndPickingOneStartsIt() throws {
        let stopped = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_SESSION3"])
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        openSessions()
        XCTAssertTrue(element("session.\(one)").exists)
        XCTAssertFalse(element("session.\(stopped)").exists)
        element("sessions.show-stopped").click()
        XCTAssertTrue(element("session.\(stopped)").waitForExistence(timeout: 2))
        keepScreenshot("show stopped")
        element("sessions.show-stopped").click()
        XCTAssertTrue(element("session.\(stopped)").waitForNonExistence(timeout: 2))

        // Picking a stopped session starts it (a launchd job) and gives it a workspace.
        element("sessions.show-stopped").click()
        element("session.\(stopped)").click()
        XCTAssertTrue(element("workspace.w2").waitForNonExistence(timeout: connect))
        XCTAssertTrue(element("workspace.w1").waitForExistence(timeout: connect))
    }

    func testPaletteFiltersAndJumps() {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let filter = openPalette()
        app.typeText("seco")
        XCTAssertTrue(element("palette.tab.w1:t1").waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("palette.tab.w1:t2").exists)
        keepScreenshot("palette")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("tab.w1:t2").wait(for: \.isSelected, toEqual: true, timeout: 2))

        // Arrows move: "beta" lists its tab, then the workspace.
        element("titlebar.palette").click()
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
        app.typeText("beta")
        XCTAssertTrue(element("palette.workspace.w2").waitForExistence(timeout: 2))
        app.typeKey(.downArrow, modifierFlags: [])
        keepScreenshot("palette moved")
        XCTAssertTrue(element("palette.workspace.w2").wait(for: \.isSelected, toEqual: true, timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("page.w2:t1").waitForExistence(timeout: 2))

        openPalette()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))
    }

    func testPaletteEnterTakesTheMovedRowAndKeysFollow() async throws {
        XCTAssertTrue(element("terminal.w1:p1").waitForExistence(timeout: connect))
        openPalette()
        // Rows start with w1's tabs: ↓ moves from t1 to t2.
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element("palette.tab.w1:t2").wait(for: \.isSelected, toEqual: true, timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("tab.w1:t2").wait(for: \.isSelected, toEqual: true, timeout: 2))
        try await waitForPrompt("w1:p4")
        try await typeAndRead("w1:p4")
    }

    func testPaletteJumpsToAnotherWorkspacesSecondTab() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let (tab, _) = try await newTab("faraway")
        openPalette()
        app.typeText("faraway")
        XCTAssertTrue(element("palette.tab.\(tab)").waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("tab.\(tab)").wait(for: \.isSelected, toEqual: true, timeout: 2))
        XCTAssertTrue(element("page.\(tab)").wait(for: \.isHittable, toEqual: true, timeout: 3))
    }
}
