import XCTest

final class BistPhoneUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BIST_UI_TEST_ID"] = UUID().uuidString
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureEditCompleteSurvivesRelaunch() throws {
        let app = isolatedApp()
        app.launch()
        let capture = element("phone.capture", in: app)
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        capture.tap()
        capture.typeText("Review the phone app")
        element("phone.capture.add", in: app).tap()

        let task = element("phone.task.open", in: app)
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        let notes = element("phone.task.notes", in: app)
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("Written on the iPhone")
        element("phone.task.save", in: app).tap()

        let complete = element("phone.task.complete", in: app)
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        let completed = NSPredicate(format: "value == %@", "Completed")
        expectation(for: completed, evaluatedWith: complete)
        waitForExpectations(timeout: 5)
        keepScreenshot("Completed phone task")

        app.terminate()
        app.launch()
        let persistedCompletion = element("phone.task.complete", in: app)
        XCTAssertTrue(persistedCompletion.waitForExistence(timeout: 10))
        XCTAssertEqual(persistedCompletion.value as? String, "Completed")
        element("phone.task.open", in: app).tap()
        let savedNotes = element("phone.task.notes", in: app)
        XCTAssertTrue(savedNotes.waitForExistence(timeout: 5))
        XCTAssertEqual(savedNotes.value as? String, "Written on the iPhone")
        keepScreenshot("Persisted task details")
    }

    func testNoteSurvivesRelaunchAndLocalBuildKeepsCloudOff() throws {
        let app = isolatedApp()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Note"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Note"].tap()
        let note = element("phone.note", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("A note from my phone\nA second line")
        XCTAssertEqual(note.value as? String, "A note from my phone\nA second line")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Note"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Note"].tap()
        let reopened = element("phone.note", in: app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "A note from my phone\nA second line")
        keepScreenshot("Persisted phone note")
        app.tabBars.buttons["Settings"].tap()
        let cloud = element("phone.sync.toggle", in: app)
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        XCTAssertFalse(cloud.isEnabled)
        XCTAssertEqual(cloud.value as? String, "0")
        keepScreenshot("Local phone settings")
    }
}
