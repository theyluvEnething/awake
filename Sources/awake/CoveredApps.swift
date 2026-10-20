import AppKit
import CoreGraphics

/// Claude and T3 Code keep drawing while other apps' windows cover theirs completely, which cost about
/// a third of a core in their processes and WindowServer on this Mac. Hiding them, as Cmd-H does,
/// stops it, and switching back to one shows it again. Nothing visible is lost: only apps with every
/// window fully covered, and not in front, are hidden.
enum CoveredApps {
    static let bundles: Set<String> = ["com.anthropic.claudefordesktop", "com.t3tools.t3code"]
    /// Checks in a row an app must be covered before it is hidden, so a window briefly placed over it
    /// leaves it alone.
    static let checksBeforeHiding = 2
    /// Uncovered edges thinner than this, such as 8 points beside a slightly narrower window, still
    /// count as covered.
    static let sliver: CGFloat = 12
    /// Windows smaller than this in either dimension are helpers, not something to look at.
    static let smallest: CGFloat = 40

    struct Window: Equatable {
        var pid: pid_t
        var layer: Int
        var alpha: Double
        var frame: CGRect
        var number = 0
    }

    /// The windows on the current screen, front to back. Bounds and owners need no permission.
    static func windows() -> [Window] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return Window(pid: pid, layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                          alpha: entry[kCGWindowAlpha as String] as? Double ?? 1, frame: frame,
                          number: entry[kCGWindowNumber as String] as? Int ?? 0)
        }
    }

    /// Whether any of the windows numbered `numbers` shows on screen, more than a sliver of it. Awake
    /// pauses its own windows' updates otherwise; macOS's occlusion state calls a window behind a
    /// translucent one visible, so it can't tell.
    static func anyVisible(_ numbers: Set<Int>, in windows: [Window]) -> Bool {
        windows.indices.contains { index in
            guard numbers.contains(windows[index].number) else { return false }
            let covers = windows[..<index]
                .filter { !numbers.contains($0.number) && $0.layer == 0 && $0.alpha >= 0.95 }
                .map(\.frame)
            return !uncovered(windows[index].frame, by: covers).isEmpty
        }
    }

    /// Whether every window `pid` shows is hidden behind opaque normal windows of other apps. An app with
    /// a window above the normal layer, such as a floating panel, is visible; one with nothing on screen
    /// is left alone.
    static func covered(_ pid: pid_t, in windows: [Window]) -> Bool {
        let own = windows.indices.filter {
            windows[$0].pid == pid && windows[$0].frame.width >= smallest && windows[$0].frame.height >= smallest
        }
        guard !own.isEmpty, own.allSatisfy({ windows[$0].layer == 0 }) else { return false }
        return own.allSatisfy { index in
            let covers = windows[..<index]
                .filter { $0.pid != pid && $0.layer == 0 && $0.alpha >= 0.95 }
                .map(\.frame)
            return uncovered(windows[index].frame, by: covers).isEmpty
        }
    }

    /// The parts of `rect` none of `covers` overlaps, ignoring slivers.
    static func uncovered(_ rect: CGRect, by covers: [CGRect]) -> [CGRect] {
        var remaining = [rect]
        for cover in covers {
            remaining = remaining.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(cover)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
        return remaining.filter { $0.width >= sliver && $0.height >= sliver }
    }

    /// One check: apps covered this time add to their count, others start over, and apps that reach
    /// `checksBeforeHiding` are hidden and start over too.
    static func step(covered: Set<pid_t>, previous: [pid_t: Int]) -> (counts: [pid_t: Int], hide: Set<pid_t>) {
        var counts: [pid_t: Int] = [:]
        var hide: Set<pid_t> = []
        for pid in covered {
            let count = (previous[pid] ?? 0) + 1
            if count >= checksBeforeHiding { hide.insert(pid) } else { counts[pid] = count }
        }
        return (counts, hide)
    }
}
