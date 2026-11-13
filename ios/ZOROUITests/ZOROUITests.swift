// UNVERIFIED-ON-HOST
// XCUITest: launch, every section, first run and the approval sheet. Runs only under Xcode on a
// simulator or device. The app is launched with DEBUG-only arguments (ios/ZORO/UITestSupport.swift):
// an in-memory graph against an unreachable server, so no keychain, network or permission prompt.
import XCTest

final class ZOROUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zoro-ui-test"] + extra
        app.launch()
        return app
    }

    func testLaunchShowsHomeWithTheOrb() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["ZORO"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ZORO"].exists || app.otherElements["ZORO"].exists)
    }

    func testEverySectionOpens() {
        let app = launch()
        let tabs: [(String, [String])] = [
            ("Spaces", ["Shopping", "Finance", "Investments", "Fitness", "Photos", "Music"]),
            ("Activity", ["Agent activity", "History"]),
            ("You", ["Memory", "Integrations", "Device control", "Security and privacy", "Settings"]),
        ]
        for (tab, sections) in tabs {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 10))
            app.tabBars.buttons[tab].tap()
            for section in sections {
                let row = app.buttons[section].firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(section) row missing")
                row.tap()
                XCTAssertFalse(app.staticTexts["\(section) is not connected yet."].exists)
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
        }
    }

    func testFirstRunShowsWelcome() {
        let app = launch(["-zoro-ui-test-unpaired"])
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 10) || app.staticTexts["Welcome"].exists)
    }

    func testApprovalSheetShowsAndDeclines() {
        let app = launch(["-zoro-ui-test-approval"])
        let decline = app.buttons["Decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Run the routine you set up."].exists)
        decline.tap()
        XCTAssertFalse(decline.waitForExistence(timeout: 2))
    }
}
