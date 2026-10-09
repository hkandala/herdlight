import XCTest

/// Runs against two throwaway herdr sessions from `make e2e`. The runner is sandboxed and cannot
/// reach herdr, so herdr calls go through the e2e helper on localhost (`scripts/e2e-helper.py`).
/// xcodebuild strips the TEST_RUNNER_ prefix from the names.
@MainActor
final class HerdlightUITests: XCTestCase {
    var one = ""
    private var two = ""
    let app = XCUIApplication()
    /// The app's first snapshot: login shell, herdr checks and a few herdr runs; slow on CI runners.
    let connect: TimeInterval = 30

    /// Session one: w1 "alpha" with t1 = p1 | (p2 / p3) at 0.6 and t2 "second"; w2 "beta".
    /// Session two: w1 "gamma".
    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        one = try XCTUnwrap(env["HL_SESSION"], "run through make e2e")
        two = try XCTUnwrap(env["HL_SESSION2"], "run through make e2e")
        // Once per session; the runner may restart between tests, so ask herdr, not a static. The check is on
        // the last step, so a setup cut short builds again (and fails loudly) instead of passing half-built.
        let snapshot = try await Self.call(two, "session.snapshot", [:])["snapshot"] as? [String: Any]
        let built = (snapshot?["workspaces"] as? [[String: Any]] ?? []).contains { $0["label"] as? String == "gamma" }
        if !built {
            try await Self.call(one, "workspace.create", ["label": "alpha", "cwd": "/tmp", "focus": false])
            try await Self.call(one, "pane.split", ["target_pane_id": "w1:p1", "direction": "right", "ratio": 0.6,
                                                    "cwd": "/tmp", "focus": false])
            try await Self.call(one, "pane.split", ["target_pane_id": "w1:p2", "direction": "down",
                                                    "cwd": "/tmp", "focus": false])
            try await Self.call(
                one,
                "tab.create",
                ["workspace_id": "w1", "label": "second", "cwd": "/tmp", "focus": false],
            )
            try await Self.call(one, "workspace.create", ["label": "beta", "cwd": "/tmp", "focus": false])
            try await Self.call(two, "workspace.create", ["label": "gamma", "cwd": "/tmp", "focus": false])
        }
        // No window state from earlier runs.
        app.launchArguments = ["-session", one, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    func testShowsWorkspacesTabsAndSplits() {
        XCTAssertTrue(element("workspace.w1").waitForExistence(timeout: connect))
        XCTAssertTrue(element("workspace.w2").exists)
        XCTAssertTrue(element("tab.w1:t1").exists)
        XCTAssertTrue(element("tab.w1:t2").exists)
        // At launch no text field has the keyboard; a terminal has it.
        XCTAssertEqual(app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).count, 0)
        XCTAssertNotEqual(element("sidebar.filter").elementType, .textField)

        // p1 | (p2 / p3): p1 on the left with about 60 % of the width, p2 above p3.
        let first = element("pane.w1:p1").frame, second = element("pane.w1:p2").frame
        let third = element("pane.w1:p3").frame
        XCTAssertLessThan(first.maxX, second.minX)
        XCTAssertEqual(first.width / (first.width + second.width), 0.6, accuracy: 0.03)
        XCTAssertLessThan(second.maxY, third.minY)
        XCTAssertLessThan(first.maxX, third.minX)
        keepScreenshot("split")

        element("tab.w1:t2").click()
        XCTAssertTrue(element("pane.w1:p4").wait(for: \.isHittable, toEqual: true, timeout: 2))
        XCTAssertEqual(app.windows.firstMatch.title, "second")

        element("workspace.w2").click()
        XCTAssertTrue(element("page.w2:t1").waitForExistence(timeout: 2))
        XCTAssertFalse(element("page.w1:t1").exists)
        XCTAssertTrue(element("pane.w2:p1").exists)
        keepScreenshot("second workspace")
    }

    /// A row of another workspace shows its own tab, not the workspace's first one.
    func testTabRowOfAnotherWorkspaceShowsThatTab() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        element("workspace.w2").click()
        XCTAssertTrue(element("page.w2:t1").waitForExistence(timeout: 2))
        element("tab.w1:t2").click()
        XCTAssertTrue(element("pane.w1:p4").wait(for: \.isHittable, toEqual: true, timeout: 2))
        XCTAssertTrue(element("tab.w1:t2").isSelected)
        XCTAssertFalse(element("pane.w1:p1").isHittable)

        // Back to the first tab through another workspace: the title-bar marker is on it, and the second tab's
        // capsule scrolls there.
        element("workspace.w2").click()
        XCTAssertTrue(element("pane.w2:p1").wait(for: \.isHittable, toEqual: true, timeout: 2))
        element("tab.w1:t1").click()
        XCTAssertTrue(element("pane.w1:p1").wait(for: \.isHittable, toEqual: true, timeout: 2))
        element("titlebar.sidebar").click()
        let first = element("tab.w1:t1"), second = element("tab.w1:t2")
        XCTAssertTrue(first.wait(for: \.isSelected, toEqual: true, timeout: 2))
        // Once the strip's scroll to t1 has settled (on CI it was still between the pages).
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            first.value as? String == "in view" && second.value as? String == ""
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 2), .completed)
        second.click()
        XCTAssertTrue(element("pane.w1:p4").wait(for: \.isHittable, toEqual: true, timeout: 2))
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'in view'"), object: second)
        XCTAssertEqual(XCTWaiter().wait(for: [marked], timeout: 2), .completed)
    }

    func testSwitchesSessions() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        openSessions()
        let other = element("session.\(two)")
        XCTAssertTrue(element("session.\(one)").exists)
        other.click()

        let gamma = app.buttons.matching(NSPredicate(format: "identifier == 'workspace.w1' AND label == 'gamma'"))
        XCTAssertTrue(gamma.firstMatch.waitForExistence(timeout: connect))
        XCTAssertFalse(element("workspace.w2").exists)
    }

    func testSessionFilterNarrowsTheList() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        // The field has the keyboard as soon as the list opens.
        openSessions()
        XCTAssertTrue(element("session.\(one)").exists)
        app.typeText(two)
        XCTAssertTrue(element("session.\(one)").waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("session.\(two)").exists)
        keepScreenshot("session filter")
    }

    func testSidebarFilterNarrowsTheTabs() {
        XCTAssertTrue(element("tab.w1:t1").waitForExistence(timeout: connect))
        let filter = element("sidebar.filter")
        filter.click()
        XCTAssertTrue(hasKeyboard(filter))
        filter.typeText("seco")
        XCTAssertTrue(element("tab.w1:t1").waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("tab.w1:t2").exists)
        XCTAssertFalse(element("workspace.w2").exists)
        keepScreenshot("sidebar filter")
    }

    func testHidingTheSidebarShowsTitleBarTabs() {
        let window = app.windows.firstMatch
        let tab = element("tab.w1:t2")
        XCTAssertTrue(tab.waitForExistence(timeout: connect))
        XCTAssertGreaterThan(tab.frame.minY, window.frame.minY + 40)

        element("titlebar.sidebar").click()
        XCTAssertTrue(element("sidebar.filter").waitForNonExistence(timeout: 2))
        XCTAssertTrue(tab.waitForExistence(timeout: 2))
        XCTAssertLessThan(tab.frame.maxY, window.frame.minY + 40)
        tab.click()
        XCTAssertTrue(window.wait(for: \.title, toEqual: "second", timeout: 2))
        keepScreenshot("title-bar tabs")
    }

    func testSplitButtonAddsAPane() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let (tab, pane) = try await newTab("split")
        element("tab.\(tab)").click()
        XCTAssertTrue(element("page.\(tab)").wait(for: \.isHittable, toEqual: true, timeout: 3))
        hoverHeader(pane)
        element("pane.\(pane).split-right").click()

        // The app draws a second card to the right of the first, and herdr has two panes in the tab.
        let cards = element("page.\(tab)").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", #"pane\.[^.]+"#))
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 2))
        XCTAssertLessThan(cards.element(boundBy: 0).frame.maxX, cards.element(boundBy: 1).frame.minX)
        let snapshot = try await Self.call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
        XCTAssertEqual((snapshot?["panes"] as? [[String: Any]])?.count { $0["tab_id"] as? String == tab }, 2)
        keepScreenshot("split")
    }

    func testSessionListClosesOnEscapeAndOutsideClick() {
        XCTAssertTrue(element("pane.w1:p1").waitForExistence(timeout: connect))
        let filter = openSessions()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))

        openSessions()
        element("pane.w1:p1").click()
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))
    }

    func testSelectsAnotherTabWhenTheSelectedOneCloses() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let (tab, _) = try await newTab("doomed", in: "w1", closeAfter: false)
        let row = element("tab.\(tab)")
        row.click()
        XCTAssertTrue(row.wait(for: \.isSelected, toEqual: true, timeout: 2))

        try await Self.call(one, "tab.close", ["tab_id": tab])
        XCTAssertTrue(row.waitForNonExistence(timeout: 2))
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.w1:' AND selected == true"))
        XCTAssertTrue(selected.firstMatch.waitForExistence(timeout: 2))
        let page = element("page.\(selected.firstMatch.identifier.dropFirst("tab.".count))")
        XCTAssertTrue(page.wait(for: \.isHittable, toEqual: true, timeout: 2))
    }
}

/// Helpers shared by the test files.
extension HerdlightUITests {
    /// `stty size` in the pane prints the grid its card shows (the terminal's accessibility value).
    func expectPTYSize(_ pane: String) async throws {
        let terminal = element("terminal.\(pane)")
        try await waitForPrompt(pane)
        try await poll("stty size in \(pane) to match its card", times: 30) { () async throws -> String? in
            guard terminal.exists, let grid = terminal.value as? String, !grid.isEmpty else { return nil }
            try await Self.call(one, "pane.send_text", ["pane_id": pane, "text": "clear; stty size\r"])
            try await Task.sleep(for: .milliseconds(200))
            return try await read(pane).split(separator: "\n").contains { $0 == grid } ? grid : nil
        }
    }

    func waitForPrompt(_ pane: String) async throws {
        try await waitFor(pane) { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Polls the pane's text until `done` passes. Escaping: the compiler rejects it otherwise across files.
    func waitFor(_ pane: String, _ done: @escaping (String) -> Bool) async throws {
        try await poll("pane \(pane) to show it") { () async throws -> String? in
            let text = try await read(pane)
            return done(text) ? text : nil
        }
    }

    func read(_ pane: String) async throws -> String {
        let read = try await Self.call(one, "pane.read", ["pane_id": pane, "source": "visible"])["read"]
        return try XCTUnwrap((read as? [String: Any])?["text"] as? String)
    }

    func terminalID(_ pane: String) async throws -> String {
        let pane = try await Self.call(one, "pane.get", ["pane_id": pane])["pane"] as? [String: Any]
        return try XCTUnwrap(pane?["terminal_id"] as? String)
    }

    /// `probe` every 100 ms until it gives a value; the test fails after `times` tries.
    @discardableResult
    func poll<Value>(_ what: String, times: Int = 50,
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

    /// Shows a card's header buttons. Over the header, not the card's center: SwiftUI does not see the
    /// pointer jump straight into a terminal view, which takes the mouse moves.
    func hoverHeader(_ pane: String) {
        element("pane.\(pane)").coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 17)).hover()
    }

    /// A new tab (closed after the test unless told not to), shown in the sidebar: its id and its pane's. By
    /// default in w2, another workspace than the selected one, so a click on it also crosses workspaces.
    func newTab(_ label: String, in workspace: String = "w2",
                closeAfter: Bool = true) async throws -> (tab: String, pane: String)
    {
        let created = try await Self.call(one, "tab.create", ["workspace_id": workspace, "label": label,
                                                              "cwd": "/tmp", "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        let pane = try XCTUnwrap((created["root_pane"] as? [String: Any])?["pane_id"] as? String)
        if closeAfter {
            addTeardownBlock { [one] in _ = try? await Self.call(one, "tab.close", ["tab_id": tab]) }
        }
        XCTAssertTrue(element("tab.\(tab)").waitForExistence(timeout: 2))
        return (tab, pane)
    }

    /// Splits the pane to the right in herdr; the new pane's id.
    @discardableResult
    func split(_ pane: String) async throws -> String {
        let split = try await Self.call(one, "pane.split", ["target_pane_id": pane, "direction": "right",
                                                            "cwd": "/tmp", "focus": false])
        return try XCTUnwrap((split["pane"] as? [String: Any])?["pane_id"] as? String)
    }

    /// The names of the pane's foreground processes.
    func foreground(_ pane: String) async throws -> [String] {
        let info = try await Self.call(one, "pane.process_info", ["pane_id": pane])["process_info"]
        let processes = (info as? [String: Any])?["foreground_processes"] as? [[String: Any]] ?? []
        return processes.compactMap { $0["name"] as? String }
    }

    func tabIDs() async throws -> [String] {
        let snapshot = try await Self.call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
        return (snapshot?["tabs"] as? [[String: Any]] ?? []).compactMap { $0["tab_id"] as? String }
    }

    /// The tab herdr has now and did not have `before`.
    func newTabID(after before: [String]) async throws -> String {
        try await poll("a new tab in herdr") { () async throws -> String? in
            try await tabIDs().first { !before.contains($0) }
        }
    }

    /// Types a command where the keyboard is and waits for its output in the pane.
    func typeAndRead(_ pane: String) async throws {
        app.typeText("echo hl-keys-$((6*7))")
        app.typeKey(.return, modifierFlags: [])
        try await waitFor(pane) { $0.contains("\nhl-keys-42") }
    }

    /// The session's `terminal session` runs, any client's, as `pid argv` lines.
    func streams(_ session: String) async throws -> [String] {
        let (data, status) = try await Self.post("\(session)/streams", Data())
        XCTAssertEqual(status, 200)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Opens the session list; its filter has the keyboard.
    @discardableResult
    func openSessions() -> XCUIElement {
        element("titlebar.session-picker").click()
        let filter = element("sessions.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
        return filter
    }

    /// ⌘K; the palette's filter has the keyboard.
    @discardableResult
    func openPalette() -> XCUIElement {
        app.typeKey("k", modifierFlags: .command)
        let filter = element("palette.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
        return filter
    }

    /// For people reviewing a run: the window, in the result bundle.
    func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for the element to take the keyboard; focus lands a moment after it appears.
    func hasKeyboard(_ element: XCUIElement) -> Bool {
        let focus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element,
        )
        return XCTWaiter().wait(for: [focus], timeout: 2) == .completed
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// One herdr API call on a throwaway session, through the helper.
    @discardableResult
    nonisolated static func call(_ session: String, _ method: String,
                                 _ params: [String: Any]) async throws -> [String: Any]
    {
        let body = try JSONSerialization.data(withJSONObject: ["id": "1", "method": method, "params": params])
        let (data, status) = try await post(session, body + Data("\n".utf8))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(status, 200, text)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], text)
        return try XCTUnwrap(reply["result"] as? [String: Any], "\(method): \(text)")
    }

    /// One POST to the e2e helper: `<session>` for an API call, `<session>/<action>` for the others (see the helper).
    @discardableResult
    nonisolated static func post(_ path: String, _ body: Data) async throws -> (data: Data, status: Int) {
        let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_HELPER"])
        var request = try URLRequest(url: XCTUnwrap(URL(string: "\(helper)/\(path)")))
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
