import Foundation
import Sparkle
import Testing
@testable import awake

@Suite(.serialized) @MainActor struct UpdateControllerTests {
    @Test func automaticUpdatesDefaultOnAndPersistWhenTurnedOff() throws {
        let name = "awake-update-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let updates = UpdateController(defaults: defaults)
        #expect(updates.automatic)
        updates.setAutomatic(false)
        #expect(!updates.automatic)
        #expect(!UpdateController(defaults: defaults).automatic)
        updates.setAutomatic(true)
        #expect(UpdateController(defaults: defaults).automatic)
    }

    @Test func manualDownloadStagesWithoutRestartingAndInstallsOnlyWhenRequested() {
        let updates = UpdateController()
        updates.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(updates.state == .checking)
        updates.showDownloadInitiated(cancellation: {})
        updates.showDownloadDidReceiveExpectedContentLength(100)
        updates.showDownloadDidReceiveData(ofLength: 25)
        #expect(updates.progress == 0.25)
        updates.showDownloadDidStartExtractingUpdate()
        var choices: [SPUUserUpdateChoice] = []
        updates.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices.isEmpty)
        #expect(updates.state == .ready)
        #expect(!updates.restartRequested)
        #expect(!updates.canCheck)
        updates.installNow()
        #expect(updates.restartRequested)
        #expect(choices == [.install])
        updates.installNow()
        #expect(choices == [.install])
    }

    @Test func failureDoesNotClaimUpToDateAndClearsAStaleInstallAction() {
        let updates = UpdateController()
        var installed = false
        updates.showReady(toInstallAndRelaunch: { _ in installed = true })
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        var acknowledged = false
        updates.showUpdaterError(error) { acknowledged = true }
        #expect(acknowledged)
        #expect(updates.state == .error)
        #expect(updates.message != nil)
        updates.installNow()
        #expect(!installed)
    }

    @Test func progressCannotOverrunOrInventATotal() {
        let updates = UpdateController()
        updates.showDownloadInitiated(cancellation: {})
        updates.showDownloadDidReceiveData(ofLength: 50)
        #expect(updates.progress == nil)
        updates.showDownloadDidReceiveExpectedContentLength(40)
        #expect(updates.progress == 1)
        updates.showDownloadDidReceiveExpectedContentLength(0)
        #expect(updates.progress == nil)
    }

    @Test func currentVersionAndUnsupportedSystemProduceDifferentResults() {
        let updates = UpdateController()
        for (reason, expected) in [(SPUNoUpdateFoundReason.onLatestVersion, UpdateController.State.current),
                                  (.onNewerThanLatestVersion, .current), (.systemIsTooOld, .error)] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                userInfo: [SPUNoUpdateFoundReasonKey: reason.rawValue])
            updates.showUpdateNotFoundWithError(error, acknowledgement: {})
            #expect(updates.state == expected)
        }
    }

    @Test func dismissingAStagedUpdateCannotLeaveADeadRestartButton() {
        let updates = UpdateController()
        var installed = false
        updates.showReady(toInstallAndRelaunch: { _ in installed = true })
        #expect(updates.updateInProgress)
        updates.dismissUpdateInstallation()
        #expect(!updates.updateInProgress)
        #expect(updates.state == .idle)
        updates.installNow()
        #expect(!installed)
    }
}
