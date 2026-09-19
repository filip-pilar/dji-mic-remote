import XCTest
import AppKit
import AVFoundation
@testable import DJIMicRemote

final class StartupRecognizer: LocalRecognizing {
    var continuation: CheckedContinuation<Void, Error>?
    var preparations = 0
    var delayed = false
    // The tests inspect/resume this continuation on the main actor. A
    // nonisolated async witness otherwise publishes it from the generic pool.
    @MainActor func prepare(progress: @escaping (String) -> Void) async throws {
        preparations += 1
        progress("Loading the model…")
        if delayed { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    @MainActor func transcribe(_ audio: URL) async throws -> String { "Fixture" }
}

final class StartupTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    @MainActor func makeRemote(_ recognizer: StartupRecognizer = StartupRecognizer()) throws -> Remote {
        _ = NSApplication.shared
        let local = LocalDictation(history: try LocalHistory(directory: directory), recognizer: recognizer, recorder: FakeRecorder(),
            inputs: { [AudioInput(uid: "fixture", name: "Fixture mic")] }, autoSend: false)
        local.inputUID = "fixture"
        let remote = Remote(local: local); remote.engine = .local
        remote.permissionCheckInterval = 0.01
        remote.accessibilityAllowed = { true }; remote.microphoneAuthorization = { .authorized }
        remote.installListener = { true }; remote.prepareTextTarget = {}
        remote.openAccessibilitySettings = {}; remote.openMicrophoneSettings = {}
        remote.dismissPermissionWindows = {}
        remote.requestMicrophoneAccess = { XCTFail("Unexpected microphone prompt"); return false }
        remote.buildPanel()
        remote.local.onChange = { [weak remote] in remote?.refreshControls() }
        remote.refreshControls()
        return remote
    }
    @MainActor func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Startup fixture timed out")
    }
    @MainActor func testOneClickPreparesAndStartsWithoutSecondEnable() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        XCTAssertEqual(remote.primaryButton.title, "Start remote")
        remote.primaryAction()
        try await waitUntil { remote.enabled }
        XCTAssertEqual(recognizer.preparations, 1)
        XCTAssertEqual(remote.primaryButton.title, "Pause remote")
        XCTAssertTrue(remote.local.ready)
        XCTAssertFalse(remote.localControls.isHidden)
        remote.primaryAction(); XCTAssertFalse(remote.enabled)
        remote.primaryAction(); XCTAssertTrue(remote.enabled)
        XCTAssertEqual(recognizer.preparations, 1)
    }
    @MainActor func testStatusFeedbackExpiresAndCannotSurviveNewWorkOrOverrideAttention() async throws {
        let remote = try makeRemote()
        XCTAssertEqual(remote.statusPresentation.badge, .paused)
        remote.savedFeedbackDuration = 0.02
        remote.showSavedFeedback()
        XCTAssertEqual(remote.statusPresentation.badge, .saved)
        remote.refreshControls()
        XCTAssertEqual(remote.statusPresentation.badge, .saved)
        try await waitUntil { remote.savedFeedbackTimer == nil }
        XCTAssertEqual(remote.statusPresentation.badge, .paused)
        remote.showSavedFeedback()
        remote.startupIssue = "Permission fixture"
        XCTAssertEqual(remote.statusPresentation.badge, .attention)
        remote.startupIssue = nil
        remote.local.prepare(); remote.updateStatusIcon()
        XCTAssertEqual(remote.statusPresentation.badge, .working)
        XCTAssertNil(remote.savedFeedbackTimer)
        try await waitUntil { !remote.local.working }
        XCTAssertEqual(remote.statusPresentation.badge, .paused)
        remote.showSavedFeedback(); remote.stopRemote()
        XCTAssertNil(remote.savedFeedbackTimer)
        remote.engine = .flow
        remote.showSavedFeedback()
        XCTAssertNil(remote.savedFeedbackTimer)
        XCTAssertEqual(remote.statusPresentation.badge, .paused)
    }
    @MainActor func testCancelledSetupCannotStartLate() async throws {
        let recognizer = StartupRecognizer(); recognizer.delayed = true
        let remote = try makeRemote(recognizer); remote.primaryAction()
        try await waitUntil { recognizer.continuation != nil }
        XCTAssertEqual(remote.primaryButton.title, "Cancel setup")
        remote.primaryAction(); recognizer.continuation?.resume()
        try await waitUntil { !remote.local.working }
        XCTAssertFalse(remote.enabled); XCTAssertFalse(remote.startupRequested)
        XCTAssertEqual(remote.primaryButton.title, "Start remote")
    }
    @MainActor func testAccessibilityPermissionResumesSameStart() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var allowed = false; var opened = 0
        remote.accessibilityAllowed = { allowed }
        remote.openAccessibilitySettings = { opened += 1 }
        remote.primaryAction(); try await waitUntil { remote.startupStage == .accessibility }
        XCTAssertFalse(remote.enabled); XCTAssertEqual(opened, 1)
        XCTAssertEqual(recognizer.preparations, 0)
        XCTAssertEqual(remote.primaryButton.title, "Open Accessibility Settings")
        allowed = true; remote.resumeStartup()
        try await waitUntil { remote.enabled }
        XCTAssertEqual(recognizer.preparations, 1)
    }
    @MainActor func testAccessibilityGrantResumesWhileControlsRemainClosed() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var allowed = false; var settingsOpened = 0
        remote.accessibilityAllowed = { allowed }
        remote.openAccessibilitySettings = { settingsOpened += 1 }
        remote.primaryAction()
        XCTAssertFalse(remote.popover.isShown)
        XCTAssertTrue(try XCTUnwrap(remote.permissionTimer).isValid)
        // No activation notification, menu reopening, or manual resume call.
        allowed = true
        try await waitUntil { remote.enabled }
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(recognizer.preparations, 1)
        XCTAssertNil(remote.permissionTimer)
        XCTAssertFalse(remote.popover.isShown)
    }
    @MainActor func testPermissionWatchDoesNotReopenSettingsOrLoadBeforeGrant() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var checks = 0; var opened = 0
        remote.accessibilityAllowed = { checks += 1; return false }
        remote.openAccessibilitySettings = { opened += 1 }
        remote.primaryAction()
        try await waitUntil { checks >= 4 }
        XCTAssertEqual(opened, 1); XCTAssertEqual(recognizer.preparations, 0)
        XCTAssertEqual(remote.stateTitle.stringValue, "Waiting for Accessibility")
        remote.cancelStartup()
        XCTAssertNil(remote.permissionTimer)
    }
    @MainActor func testMicrophoneSettingsGrantResumesWithoutReturningToApp() async throws {
        let remote = try makeRemote(); var permission = AVAuthorizationStatus.denied
        remote.microphoneAuthorization = { permission }
        remote.primaryAction()
        XCTAssertNotNil(remote.permissionTimer)
        permission = .authorized
        try await waitUntil { remote.enabled }
        XCTAssertNil(remote.permissionTimer)
    }
    @MainActor func testDeniedMicrophoneHasSpecificActionAndResumes() async throws {
        let remote = try makeRemote(); var permission = AVAuthorizationStatus.denied
        var opened = 0; remote.openMicrophoneSettings = { opened += 1 }
        remote.microphoneAuthorization = { permission }
        remote.primaryAction()
        XCTAssertEqual(remote.primaryButton.title, "Open Microphone Settings"); XCTAssertEqual(opened, 1)
        XCTAssertFalse(remote.local.working)
        permission = .authorized; remote.resumeStartup()
        try await waitUntil { remote.enabled }
    }
    @MainActor func testAccessibilityClosesControlsAndOpensSettingsOnlyOnExplicitActions() throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        remote.accessibilityAllowed = { false }
        var actions: [String] = []
        remote.dismissPermissionWindows = { actions.append("dismiss") }
        remote.openAccessibilitySettings = { actions.append("settings") }
        remote.primaryAction()
        remote.resumeStartup(); remote.resumeStartup(); remote.checkAccessibility()
        XCTAssertEqual(actions, ["dismiss", "settings"])
        XCTAssertFalse(remote.revealAppButton.isHidden)
        remote.primaryAction()
        XCTAssertEqual(actions, ["dismiss", "settings", "dismiss", "settings"])
        XCTAssertEqual(recognizer.preparations, 0)
    }
    @MainActor func testMissingEntryRecoveryRevealsExactlyRunningBundle() throws {
        let remote = try makeRemote(); remote.accessibilityAllowed = { false }
        var actions: [String] = []
        remote.dismissPermissionWindows = { actions.append("dismiss") }
        remote.revealApplication = { url in
            actions.append("reveal"); XCTAssertEqual(url, Bundle.main.bundleURL)
        }
        remote.primaryAction(); actions.removeAll()
        remote.accessibilityHelp()
        XCTAssertEqual(actions, []) // Inline instructions, no extra window.
        XCTAssertEqual(remote.primaryButton.title, "Show this app in Finder")
        XCTAssertTrue(remote.statusLabel.stringValue.contains("click −"))
        XCTAssertTrue(remote.statusLabel.stringValue.contains("click +"))
        remote.primaryAction()
        XCTAssertEqual(actions, ["dismiss", "reveal"])
        XCTAssertTrue(remote.startupRequested); XCTAssertFalse(remote.enabled)
        remote.cancelStartup(); XCTAssertTrue(remote.revealAppButton.isHidden)
    }
    @MainActor func testGrantWhileReadingRecoveryContinuesOnlyOnce() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var allowed = false; remote.accessibilityAllowed = { allowed }
        remote.primaryAction(); remote.accessibilityHelp()
        XCTAssertTrue(remote.accessibilityRecovery)
        allowed = true
        try await waitUntil { remote.enabled }
        remote.resumeStartup()
        XCTAssertFalse(remote.accessibilityRecovery)
        XCTAssertEqual(recognizer.preparations, 1)
        XCTAssertNil(remote.permissionTimer)
    }
    @MainActor func testBothPermissionsPrecedeModelAndMicrophoneDenialDoesNotOpenSettings() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var accessibility = false; var microphone = AVAuthorizationStatus.notDetermined
        var prompts = 0; var settings = 0
        remote.accessibilityAllowed = { accessibility }; remote.microphoneAuthorization = { microphone }
        remote.openMicrophoneSettings = { settings += 1 }
        remote.requestMicrophoneAccess = { prompts += 1; microphone = .denied; return false }
        remote.primaryAction()
        XCTAssertEqual(remote.startupStage, .accessibility); XCTAssertEqual(prompts, 0)
        XCTAssertEqual(recognizer.preparations, 0)
        accessibility = true; remote.resumeStartup()
        XCTAssertEqual(remote.startupStage, .microphoneRequest)
        XCTAssertEqual(remote.stateTitle.stringValue, "Allow microphone access")
        try await waitUntil { remote.startupStage == .microphone }
        XCTAssertEqual(prompts, 1); XCTAssertEqual(settings, 0); XCTAssertEqual(recognizer.preparations, 0)
        remote.primaryAction(); XCTAssertEqual(settings, 1)
        microphone = .authorized; remote.resumeStartup()
        try await waitUntil { remote.enabled }
        XCTAssertEqual(recognizer.preparations, 1)
    }
    @MainActor func testGrantingMicrophoneContinuesWithoutAnotherStart() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var permission = AVAuthorizationStatus.notDetermined
        remote.microphoneAuthorization = { permission }
        remote.requestMicrophoneAccess = { permission = .authorized; return true }
        remote.primaryAction()
        XCTAssertEqual(recognizer.preparations, 0)
        try await waitUntil { remote.enabled }
        XCTAssertEqual(recognizer.preparations, 1)
    }
    @MainActor func testCancelledMicrophonePromptCannotLoadOrEnableLate() async throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var permission = AVAuthorizationStatus.notDetermined
        var pending: CheckedContinuation<Bool, Never>?
        remote.microphoneAuthorization = { permission }
        remote.requestMicrophoneAccess = { await withCheckedContinuation { pending = $0 } }
        remote.primaryAction(); try await waitUntil { pending != nil }
        XCTAssertEqual(remote.primaryButton.title, "Cancel setup")
        let task = try XCTUnwrap(remote.microphoneTask)
        remote.primaryAction(); permission = .authorized; pending?.resume(returning: true)
        await task.value
        XCTAssertFalse(remote.enabled); XCTAssertFalse(remote.startupRequested)
        XCTAssertEqual(recognizer.preparations, 0)
    }
    @MainActor func testCancelledAccessibilityWaitDoesNotResumeAfterGrant() throws {
        let recognizer = StartupRecognizer(); let remote = try makeRemote(recognizer)
        var allowed = false; remote.accessibilityAllowed = { allowed }
        remote.primaryAction(); remote.cancelStartup()
        XCTAssertNil(remote.permissionTimer)
        allowed = true; remote.resumeStartup()
        XCTAssertFalse(remote.enabled); XCTAssertEqual(recognizer.preparations, 0)
    }
    @MainActor func testProgressRefreshPreservesMicrophoneMenuItems() throws {
        let remote = try makeRemote()
        let item = try XCTUnwrap(remote.inputPicker.item(at: 1))
        remote.refreshControls(); remote.refreshControls()
        XCTAssertTrue(remote.inputPicker.item(at: 1) === item)
        remote.local.listInputs = { [] }; remote.local.refreshInputs(); remote.refreshControls()
        XCTAssertEqual(remote.inputPicker.numberOfItems, 1)
        XCTAssertEqual(remote.inputPicker.indexOfSelectedItem, 0)
    }
    @MainActor func testListenerFailureStaysOffWithRetryAction() async throws {
        let remote = try makeRemote(); remote.installListener = { false }
        remote.primaryAction(); try await waitUntil { !remote.local.working }
        XCTAssertFalse(remote.enabled); XCTAssertFalse(remote.startupRequested)
        XCTAssertEqual(remote.primaryButton.title, "Try again")
        XCTAssertTrue(remote.statusLabel.stringValue.contains("Accessibility"))
    }
    @MainActor func testPermissionLossDuringLoadDoesNotArmRemote() async throws {
        let recognizer = StartupRecognizer(); recognizer.delayed = true
        let remote = try makeRemote(recognizer); var permission = AVAuthorizationStatus.authorized
        remote.microphoneAuthorization = { permission }; remote.primaryAction()
        try await waitUntil { recognizer.continuation != nil }
        permission = .denied; recognizer.continuation?.resume()
        try await waitUntil { !remote.local.working }
        XCTAssertFalse(remote.enabled); XCTAssertEqual(remote.startupStage, .microphone)
    }
    @MainActor func testMissingInputRevealsChoiceInsteadOfSilentFailure() throws {
        let remote = try makeRemote(); remote.local.listInputs = { [] }
        remote.primaryAction()
        XCTAssertFalse(remote.localControls.isHidden)
        XCTAssertEqual(remote.stateTitle.stringValue, "Choose a microphone")
        XCTAssertFalse(remote.enabled)
    }
    @MainActor func testPendingStartContinuesWhenMicrophoneBecomesAvailable() async throws {
        let remote = try makeRemote(); var inputs: [AudioInput] = []
        remote.local.listInputs = { inputs }; remote.primaryAction()
        XCTAssertTrue(remote.startupRequested); XCTAssertFalse(remote.enabled)
        inputs = [AudioInput(uid: "fixture", name: "Fixture mic")]
        remote.resumeStartup(); try await waitUntil { remote.enabled }
    }
    @MainActor func testReceiverArrivalDoesNotCancelModelPreparation() async throws {
        let recognizer = StartupRecognizer(); recognizer.delayed = true
        let remote = try makeRemote(recognizer); remote.primaryAction()
        try await waitUntil { recognizer.continuation != nil }
        remote.suspendForReceiverChange()
        recognizer.continuation?.resume()
        try await waitUntil { remote.enabled }
        XCTAssertTrue(remote.local.ready)
    }
    @MainActor func testDeviceLossDuringLoadingDoesNotArmRemote() async throws {
        let recognizer = StartupRecognizer(); recognizer.delayed = true
        let remote = try makeRemote(recognizer); remote.primaryAction()
        try await waitUntil { recognizer.continuation != nil }
        remote.local.listInputs = { [] }; recognizer.continuation?.resume()
        try await waitUntil { !remote.local.working }
        XCTAssertFalse(remote.enabled); XCTAssertFalse(remote.localControls.isHidden)
        XCTAssertEqual(remote.stateTitle.stringValue, "Choose a microphone")
    }
}
