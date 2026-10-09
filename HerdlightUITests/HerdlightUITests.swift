import XCTest

/// Runs against two throwaway herdr sessions from `make e2e`. The runner is sandboxed and cannot
/// reach herdr, so herdr calls go through the e2e helper on localhost (`scripts/e2e-helper.py`).
/// xcodebuild strips the TEST_RUNNER_ prefix from the names.
@MainActor
final class HerdlightUITests: XCTestCase {
    private static var built = false
    private var one = ""
    private var two = ""
    private let app = XCUIApplication()

    /// Session one: w1 "alpha" with t1 = p1 | (p2 / p3) at 0.6 and t2 "second"; w2 "beta".
    /// Session two: w1 "gamma".
    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        one = try XCTUnwrap(env["HL_SESSION"], "run through make e2e")
        two = try XCTUnwrap(env["HL_SESSION2"], "run through make e2e")
        if !Self.built {
            Self.built = true
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
        XCTAssertTrue(element("workspace.w1").waitForExistence(timeout: 10))
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
        XCTAssertTrue(element("tab.w2:t1").waitForExistence(timeout: 2))
        XCTAssertFalse(element("tab.w1:t1").exists)
        XCTAssertTrue(element("pane.w2:p1").exists)
        keepScreenshot("second workspace")
    }

    func testFollowsTabsMadeAndClosedInHerdr() async throws {
        XCTAssertTrue(element("tab.w1:t2").waitForExistence(timeout: 10))
        let created = try await call(one, "tab.create", ["workspace_id": "w1", "label": "live", "cwd": "/tmp",
                                                         "focus": false])
        let tab = try XCTUnwrap((created["tab"] as? [String: Any])?["tab_id"] as? String)
        XCTAssertTrue(element("tab.\(tab)").waitForExistence(timeout: 2))

        try await call(one, "tab.close", ["tab_id": tab])
        XCTAssertTrue(element("tab.\(tab)").waitForNonExistence(timeout: 2))
    }

    func testSwitchesSessions() {
        let picker = element("sidebar.session-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(element("workspace.w2").waitForExistence(timeout: 10))
        picker.click()
        let other = app.menuItems["This Mac · \(two)"]
        XCTAssertTrue(other.waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["This Mac · \(one)"].exists)
        other.click()

        XCTAssertTrue(wait(timeout: 5) { element("workspace.w1").value as? String == "gamma" })
        XCTAssertFalse(element("workspace.w2").exists)
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
