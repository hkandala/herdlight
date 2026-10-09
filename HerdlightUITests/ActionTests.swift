import XCTest

/// Actions (phase 4b): close, zoom, new tab, workspace and session, the palette. Session one's t1 is
/// p1 | (p2 / p3), t2 "second" holds p4; w2 is "beta".
extension HerdlightUITests {
    func testClosingAPaneAsksUnlessOnlyItsShellRuns() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, first) = try await newTab("close")
        let split = try await Self.call(one, "pane.split", ["target_pane_id": first, "direction": "right",
                                                            "cwd": "/tmp", "focus": false])
        let second = try XCTUnwrap((split["pane"] as? [String: Any])?["pane_id"] as? String)
        element("tab.\(tab)").click()
        try await waitForPrompt(second)

        // Something besides the shell runs: the app asks, and Cancel keeps the pane.
        try await Self.call(one, "pane.send_text", ["pane_id": second, "text": "sleep 100\r"])
        try await poll("sleep to run") { () async throws -> Bool? in
            let info = try await Self.call(one, "pane.process_info", ["pane_id": second])["process_info"]
            let processes = (info as? [String: Any])?["foreground_processes"] as? [[String: Any]]
            return processes?.contains { $0["name"] as? String == "sleep" } == true ? true : nil
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
            let info = try await Self.call(one, "pane.process_info", ["pane_id": second])["process_info"]
            let processes = (info as? [String: Any])?["foreground_processes"] as? [[String: Any]]
            return processes?.allSatisfy { $0["name"] as? String != "sleep" } == true ? true : nil
        }
        hoverHeader(second)
        element("pane.\(second).close").click()
        XCTAssertTrue(element("pane.\(second)").waitForNonExistence(timeout: 3))
        XCTAssertFalse(confirm.exists)
        XCTAssertTrue(element("pane.\(first)").exists)
    }

    func testClosingATabAsksFirst() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, pane) = try await newTab("doomed", closeAfter: false)
        try await Self.call(one, "pane.split", ["target_pane_id": pane, "direction": "right", "cwd": "/tmp",
                                                "focus": false])
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
        let tab = try await poll("a new tab in herdr") { () async throws -> String? in
            try await tabIDs().first { !before.contains($0) }
        }
        addTeardownBlock { [one] in _ = try? await Self.call(one, "tab.close", ["tab_id": tab]) }
        XCTAssertTrue(tab.hasPrefix("w1:"))
        XCTAssertTrue(element("tab.\(tab)").wait(for: \.isSelected, toEqual: true, timeout: 3))
        XCTAssertTrue(element("page.\(tab)").wait(for: \.isHittable, toEqual: true, timeout: 3))
    }

    func testNewWorkspaceAppearsSelected() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let before = try await tabIDs()
        element("sidebar.new-workspace").click()
        let tab = try await poll("a new workspace in herdr") { () async throws -> String? in
            try await tabIDs().first { !before.contains($0) }
        }
        let workspace = String(tab.prefix { $0 != ":" })
        addTeardownBlock { [one] in _ = try? await Self.call(one, "workspace.close", ["workspace_id": workspace]) }
        XCTAssertTrue(element("workspace.\(workspace)").waitForExistence(timeout: 3))
        // Only the selected workspace's pages are in the strip.
        XCTAssertTrue(element("page.\(tab)").waitForExistence(timeout: 3))
        XCTAssertFalse(element("page.w1:t1").exists)
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
        try await poll("the zoomed card's output") { () async throws -> Bool? in
            let read = try await Self.call(one, "pane.read", ["pane_id": "w1:p2", "source": "visible"])["read"]
            return ((read as? [String: Any])?["text"] as? String)?.contains("\nhl-zoom-42") == true ? true : nil
        }
        // The hidden cards keep their size.
        try await Self.call(one, "pane.send_text", ["pane_id": "w1:p3", "text": "clear; stty size\r"])
        try await poll("p3 to keep its size") { () async throws -> Bool? in
            let read = try await Self.call(one, "pane.read", ["pane_id": "w1:p3", "source": "visible"])["read"]
            let text = (read as? [String: Any])?["text"] as? String ?? ""
            return text.split(separator: "\n").contains { $0 == neighbor } ? true : nil
        }

        app.typeKey(.return, modifierFlags: [.command, .shift])
        XCTAssertTrue(element("pane.w1:p1").waitForExistence(timeout: 2))
        XCTAssertTrue(element("pane.w1:p3").exists)
        XCTAssertEqual(card.frame.width, before.width, accuracy: 2)
        try await expectPTYSize("w1:p2")
    }

    func testNewSessionFromTheFilterIsSelected() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_SESSION4"])
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        element("titlebar.session-picker").click()
        let filter = element("sessions.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
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
        element("titlebar.session-picker").click()
        XCTAssertTrue(element("session.\(one)").waitForExistence(timeout: 2))
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
        app.typeKey("k", modifierFlags: .command)
        let filter = element("palette.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
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

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))
    }

    func testPaletteJumpsToAnotherWorkspacesSecondTab() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let (tab, _) = try await newTab("faraway")
        app.typeKey("k", modifierFlags: .command)
        let filter = element("palette.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
        app.typeText("faraway")
        XCTAssertTrue(element("palette.tab.\(tab)").waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("tab.\(tab)").wait(for: \.isSelected, toEqual: true, timeout: 2))
        XCTAssertTrue(element("page.\(tab)").wait(for: \.isHittable, toEqual: true, timeout: 3))
    }

    // MARK: Helpers

    /// Shows a card's header buttons. Over the header, not the card's center: SwiftUI does not see the
    /// pointer jump straight into a terminal view, which takes the mouse moves.
    func hoverHeader(_ pane: String) {
        element("pane.\(pane)").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 17)).hover()
    }

    /// A new tab in w2 (closed after the test), shown in the sidebar: its id and its pane's. In another workspace
    /// than the selected one, so a click on it also crosses workspaces.
    private func newTab(_ label: String, closeAfter: Bool = true) async throws -> (tab: String, pane: String) {
        let created = try await Self.call(one, "tab.create", ["workspace_id": "w2", "label": label, "cwd": "/tmp",
                                                              "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        let pane = try XCTUnwrap((created["root_pane"] as? [String: Any])?["pane_id"] as? String)
        if closeAfter {
            addTeardownBlock { [one] in _ = try? await Self.call(one, "tab.close", ["tab_id": tab]) }
        }
        XCTAssertTrue(element("tab.\(tab)").waitForExistence(timeout: 2))
        return (tab, pane)
    }

    private func tabIDs() async throws -> [String] {
        let snapshot = try await Self.call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
        return (snapshot?["tabs"] as? [[String: Any]] ?? []).compactMap { $0["tab_id"] as? String }
    }
}
