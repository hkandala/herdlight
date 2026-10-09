import XCTest

/// Runs against two throwaway herdr sessions from `make e2e`. The runner is sandboxed and cannot
/// reach herdr, so herdr calls go through the e2e helper on localhost (`scripts/e2e-helper.py`).
/// xcodebuild strips the TEST_RUNNER_ prefix from the names.
@MainActor
final class HerdlightUITests: XCTestCase {
    private var one = ""
    private var two = ""
    private let app = XCUIApplication()
    /// The app's first snapshot: login shell, herdr checks and a few herdr runs; slow on CI runners.
    private let connect: TimeInterval = 30

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
        app.launchArguments = ["-session", one]
        app.launch()
    }

    func testShowsWorkspacesTabsAndSplits() {
        XCTAssertTrue(element("workspace.w1").waitForExistence(timeout: connect))
        XCTAssertTrue(element("workspace.w2").exists)
        XCTAssertTrue(element("tab.w1:t1").exists)
        XCTAssertTrue(element("tab.w1:t2").exists)
        // At launch no text field has the keyboard (phase 4 gives it to the terminal).
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

    func testFollowsTabsMadeAndClosedInHerdr() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let created = try await Self.call(one, "tab.create", ["workspace_id": "w1", "label": "live", "cwd": "/tmp",
                                                              "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        XCTAssertTrue(element("tab.\(tab)").waitForExistence(timeout: 2))

        try await Self.call(one, "tab.close", ["tab_id": tab])
        XCTAssertTrue(element("tab.\(tab)").waitForNonExistence(timeout: 2))
    }

    func testSwitchesSessions() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        element("titlebar.session-picker").click()
        let other = element("session.\(two)")
        XCTAssertTrue(other.waitForExistence(timeout: 2))
        XCTAssertTrue(element("session.\(one)").exists)
        other.click()

        let gamma = app.buttons.matching(NSPredicate(format: "identifier == 'workspace.w1' AND label == 'gamma'"))
        XCTAssertTrue(gamma.firstMatch.waitForExistence(timeout: connect))
        XCTAssertFalse(element("workspace.w2").exists)
    }

    func testSessionFilterNarrowsTheList() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        element("titlebar.session-picker").click()
        let filter = element("sessions.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(element("session.\(one)").exists)
        // The field has the keyboard as soon as the list opens.
        XCTAssertTrue(hasKeyboard(filter))
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
        let created = try await Self.call(one, "tab.create", ["workspace_id": "w2", "label": "split", "cwd": "/tmp",
                                                              "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        addTeardownBlock { [one] in _ = try? await Self.call(one, "tab.close", ["tab_id": tab]) }
        let pane = try XCTUnwrap((created["root_pane"] as? [String: Any])?["pane_id"] as? String)
        let row = element("tab.\(tab)")
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.click()
        let card = element("pane.\(pane)")
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.hover()
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
        let picker = element("titlebar.session-picker"), filter = element("sessions.filter")
        picker.click()
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(hasKeyboard(filter))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))

        picker.click()
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        element("pane.w1:p1").click()
        XCTAssertTrue(filter.waitForNonExistence(timeout: 2))
    }

    func testSelectsAnotherTabWhenTheSelectedOneCloses() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let created = try await Self.call(one, "tab.create", ["workspace_id": "w1", "label": "doomed", "cwd": "/tmp",
                                                              "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        let row = element("tab.\(tab)")
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.click()
        XCTAssertTrue(row.wait(for: \.isSelected, toEqual: true, timeout: 2))

        try await Self.call(one, "tab.close", ["tab_id": tab])
        XCTAssertTrue(row.waitForNonExistence(timeout: 2))
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.w1:' AND selected == true"))
        XCTAssertTrue(selected.firstMatch.waitForExistence(timeout: 2))
        let page = element("page.\(selected.firstMatch.identifier.dropFirst("tab.".count))")
        XCTAssertTrue(page.wait(for: \.isHittable, toEqual: true, timeout: 2))
    }

    /// For people reviewing a run: the window, in the result bundle.
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for the element to take the keyboard; focus lands a moment after it appears.
    private func hasKeyboard(_ element: XCUIElement) -> Bool {
        let focus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element,
        )
        return XCTWaiter().wait(for: [focus], timeout: 2) == .completed
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// One herdr API call on a throwaway session, through the helper.
    @discardableResult
    private nonisolated static func call(_ session: String, _ method: String,
                                         _ params: [String: Any]) async throws -> [String: Any]
    {
        let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_HELPER"])
        var request = try URLRequest(url: XCTUnwrap(URL(string: "\(helper)/\(session)")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": "1", "method": method, "params": params])
            + Data("\n".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, text)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], text)
        return try XCTUnwrap(reply["result"] as? [String: Any], "\(method): \(text)")
    }
}
