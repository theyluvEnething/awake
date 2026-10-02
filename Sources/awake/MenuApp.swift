import AppKit
import IOKit
import IOKit.ps
import SwiftUI

/// kIOPMMessageClamshellStateChange, a C macro Swift can't import.
private let clamshellStateChange: UInt32 = 0xE003_4100

/// The menu bar app: `awake` without arguments, as launchd starts it from Awake.app. It sits idle
/// and wakes for state changes, wake, lid, charger and thermal events, plus a loose 30-second refresh.
@MainActor
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let jobLabel = "toybox.awake"
    static let showSettings = Notification.Name("toybox.awake.show-settings")

    private var item: NSStatusItem!
    private let model = AwakeModel(snapshot: Snapshot.take())
    private var window: NSWindow?
    private var stateWatch: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private var refreshPending = false
    private var disagreeSince: Double?
    private var lidPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = 0
    private var powerSource: CFRunLoopSource?

    static func start() -> Never {
        // Opened from Finder or Spotlight while the menu already runs: show its settings and leave.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: jobLabel)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(showSettings, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
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
        watchState()
        watchSystem()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer?.tolerance = 10
        refresh()
        reconcileInBackground()
        // launchd starts the menu at login without a window; opening the app by hand shows its settings.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != Self.jobLabel {
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = Snapshot.take()
        model.snapshot = s
        menu.removeAllItems()

        let header = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        header.image = Glyph.menu(flag: s.flag)
        header.subtitle = summary(s)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Awake", action: #selector(toggleAwake), keyEquivalent: "")
        toggle.target = self
        toggle.state = s.decision.mode == .off ? .off : .on
        menu.addItem(toggle)
        // While the switch is on, macOS ignores the Apple menu's Sleep too.
        if s.flag {
            let sleep = NSMenuItem(title: "Sleep Now", action: #selector(sleepNow), keyEquivalent: "")
            sleep.target = self
            menu.addItem(sleep)
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Awake", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        menu.addItem(quit)
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

    /// Releases the switch for a minute so the Mac can sleep, then asks for sleep.
    @objc func sleepNow() {
        change(sleepAfterRelease: false) { Store.release(until: Date().timeIntervalSince1970 + 60) }
        System.sleepNow()
    }

    @objc func openSettings() {
        if window == nil {
            let view = SettingsView(model: model, setAwake: { [weak self] in self?.setAwake($0) },
                                    setIndefinitely: { [weak self] in self?.setIndefinitely($0) },
                                    sleepNow: { [weak self] in self?.sleepNow() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Awake"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.snapshot = Snapshot.take()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Quit sets Off first, so nothing keeps the Mac running for agents once the menu is gone.
    @objc private func quit() {
        change { Store.setMode(.off) }
        NSApp.terminate(nil)
    }

    private func change(sleepAfterRelease: Bool = true, _ edit: () -> Void) {
        _ = Store.withLock(timeout: 2) {
            edit()
            return Reconcile.run(locked: true, sleepAfterRelease: sleepAfterRelease)
        }
        refresh()
    }

    // MARK: State

    private func refresh() {
        let s = Snapshot.take()
        model.snapshot = s
        let warning = warning(s)
        item.button?.image = Glyph.status(flag: s.flag, warning: warning != nil)
        item.button?.toolTip = "Awake: " + (warning ?? summary(s))
    }

    private func summary(_ s: Snapshot) -> String {
        if let warning = warning(s) { return warning }
        let d = s.decision
        if s.flag {
            guard let first = d.holds.first else { return "Stays on with the lid closed" }
            return Format.label(first, now: s.inputs.now) + (d.holds.count > 1 ? " +\(d.holds.count - 1)" : "")
        }
        if d.released { return "Going to sleep" }
        if let pause = d.pause, !d.holds.isEmpty { return "Paused: \(pause)" }
        return "Sleeps when the lid closes"
    }

    /// The sudo rule is missing, or the switch has differed from awake's decision for a few seconds.
    private func warning(_ s: Snapshot) -> String? {
        if let error = s.status?.error { return error.prefix(1).uppercased() + error.dropFirst() }
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
        return s.flag ? "The switch was turned on outside Awake" : "The switch is off although Awake wants it on"
    }

    private func reconcileInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            Reconcile.run()
            await self?.refresh()
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

    /// Logout, restart or shutdown: On ends, the switch goes off and the energy mode comes back.
    private func loggingOut() {
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
