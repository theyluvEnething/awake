import AppKit
import IOKit
import IOKit.ps
import ServiceManagement
import SwiftUI

/// kIOPMMessageClamshellStateChange, a C macro Swift can't import.
private let clamshellStateChange: UInt32 = 0xE003_4100

/// The menu bar app: `awake` without arguments, as launchd starts it from Awake.app. It sits idle
/// and wakes for state changes, wake, lid, charger and thermal events, plus a loose 30-second reconcile.
@MainActor
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let showSettings = Notification.Name(Identity.app + ".show-settings")

    private var item: NSStatusItem!
    private let model = AwakeModel(snapshot: Snapshot.take())
    private let display = DisplaySleep()
    private var window: NSWindow?
    private let paths = SetupPaths(app: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    private var setupModel: SetupModel?
    private var setupTimer: Timer?
    private var reconcileTask: Task<Void, Never>?
    private var reconcilePending = false
    private var retryHelperPending = false
    private var uninstalling = false
    private var stateWatch: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private var refreshPending = false
    private var disagreeSince: Double?
    private var lidPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = 0
    private var powerSource: CFRunLoopSource?

    static func start() -> Never {
        // A newly registered menu agent must leave an existing instance alone. A hand-opened app
        // asks that instance to show setup or Settings, as Finder and Spotlight do.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Identity.app)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != Identity.menu {
                DistributedNotificationCenter.default().postNotificationName(showSettings, object: nil, userInfo: nil,
                                                                             deliverImmediately: true)
            }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = MenuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if paths.atRequiredLocation { watchState() }
        watchSystem()
        // Also reconciles, so a hold ends on time even while launchd holds back the 30-second check.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.reconcileInBackground()
            }
        }
        refreshTimer?.tolerance = 10
        refresh()
        reconcileInBackground()
        // launchd starts the menu at login without a window; opening the app by hand shows its settings.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != Identity.menu {
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if paths.atRequiredLocation { Store.setKeepDisplayOn(false) }
        display.end()
    }

    // MARK: Menu

    /// Every item has an icon, as in macOS's own menus: Settings and Quit use the
    /// symbols of the Apple and app menus.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = Snapshot.take()
        model.snapshot = s
        updateDisplay(s)
        menu.removeAllItems()

        let header = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        header.image = Glyph.menu(flag: s.flag)
        header.subtitle = summary(s)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        guard paths.atRequiredLocation else {
            menu.addItem(menuItem("Finish Setup…", "wrench.and.screwdriver", #selector(openSetup)))
            menu.addItem(menuItem("Quit Awake", "xmark.rectangle", #selector(quit)))
            return
        }
        guard !uninstalling else { return }

        let toggle = menuItem(Format.mode(.auto), "sun.max", #selector(toggleAwake))
        toggle.state = s.decision.mode == .off ? .off : .on
        menu.addItem(toggle)
        menu.addItem(.separator())
        if !Setup.snapshot(paths: paths).complete {
            menu.addItem(menuItem("Finish Setup…", "wrench.and.screwdriver", #selector(openSetup)))
        }
        menu.addItem(menuItem("Settings…", "gear", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Uninstall Awake…", "trash", #selector(uninstall)))
        menu.addItem(menuItem("Quit Awake", "xmark.rectangle", #selector(quit)))
    }

    private func menuItem(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func toggleAwake() {
        setAwake(Snapshot.take().decision.mode == .off)
    }

    func setAwake(_ on: Bool) {
        change { Store.setMode(on ? .auto : .off) }
    }

    func setIndefinitely(_ on: Bool) {
        change { on ? Store.setMode(.on) : Store.endOn() }
    }

    func setKeepDisplayOn(_ on: Bool) {
        guard !uninstalling && paths.atRequiredLocation else { return }
        Store.setKeepDisplayOn(on)
        refresh()
        reconcileInBackground()
    }

    @objc func openSettings() {
        guard !uninstalling else { return }
        guard Setup.snapshot(paths: paths).complete else {
            openSetup()
            return
        }
        if setupModel != nil { window?.close() }
        if window == nil {
            let view = SettingsView(model: model, setAwake: { [weak self] in self?.setAwake($0) },
                                    setIndefinitely: { [weak self] in self?.setIndefinitely($0) },
                                    setKeepDisplayOn: { [weak self] in self?.setKeepDisplayOn($0) })
            window = makeWindow(view)
        }
        refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        setupTimer?.invalidate()
        setupTimer = nil
        setupModel = nil
        window = nil
    }

    private func makeWindow<Content: View>(_ view: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Awake"
        window.styleMask = [.titled, .closable]
        // The title bar shows the canvas, so the window is one surface as in AdBlock.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.canvas
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: Setup

    @objc private func openSetup() {
        guard !uninstalling else { return }
        if setupModel == nil {
            window?.close()
            let setup = SetupModel(snapshot: Setup.snapshot(paths: paths))
            setupModel = setup
            let view = SetupView(model: setup, install: { [weak self] in self?.installSetup() },
                                 openSystemSettings: { SMAppService.openSystemSettingsLoginItems() },
                                 copyHooks: { [weak self] in self?.copyClaudeHooks() },
                                 showInFinder: { [weak self] in
                                     guard let self else { return }
                                     NSWorkspace.shared.activateFileViewerSelecting([self.paths.app])
                                 }, quit: { NSApp.terminate(nil) },
                                 done: { [weak self] in self?.openSettings() })
            window = makeWindow(view)
            if paths.atRequiredLocation {
                setupTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshSetup() }
                }
            }
        }
        refreshSetup()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func installSetup() {
        guard !uninstalling, paths.atRequiredLocation, let setup = setupModel, !setup.installing else { return }
        setup.installing = true
        setup.serviceErrors = [:]
        setup.codexError = nil
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            for part in SetupService.allCases {
                do { try Setup.register(part, app: paths.app) }
                catch { setup.serviceErrors[part] = error.localizedDescription }
                refreshSetup()
            }
            do { try SetupHooks.updateCodex(at: paths.codexHooks, binary: SetupPaths.binary, install: true) }
            catch { setup.codexError = error.localizedDescription }
            setup.installing = false
            refreshSetup()
        }
    }

    private func refreshSetup() {
        guard !uninstalling, let setup = setupModel else { return }
        let wasEnabled = setup.snapshot.helper == .enabled
        setup.snapshot = Setup.snapshot(paths: paths)
        if !wasEnabled && setup.snapshot.helper == .enabled {
            reconcileInBackground(retryFailures: true)
        }
    }

    private func copyClaudeHooks() {
        guard let setup = setupModel else { return }
        do {
            let json = try SetupHooks.claudeJSON(binary: SetupPaths.binary)
            NSPasteboard.general.clearContents()
            setup.copied = NSPasteboard.general.setString(json, forType: .string)
            setup.copyError = setup.copied ? nil : "Couldn't copy the hooks. Try again."
        } catch {
            setup.copyError = error.localizedDescription
        }
    }

    // MARK: Uninstall

    @objc private func uninstall() {
        guard !uninstalling, paths.atRequiredLocation, setupModel?.installing != true else { return }
        let confirm = NSAlert()
        confirm.messageText = "Uninstall Awake?"
        confirm.informativeText = Format.uninstallDescription
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard runAlert(confirm) == .alertFirstButtonReturn else { return }
        guard FileManager.default.isDeletableFile(atPath: paths.app.path) else {
            showProblem("Awake can't move itself to the Trash", "Check the app's permissions in Finder, then try again.")
            return
        }
        uninstalling = true
        Store.setKeepDisplayOn(false)
        display.update(false)
        window?.close()
        stateWatch?.cancel()
        stateWatch = nil
        Task { await performUninstall() }
    }

    private func performUninstall() async {
        await reconcileTask?.value
        let savedEnergy = Store.savedEnergy()
        let status = Store.withLock {
            Store.setMode(.off)
            Store.leases().forEach { Store.removeLease($0.name) }
            Store.queuedEvents().forEach { Store.removeEvent($0.file) }
            Store.release(until: Date().timeIntervalSince1970 + 120)
            Store.clearFailures()
            return Reconcile.run(locked: true, sleepAfterRelease: false)
        } ?? nil
        if status == nil || status?.flag == true || status?.error != nil || Store.savedEnergy() != nil {
            let alert = NSAlert()
            alert.messageText = "Power settings could not be restored"
            alert.informativeText = [status?.error, Format.uninstallRecovery(savedEnergy: savedEnergy)]
                .compactMap { $0 }.joined(separator: "\n\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel Uninstall")
            alert.addButton(withTitle: "Uninstall Anyway")
            guard runAlert(alert) == .alertSecondButtonReturn else {
                resumeAfterUninstall()
                return
            }
        }
        do {
            try await Setup.unregisterBackground(.reconcile, app: paths.app)
            try await Setup.unregisterBackground(.helper, app: paths.app)
            try SetupHooks.updateCodex(at: paths.codexHooks, binary: SetupPaths.binary, install: false)
        } catch {
            showProblem("Uninstall stopped", error.localizedDescription + "\n\nFix this, then choose Uninstall Awake again.")
            resumeAfterUninstall()
            return
        }

        // Restore power while the helper lives, stop writers, then remove files. The menu is last:
        // unregistering our own launchd job sends SIGTERM, so ignore it for the remaining steps.
        let previous = signal(SIGTERM, SIG_IGN)
        do {
            try Setup.unregisterMenu(app: paths.app)
        } catch {
            signal(SIGTERM, previous)
            showProblem("The menu login item could not be removed", error.localizedDescription)
            resumeAfterUninstall()
            return
        }
        // Claude Code hooks call the app until it's in the Trash and would recreate its state, so
        // the state goes after the app.
        do { try Setup.trashApp(at: paths.app) }
        catch { NSWorkspace.shared.activateFileViewerSelecting([paths.app]) }
        try? Setup.removeUserFiles(paths: paths)
        NSApp.terminate(nil)
    }

    private func resumeAfterUninstall() {
        uninstalling = false
        watchState()
        refresh()
        openSettings()
    }

    private func showProblem(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        runAlert(alert)
    }

    /// The menu runs while another app is active, so an alert would open behind its windows.
    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }

    /// Quit ends the lid and display holds before the menu exits.
    @objc private func quit() {
        guard !uninstalling else { return }
        if paths.atRequiredLocation { Store.setKeepDisplayOn(false) }
        display.end()
        change { Store.setMode(.off) }
        NSApp.terminate(nil)
    }

    private func change(_ edit: () -> Void) {
        guard !uninstalling && paths.atRequiredLocation else { return }
        _ = Store.withLock(timeout: 2) {
            edit()
            return Reconcile.run(locked: true)
        }
        refresh()
    }

    // MARK: State

    private func refresh() {
        let s = Snapshot.take()
        model.snapshot = s
        updateDisplay(s)
        let warning = warning(s)
        item.button?.image = Glyph.status(flag: s.flag, warning: warning != nil)
        item.button?.toolTip = "Awake: " + (warning ?? summary(s))
    }

    private func updateDisplay(_ s: Snapshot) {
        display.update(paths.atRequiredLocation && !uninstalling && s.decision.displayAwake)
        model.displayAwake = display.active
        model.displayError = display.error
    }

    private func summary(_ s: Snapshot) -> String {
        if let warning = warning(s) { return warning }
        let d = s.decision
        if s.flag, let first = d.holds.first {
            return Format.hold(first, now: s.inputs.now) + (d.holds.count > 1 ? " +\(d.holds.count - 1)" : "")
        }
        if d.released { return "Going to sleep" }
        if let pause = d.pause { return Format.paused(pause) }
        return Format.capitalized(Format.lidEffect(s.flag))
    }

    /// The helper is unavailable, or the flag has differed from awake's decision for a few seconds.
    private func warning(_ s: Snapshot) -> String? {
        if let error = s.status?.error { return Format.capitalized(error) }
        if let error = display.error { return Format.capitalized(error) }
        guard let status = s.status, status.awake != s.flag else {
            disagreeSince = nil
            return nil
        }
        guard let since = disagreeSince else {
            disagreeSince = s.inputs.now
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            return nil
        }
        guard s.inputs.now - since >= 2 else { return nil }
        return Format.capitalized(Format.changedOutside(flag: s.flag))
    }

    private func reconcileInBackground(retryFailures: Bool = false) {
        guard !uninstalling && paths.atRequiredLocation else { return }
        guard reconcileTask == nil else {
            reconcilePending = true
            retryHelperPending = retryHelperPending || retryFailures
            return
        }
        reconcileTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                if retryFailures {
                    return Store.withLock { Store.clearFailures(); return Reconcile.run(locked: true) } ?? nil
                }
                return Reconcile.run()
            }.value
            guard let self else { return }
            reconcileTask = nil
            setupModel?.powerError = status?.error
            refresh()
            if reconcilePending {
                let retry = retryHelperPending
                reconcilePending = false
                retryHelperPending = false
                reconcileInBackground(retryFailures: retry)
            }
        }
    }

    // MARK: Watching

    private func watchState() {
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        let fd = open(Store.dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        stateWatch = source
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileInBackground() }
        }
        workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loggingOut() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileInBackground() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showSettings, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        // The lid: restore the energy mode as soon as it opens, lower it as soon as it closes.
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, .main)
            let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"))
            IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, _ in
                guard message == clamshellStateChange, let context else { return }
                let app = Unmanaged<MenuApp>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { app.reconcileInBackground() }
            }, context, &lidNotifier)
            IOObjectRelease(root)
            lidPort = port
        }
        // The charger: battery and AC switch over.
        if let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let app = Unmanaged<MenuApp>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { app.reconcileInBackground() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// Logout, restart or shutdown: indefinite lid and display holds end, lid sleep comes back on
    /// and so does the energy mode.
    private func loggingOut() {
        if paths.atRequiredLocation { Store.setKeepDisplayOn(false) }
        display.end()
        guard !uninstalling && paths.atRequiredLocation else { return }
        _ = Store.withLock(timeout: 2) {
            Store.endOn()
            Store.release(until: Date().timeIntervalSince1970 + 120)
            return Reconcile.run(locked: true, sleepAfterRelease: false)
        }
    }
}

/// The cup in the menu bar: outline when closing the lid would sleep, filled when it keeps the Mac
/// running, with a warning mark when something is off.
@MainActor
enum Glyph {
    static func status(flag: Bool, warning: Bool) -> NSImage {
        let base = symbol(flag ? "cup.and.saucer.fill" : "cup.and.saucer", size: 15)
        guard warning else { return base }
        let badge = symbol("exclamationmark.circle.fill", size: 8)
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let b = NSRect(x: rect.maxX - badge.size.width, y: rect.maxY - badge.size.height,
                           width: badge.size.width, height: badge.size.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: b.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge.draw(in: b)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func menu(flag: Bool) -> NSImage {
        symbol(flag ? "cup.and.saucer.fill" : "cup.and.saucer", size: 13)
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Awake")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
