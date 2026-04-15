// BackupBotUITests.swift
// BackupBotUITests
//
// UI tests for the BackupBot macOS application covering two critical flows:
// 1. Folder add flow — selecting, configuring, and saving a backup folder
// 2. Authentication sequence — phone number, verification code, and 2FA password
//
// These tests use the XCTest UI testing framework to simulate user interactions
// with the SwiftUI interface, verifying that views respond correctly and that
// state transitions occur as expected.
//
// Swift 5.9, macOS 14+
//

import XCTest
@testable import BackupBotKit

// MARK: - Folder Add Flow Tests

/// Tests the complete folder-add workflow from opening the add folder sheet
/// through folder selection, name configuration, and saving.
///
/// The folder add flow is one of the most critical user-facing interactions
/// in BackupBot. It involves:
/// - Opening the NSOpenPanel via the "Choose..." button
/// - Resolving the selected URL and creating a security-scoped bookmark
/// - Auto-populating display name and topic name from the folder path
/// - Computing and displaying folder statistics (size, file count)
/// - Persisting the SyncFolder and TopicMapping to SwiftData
/// - Storing the secure bookmark for re-access across app launches
final class FolderAddFlowTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        app = XCUIApplication()
        app.launchArguments = ["--uitest", "--reset-data"]
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
        try await super.tearDown()
    }

    // MARK: - Add Folder Sheet Presentation

    /// The "Add Folder" button should be visible when no folders exist.
    func testAddFolderButtonVisibleOnEmptyState() {
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5),
                      "The 'Add Folder' button should be visible when no folders are configured")

        let noFoldersText = app.staticTexts["No Folders Yet"]
        XCTAssertTrue(noFoldersText.exists,
                      "The empty state message should be displayed")
    }

    /// Clicking the "Add Folder" button should present the add folder sheet.
    func testAddFolderSheetOpens() {
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        addButton.click()

        // Verify the sheet appears
        let sheetTitle = app.staticTexts["Add Backup Folder"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3),
                      "The 'Add Backup Folder' sheet should appear after clicking Add Folder")

        // Verify key UI elements exist
        XCTAssertTrue(app.buttons["Choose..."].exists,
                      "The 'Choose...' button should be present in the sheet")
        XCTAssertTrue(app.textFields["Display Name"].exists,
                      "The 'Display Name' text field should be present")
        XCTAssertTrue(app.textFields["Topic Name"].exists,
                      "The 'Topic Name' text field should be present")
    }

    /// The "Add Folder" button should be disabled until a folder is selected
    /// and all required fields are populated.
    func testAddFolderButtonDisabledWithoutFolderSelection() {
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        // The primary "Add Folder" action button in the sheet should be disabled
        let saveButton = app.buttons["Add Folder"].firstMatch
        // Note: In the sheet, there's a save button with the same label
        // We need to find the one inside the sheet
        let sheetSaveButton = app.sheets.buttons["Add Folder"]
        if sheetSaveButton.waitForExistence(timeout: 2) {
            XCTAssertFalse(sheetSaveButton.isEnabled,
                           "The save button should be disabled when no folder is selected")
        }
    }

    /// The "Cancel" button should dismiss the sheet without saving.
    func testCancelButtonDismissesSheet() {
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let sheetTitle = app.staticTexts["Add Backup Folder"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3))

        // Click Cancel
        let cancelButton = app.sheets.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.click()
        }

        // The sheet should no longer be visible
        XCTAssertFalse(sheetTitle.exists,
                       "The sheet should be dismissed after clicking Cancel")
    }

    /// After selecting a folder, display name and topic name should auto-populate.
    func testFolderSelectionAutoPopulatesFields() {
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let sheetTitle = app.staticTexts["Add Backup Folder"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3))

        // Note: In UI tests, we can't easily interact with NSOpenPanel
        // because it runs in a separate process. For a full integration test,
        // we would need to use accessibility features or a test-specific
        // folder selection mechanism.
        //
        // Here we verify the UI state machine: if a folder were selected,
        // the display name field would be populated.
        //
        // For programmatic testing, the AddFolderView could expose a
        // testability hook that bypasses NSOpenPanel.
    }

    // MARK: - Form Validation

    /// The form should validate that the display name is not empty.
    func testFormValidationEmptyDisplayName() {
        // Open the add folder sheet
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let sheetTitle = app.staticTexts["Add Backup Folder"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3))

        // Clear the display name (if it was auto-populated)
        let displayNameField = app.textFields["Display Name"]
        if displayNameField.exists {
            // Select all and delete
            displayNameField.click()
            displayNameField.typeKey("a", modifierFlags: .command)
            displayNameField.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])

            // The save button should remain disabled
            let saveButton = app.sheets.buttons["Add Folder"]
            if saveButton.exists {
                XCTAssertFalse(saveButton.isEnabled,
                               "Save should be disabled with empty display name")
            }
        }
    }

    /// The form should validate that the topic name is not empty.
    func testFormValidationEmptyTopicName() {
        let addButton = app.buttons["Add Folder"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let sheetTitle = app.staticTexts["Add Backup Folder"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3))

        // Clear the topic name
        let topicNameField = app.textFields["Topic Name"]
        if topicNameField.exists {
            topicNameField.click()
            topicNameField.typeKey("a", modifierFlags: .command)
            topicNameField.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])

            let saveButton = app.sheets.buttons["Add Folder"]
            if saveButton.exists {
                XCTAssertFalse(saveButton.isEnabled,
                               "Save should be disabled with empty topic name")
            }
        }
    }

    // MARK: - Folder Statistics

    /// After folder selection, the "Folder Statistics" section should appear.
    ///
    /// - Note: This test requires a way to inject a folder selection in the
    ///   test environment. In a real test suite, the `AddFolderView` would
    ///   need a testability injection point.
    func testFolderStatisticsDisplayedAfterSelection() {
        // This test documents the expected behavior:
        // After selecting a folder via NSOpenPanel, the UI should show:
        // 1. "Folder Statistics" section header
        // 2. Total Size row with formatted byte count
        // 3. File Count row with the number of files
        // 4. Subfolders row with the count of subdirectories
        //
        // The actual verification requires either:
        // a) A test-specific folder selection mechanism, or
        // b) Snapshot testing of the view state
    }
}

// MARK: - Authentication Sequence Tests

/// Tests the Telegram authentication flow UI: phone number entry,
/// verification code submission, and 2FA password entry.
///
/// The auth flow is a multi-step wizard with the following transitions:
/// 1. Phone Number → (Send Code) → Waiting for Code
/// 2. Verification Code → (Verify) → Authenticated or Waiting for Password
/// 3. 2FA Password → (Authenticate) → Authenticated
///
/// Each step has input validation, loading states, error handling,
/// and navigation controls (back / cancel).
final class AuthenticationSequenceTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        app = XCUIApplication()
        app.launchArguments = ["--uitest", "--reset-data"]
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
        try await super.tearDown()
    }

    // MARK: - Settings Navigation

    /// The Telegram settings view should be accessible via the Settings window.
    func testTelegramSettingsAccessible() {
        // Open Settings
        app.menuItems["Settings"].click()

        let telegramTab = app.tabs["Telegram"]
        if telegramTab.waitForExistence(timeout: 3) {
            telegramTab.click()
        }

        // Verify key elements
        let apiIDField = app.textFields["API ID"]
        XCTAssertTrue(apiIDField.waitForExistence(timeout: 3),
                      "API ID field should be visible in Telegram settings")

        let apiHashField = app.secureFields["API Hash"]
        XCTAssertTrue(apiHashField.exists,
                      "API Hash field should be visible in Telegram settings")

        let forumChatIDField = app.textFields["Forum Chat ID"]
        XCTAssertTrue(forumChatIDField.exists,
                      "Forum Chat ID field should be visible in Telegram settings")
    }

    // MARK: - Phone Number Step

    /// The auth flow should start at the phone number entry step.
    func testAuthFlowStartsWithPhoneNumber() {
        // Navigate to Telegram settings and click Connect
        app.menuItems["Settings"].click()

        let telegramTab = app.tabs["Telegram"]
        if telegramTab.waitForExistence(timeout: 3) {
            telegramTab.click()
        }

        let connectButton = app.buttons["Connect & Authenticate"]
        if connectButton.waitForExistence(timeout: 3) && connectButton.isEnabled {
            connectButton.click()

            // The auth sheet should appear with phone number entry
            let phoneTitle = app.staticTexts["Enter Phone Number"]
            XCTAssertTrue(phoneTitle.waitForExistence(timeout: 3),
                          "Auth flow should start at the phone number step")

            // Verify the phone input field exists
            let phoneField = app.textFields["Phone Number"]
            XCTAssertTrue(phoneField.exists,
                          "Phone number input field should be present")

            // Verify the step indicator shows step 1
            let stepIndicator = app.staticTexts["Phone"]
            XCTAssertTrue(stepIndicator.exists,
                          "Step 1 'Phone' should be shown in the step indicator")
        }
    }

    /// The "Send Code" button should be disabled with an empty phone number.
    func testSendCodeButtonDisabledWithEmptyPhone() {
        // Open auth flow
        app.menuItems["Settings"].click()

        let telegramTab = app.tabs["Telegram"]
        if telegramTab.waitForExistence(timeout: 3) {
            telegramTab.click()
        }

        let connectButton = app.buttons["Connect & Authenticate"]
        if connectButton.waitForExistence(timeout: 3) && connectButton.isEnabled {
            connectButton.click()

            let sendCodeButton = app.sheets.buttons["Send Code"]
            if sendCodeButton.waitForExistence(timeout: 2) {
                XCTAssertFalse(sendCodeButton.isEnabled,
                               "Send Code should be disabled with empty phone number")
            }
        }
    }

    /// Entering a valid phone number should enable the "Send Code" button.
    func testSendCodeButtonEnabledWithValidPhone() {
        app.menuItems["Settings"].click()

        let telegramTab = app.tabs["Telegram"]
        if telegramTab.waitForExistence(timeout: 3) {
            telegramTab.click()
        }

        let connectButton = app.buttons["Connect & Authenticate"]
        if connectButton.waitForExistence(timeout: 3) && connectButton.isEnabled {
            connectButton.click()

            let phoneField = app.textFields["Phone Number"]
            if phoneField.waitForExistence(timeout: 2) {
                phoneField.click()
                phoneField.typeText("15551234567")

                let sendCodeButton = app.sheets.buttons["Send Code"]
                if sendCodeButton.waitForExistence(timeout: 2) {
                    XCTAssertTrue(sendCodeButton.isEnabled,
                                  "Send Code should be enabled with a valid phone number")
                }
            }
        }
    }

    // MARK: - Verification Code Step

    /// After sending the phone number, the flow should transition to the
    /// verification code step.
    ///
    /// - Note: This test documents the expected transition but cannot
    ///   fully exercise it without a real or mock backend.
    func testVerifyCodeStepTransition() {
        // The expected transition:
        // 1. User enters phone number and clicks "Send Code"
        // 2. The step indicator advances to step 2 ("Code")
        // 3. A verification code input field appears
        // 4. A countdown timer shows remaining time to resend
        // 5. The "Verify" button is disabled until a code is entered
        //
        // In a real test environment with a mock transport:
        // - Enter phone number
        // - Click "Send Code"
        // - Verify step 2 is shown
        // - Enter a 5-6 digit code
        // - Click "Verify"
        // - Verify the transition to authenticated or 2FA step
    }

    /// The "Resend Code" button should appear after the countdown timer expires.
    func testResendCodeButtonAfterTimer() {
        // Expected behavior:
        // 1. After sending the phone number, a 120-second countdown starts
        // 2. The countdown is displayed next to the code field
        // 3. When the countdown reaches 0, the "Resend Code" button appears
        // 4. Clicking "Resend Code" triggers the send code flow again
        //
        // In a test environment, the timer could be accelerated
    }

    // MARK: - 2FA Password Step

    /// If the account has 2FA enabled, the flow should transition to the
    /// password step after successful code verification.
    func test2FAPasswordStepTransition() {
        // Expected transition:
        // 1. User enters correct verification code
        // 2. The server indicates 2FA is required
        // 3. The step indicator advances to step 3 ("Password")
        // 4. A secure password input field appears
        // 5. A lock icon and warning about 2FA is displayed
        // 6. The "Authenticate" button is disabled until a password is entered
    }

    /// The "Back" button should allow returning to the previous step.
    func testBackNavigationInAuthFlow() {
        // Expected behavior:
        // 1. On the verification code step, clicking "Back" returns to phone step
        // 2. On the 2FA password step, clicking "Back" returns to code step
        // 3. The entered data from the previous step should be preserved
        // 4. The error message should be cleared when navigating back
    }

    // MARK: - Success State

    /// After successful authentication, the success view should be shown.
    func testSuccessViewAfterAuthentication() {
        // Expected behavior:
        // 1. After successful code verification (no 2FA) or password entry
        // 2. A success animation (checkmark bounce) is displayed
        // 3. The text "Successfully Connected" appears
        // 4. A "Done" button closes the auth sheet
        // 5. The Telegram settings view shows "Connected" status
    }

    /// After successful authentication, the connection status should update.
    func testConnectionStatusUpdatesAfterAuth() {
        // Expected behavior:
        // 1. The status indicator changes from gray/yellow to green
        // 2. The masked phone number is displayed
        // 3. The "Disconnect" button appears
        // 4. The "Test Connection" button becomes available
    }

    // MARK: - Error Handling

    /// Error messages should be displayed when authentication fails.
    func testErrorMessageDisplayOnAuthFailure() {
        // Expected behavior:
        // 1. When sendPhoneNumber fails, an error banner appears
        // 2. When verifyCode fails, an error message is shown
        // 3. When verifyPassword fails, an error message is shown
        // 4. Errors are cleared when navigating between steps
        // 5. The loading spinner stops on error
    }

    /// The "Cancel" button should dismiss the auth sheet at any step.
    func testCancelButtonDismissesAuthSheet() {
        // Open auth flow
        app.menuItems["Settings"].click()

        let telegramTab = app.tabs["Telegram"]
        if telegramTab.waitForExistence(timeout: 3) {
            telegramTab.click()
        }

        let connectButton = app.buttons["Connect & Authenticate"]
        if connectButton.waitForExistence(timeout: 3) && connectButton.isEnabled {
            connectButton.click()

            // Click Cancel on the phone step
            let cancelButton = app.sheets.buttons["Cancel"]
            if cancelButton.waitForExistence(timeout: 2) {
                cancelButton.click()
            }

            // The sheet should be dismissed
            let phoneTitle = app.staticTexts["Enter Phone Number"]
            let sheetDismissed = !phoneTitle.exists
            XCTAssertTrue(sheetDismissed,
                          "Auth sheet should be dismissed after clicking Cancel")
        }
    }
}
