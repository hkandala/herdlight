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
        // Once per session; the runner may restart between tests, so ask herdr, not a static.
        let snapshot = try await call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
        if (snapshot?["workspaces"] as? [Any])?.isEmpty ?? true {
            try await call(one, "workspace.create", ["label": "alpha", "cwd": "/tmp", "focus": false])
            try await call(one, "pane.split", ["target_pane_id": "w1:p1", "direction": "right", "ratio": 0.6,
                                               "cwd": "/tmp", "focus": false])
            try await call(one, "pane.split", ["target_pane_id": "w1:p2", "direction": "down",
                                               "cwd": "/tmp", "focus": false])
            try await call(one, "tab.create", ["workspace_id": "w1", "label": "second", "cwd": "/tmp", "focus": false])
            try await call(one, "workspace.create", ["label": "beta", "cwd": "/tmp", "focus": false])
            try await call(two, "workspace.create", ["label": "gamma", "cwd": "/tmp", "focus": false])
        }
        app.launchArguments = ["-session", one]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testShowsWorkspacesTabsAndSplits() {
        XCTAssertTrue(element("workspace.w1").waitForExistence(timeout: connect))
        XCTAssertTrue(element("workspace.w2").exists)
        XCTAssertTrue(element("tab.w1:t1").exists)
        XCTAssertTrue(element("tab.w1:t2").exists)

        // p1 | (p2 / p3): p1 on the left with 60 % of the width, p2 above p3.
        let first = element("pane.w1:p1").frame, second = element("pane.w1:p2").frame
        let third = element("pane.w1:p3").frame
        XCTAssertLessThan(first.maxX, second.minX)
        XCTAssertEqual(first.width / (first.width + second.width), 0.6, accuracy: 0.02)
        XCTAssertEqual(second.minX, third.minX, accuracy: 1)
        XCTAssertEqual(second.width, third.width, accuracy: 1)
        XCTAssertLessThan(second.maxY, third.minY)
        XCTAssertEqual(second.height, third.height, accuracy: 2)
        XCTAssertEqual(first.height, second.height + third.height + 8, accuracy: 2)
        XCTAssertEqual(second.minX - first.maxX, 8, accuracy: 1)
        keepScreenshot("split")

        element("tab.w1:t2").click()
        let page = element("page.w1:t2")
        XCTAssertTrue(page.waitForExistence(timeout: 2))
        XCTAssertTrue(wait { app.windows.firstMatch.frame.contains(element("pane.w1:p4").frame) })
        XCTAssertEqual(app.windows.firstMatch.title, "second")

        element("workspace.w2").click()
        XCTAssertTrue(element("page.w2:t1").waitForExistence(timeout: 2))
        XCTAssertFalse(element("page.w1:t1").exists)
        XCTAssertTrue(element("pane.w2:p1").exists)
        keepScreenshot("second workspace")
    }

    func testFollowsTabsMadeAndClosedInHerdr() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: connect))
        let created = try await call(one, "tab.create", ["workspace_id": "w1", "label": "live", "cwd": "/tmp",
                                                         "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        XCTAssertTrue(element("tab.\(tab)").waitForExistence(timeout: 2))

        try await call(one, "tab.close", ["tab_id": tab])
        XCTAssertTrue(element("tab.\(tab)").waitForNonExistence(timeout: 2))
    }

    func testSwitchesSessions() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        element("titlebar.session-picker").click()
        let other = element("session.\(two)")
        XCTAssertTrue(other.waitForExistence(timeout: 2))
        XCTAssertTrue(element("session.\(one)").exists)
        other.click()

        // Reading `label` of a missing element fails the test, so check that it exists first.
        let row = element("workspace.w1")
        XCTAssertTrue(wait(timeout: connect) { row.exists && row.label == "gamma" })
        XCTAssertFalse(element("workspace.w2").exists)
    }

    func testSessionFilterNarrowsTheList() {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        element("titlebar.session-picker").click()
        let filter = element("sessions.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        XCTAssertTrue(element("session.\(one)").exists)
        filter.typeText(String(two.suffix(2)))
        XCTAssertTrue(element("session.\(one)").waitForNonExistence(timeout: 2))
        XCTAssertTrue(element("session.\(two)").exists)
        keepScreenshot("session filter")
    }

    func testSidebarFilterNarrowsTheTabs() {
        XCTAssertTrue(element("tab.w1:t1").waitForExistence(timeout: connect))
        let filter = element("sidebar.filter")
        filter.click()
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
        XCTAssertTrue(wait { tab.exists && tab.frame.maxY < window.frame.minY + 40 })
        tab.click()
        XCTAssertTrue(wait { window.title == "second" })
        keepScreenshot("title-bar tabs")
    }

    func testSplitButtonAddsAPane() async throws {
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: connect))
        let created = try await call(one, "tab.create", ["workspace_id": "w2", "label": "split", "cwd": "/tmp",
                                                         "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        let pane = try XCTUnwrap((created["root_pane"] as? [String: Any])?["pane_id"] as? String)
        let row = element("tab.\(tab)")
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.click()
        let card = element("pane.\(pane)")
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.hover()
        element("pane.\(pane).split-right").click()

        // herdr has the new pane, and the app draws it to the right of the first.
        var panes: [String] = []
        for _ in 0 ..< 20 where panes.count < 2 {
            let snapshot = try await call(one, "session.snapshot", [:])["snapshot"] as? [String: Any]
            panes = (snapshot?["panes"] as? [[String: Any]] ?? []).filter { $0["tab_id"] as? String == tab }
                .compactMap { $0["pane_id"] as? String }
            try await Task.sleep(for: .milliseconds(100))
        }
        let new = try XCTUnwrap(panes.first { $0 != pane })
        XCTAssertTrue(element("pane.\(new)").waitForExistence(timeout: 2))
        XCTAssertLessThan(card.frame.maxX, element("pane.\(new)").frame.minX)
        keepScreenshot("split")
        try await call(one, "tab.close", ["tab_id": tab])
    }

    /// For people reviewing a run: the window, in the result bundle.
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func wait(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date() + timeout
        while !condition() {
            if Date() > deadline {
                return false
            }
            RunLoop.current.run(until: Date() + 0.1)
        }
        return true
    }

    /// One herdr API call on a throwaway session, through the helper.
    @discardableResult
    private func call(_ session: String, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
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
