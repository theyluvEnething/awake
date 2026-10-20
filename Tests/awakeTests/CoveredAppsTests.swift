import CoreGraphics
import Testing
@testable import awake

private let screen = CGRect(x: 0, y: 39, width: 1800, height: 1056)

private func window(_ pid: pid_t, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> CoveredApps.Window {
    CoveredApps.Window(pid: pid, layer: layer, alpha: alpha, frame: frame)
}

struct CoveredAppsTests {
    @Test func aWindowBehindALargerWindowOfAnotherAppIsCovered() {
        let windows = [window(2, screen), window(1, screen.insetBy(dx: 100, dy: 100))]
        #expect(CoveredApps.covered(1, in: windows))
    }

    @Test func windowsTogetherCoverWhatNeitherCoversAlone() {
        let left = CGRect(x: 0, y: 39, width: 900, height: 1056)
        let right = CGRect(x: 900, y: 39, width: 900, height: 1056)
        #expect(CoveredApps.covered(1, in: [window(2, left), window(3, right), window(1, screen)]))
        #expect(!CoveredApps.covered(1, in: [window(2, left), window(1, screen)]))
    }

    @Test func aSliverStaysCoveredButAUsableStripDoesNot() {
        // ChatGPT's window was 1792 points wide over Claude's 1800: an 8-point edge nobody uses.
        let sliver = CGRect(x: 0, y: 39, width: 1792, height: 1056)
        #expect(CoveredApps.covered(1, in: [window(2, sliver), window(1, screen)]))
        let strip = CGRect(x: 0, y: 39, width: 1700, height: 1056)
        #expect(!CoveredApps.covered(1, in: [window(2, strip), window(1, screen)]))
    }

    @Test func onlyWindowsInFrontOfItCount() {
        #expect(!CoveredApps.covered(1, in: [window(1, screen), window(2, screen)]))
    }

    @Test func itsOwnWindowsDoNotCoverIt() {
        #expect(!CoveredApps.covered(1, in: [window(1, screen), window(1, screen.insetBy(dx: 50, dy: 50))]))
    }

    @Test func floatingWindowsAndTranslucentOverlaysNeitherHideNorCover() {
        // The Dock and the menu bar are full-width windows above the normal layer.
        #expect(!CoveredApps.covered(1, in: [window(9, screen, layer: 20), window(1, screen)]))
        #expect(!CoveredApps.covered(1, in: [window(2, screen, alpha: 0.5), window(1, screen)]))
        // A floating panel of the app itself stays visible above everything.
        #expect(!CoveredApps.covered(1, in: [window(1, CGRect(x: 600, y: 300, width: 400, height: 300), layer: 3),
                                             window(2, screen), window(1, screen)]))
    }

    @Test func anAppWithNothingOnScreenIsLeftAlone() {
        #expect(!CoveredApps.covered(1, in: [window(2, screen)]))
        // Tiny helper windows don't count as something to hide.
        #expect(!CoveredApps.covered(1, in: [window(2, screen), window(1, CGRect(x: 10, y: 50, width: 20, height: 20))]))
    }

    @Test func awakesOwnWindowsCountAsSeenOnlyWhileSomethingOfThemShows() {
        let settings = CoveredApps.Window(pid: 1, layer: 0, alpha: 1, frame: CGRect(x: 899, y: 39, width: 520, height: 672), number: 7)
        let statusItem = CoveredApps.Window(pid: 1, layer: 25, alpha: 1, frame: CGRect(x: 1297, y: 7, width: 24, height: 24), number: 8)
        #expect(CoveredApps.anyVisible([7], in: [statusItem, settings, window(2, screen)]))
        // A translucent-looking app still covers it: only the window's own alpha counts.
        #expect(!CoveredApps.anyVisible([7], in: [statusItem, window(2, screen), settings]))
        #expect(CoveredApps.anyVisible([7], in: [window(2, CGRect(x: 0, y: 39, width: 1000, height: 1056)), settings]))
        // Minimized or on another Space: not on screen at all.
        #expect(!CoveredApps.anyVisible([7], in: [statusItem, window(2, screen)]))
    }

    @Test func anAppIsHiddenOnlyAfterTwoCoveredChecksInARow() {
        let first = CoveredApps.step(covered: [1, 2], previous: [:])
        #expect(first.hide.isEmpty)
        let second = CoveredApps.step(covered: [1], previous: first.counts)
        #expect(second.hide == [1])
        // App 2 came back into view and app 1 is hidden now, so both counts start over.
        #expect(second.counts.isEmpty)
    }
}
