import XCTest

final class HerdlightUITests: XCTestCase {
    @MainActor
    func testLaunchShowsWindowAndSidebar() throws {
        // `make e2e` starts a throwaway herdr session and passes its name in as
        // TEST_RUNNER_HL_SESSION; xcodebuild strips the prefix.
        let session = try XCTUnwrap(ProcessInfo.processInfo.environment["HL_SESSION"], "run through make e2e")
        let app = XCUIApplication()
        app.launchArguments = ["-session", session]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
    }
}
