//
//  ScreenshotWatcher.swift
//  Stripe
//
//  While macOS's Screenshot toolbar is open, macOS puts its own screenshot
//  controls (selection, window, screen, record, capture) on the Touch Bar, but
//  Stripe's bar would cover them. With a Screenshot key's "nativeBar" option on
//  (the default), Stripe steps aside while the toolbar is open, like hiding it
//  for an app, and comes back when it closes.
//
//  The toolbar never becomes the frontmost app (its process, screencaptureui,
//  runs in the background), so it's found by its windows instead: while open,
//  the toolbar and the capture overlay sit at a very high window level.
//

import AppKit

final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    /// Set while parsing a preset, when a Screenshot key wants the native bar.
    var wantedByPreset = false

    /// Polling runs only while enabled.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    /// Whether the Screenshot toolbar is open right now (as of the last check).
    private(set) var isOpen = false

    private var timer: Timer?

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 0.3
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if isOpen {
            isOpen = false
            TouchBarController.shared.updateActiveApp()
        }
    }

    /// Checks a few times shortly after the Screenshot key opens the toolbar, so
    /// the switch doesn't wait for the next one-second check.
    func checkSoon() {
        guard enabled else { return }
        for delay in [0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    private func check() {
        let open = ScreenshotWatcher.toolbarOnScreen()
        guard open != isOpen else { return }
        isOpen = open
        TouchBarController.shared.updateActiveApp()
    }

    private static let screenshotBundleIDs: Set<String> = ["com.apple.screenshot.launcher", "com.apple.screencaptureui"]

    private static func toolbarOnScreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        for window in windows {
            // The open toolbar and overlay sit at layer ~1500; a lower-level
            // "Screenshot" window can linger after closing, so ignore those.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 1000 else { continue }
            if window[kCGWindowOwnerName as String] as? String == "screencapture" { return true }
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t,
               let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               screenshotBundleIDs.contains(id) {
                return true
            }
        }
        return false
    }
}
