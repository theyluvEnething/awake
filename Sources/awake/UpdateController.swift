import AppKit
import Observation
import Sparkle

/// Typeout's update behavior: check after startup and every six hours, stage quietly,
/// then install on quit or when the user chooses to restart. Sparkle owns verification and replacement.
@MainActor @Observable
final class UpdateController: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    enum State { case idle, checking, current, downloading, extracting, ready, installing, error }

    private(set) var state: State = .idle
    private(set) var automatic: Bool
    private(set) var version: String?
    private(set) var message: String?
    private(set) var needsDownloads = false
    private(set) var checkAvailable = false
    private(set) var restartRequested = false
    var suspended = false
    private var received: UInt64 = 0
    private var expected: UInt64 = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var availability: NSKeyValueObservation?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var failureStreak = 0
    @ObservationIgnored private var checksToSkip = 0

    static let releases = URL(string: "https://github.com/theyluvEnething/awake/releases/latest")!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automatic = defaults.object(forKey: "AwakeAutomaticUpdates") as? Bool ?? true
        super.init()
    }

    var canCheck: Bool {
        !suspended && checkAvailable && [.idle, .current, .error].contains(state)
    }

    var updateInProgress: Bool { [.checking, .downloading, .extracting, .ready, .installing].contains(state) }

    var progress: Double? {
        expected == 0 ? nil : min(1, Double(received) / Double(expected))
    }

    static var installedVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return "Development build" }
        return "\(version) (build \(build))"
    }

    func start() {
        guard updater == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        do { try updater.start() }
        catch { failed(error); return }
        updater.automaticallyDownloadsUpdates = automatic
        availability = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            MainActor.assumeIsolated { self?.checkAvailable = change.newValue ?? false }
        }
        startup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.scheduledCheck()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduledCheck() }
        }
        timer?.tolerance = 60
    }

    func setAutomatic(_ on: Bool) {
        defaults.set(on, forKey: "AwakeAutomaticUpdates")
        automatic = on
        updater?.automaticallyDownloadsUpdates = on
    }

    private func scheduledCheck() {
        guard automatic, canCheck, let updater else { return }
        if checksToSkip > 0 { checksToSkip -= 1; return }
        beginCheck()
        updater.checkForUpdatesInBackground()
    }

    func checkNow() {
        guard canCheck, let updater else { return }
        beginCheck()
        updater.checkForUpdates()
    }

    private func beginCheck() {
        state = .checking
        message = nil
        needsDownloads = false
    }

    func installNow() {
        guard state == .ready, let install else { return }
        self.install = nil
        restartRequested = true
        state = .installing
        install()
    }

    func openDownloads() { NSWorkspace.shared.open(Self.releases) }

    private func failed(_ error: Error) {
        install = nil
        restartRequested = false
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
            let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
            if reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
                || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
                state = .current
                message = nil
                version = nil
                failureStreak = 0
                checksToSkip = 0
                return
            }
        }
        state = .error
        if message == error.localizedDescription { return }
        message = error.localizedDescription
        needsDownloads = error.domain == SUSparkleErrorDomain
            && [SUError.signatureError.rawValue, SUError.validationError.rawValue,
                SUError.insufficientSigningError.rawValue].contains(OSStatus(error.code))
        failureStreak = min(3, failureStreak + 1)
        checksToSkip = failureStreak
    }

    // MARK: Sparkle user interaction, rendered in Awake's Settings instead of popup windows

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Awake owns the 20-second / six-hour schedule, so Sparkle's own scheduler stays off.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { beginCheck() }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        failureStreak = 0
        checksToSkip = 0
        if appcastItem.isInformationOnlyUpdate {
            self.state = .error
            message = "This update requires a fresh download."
            needsDownloads = true
            reply(.dismiss)
        } else if state.stage == .installing {
            self.state = .ready
            install = { reply(.install) }
        } else {
            self.state = .downloading
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failed(error)
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failed(error)
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        state = .downloading
        received = 0
        expected = 0
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = received.addingReportingOverflow(length)
        received = overflow ? .max : total
    }
    func showDownloadDidStartExtractingUpdate() { state = .extracting }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state = .ready
        install = { reply(.install) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) { state = .installing }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        install = nil
        restartRequested = false
        if updateInProgress { state = .idle }
    }

    // MARK: Background checks bypass the user driver until the update is staged

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        version = item.displayVersionString
        state = .downloading
        received = 0
        expected = 0
        failureStreak = 0
        checksToSkip = 0
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        version = item.displayVersionString
        state = .ready
        install = immediateInstallHandler
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { failed(error) }
}
