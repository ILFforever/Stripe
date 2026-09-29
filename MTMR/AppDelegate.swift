//
//  AppDelegate.swift
//  MTMR
//
//  Created by Anton Palgunov on 16/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) // the STR mark is wider than square
    var isBlockedApp: Bool = false

    private var fileSystemSource: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_: Notification) {
        // Checked quietly; the prompt comes only when a key-simulating button is used.
        NSLog("Stripe: Accessibility permission \(AccessibilityPermission.isGranted ? "granted" : "not granted yet")")

        TouchBarController.shared.setupControlStripPresence()

        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusImage")
        }
        createMenu()

        reloadOnDefaultConfigChanged()
        DebugHooks.installIfRequested()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIsBlockedApp), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIsBlockedApp), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIsBlockedApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func applicationWillTerminate(_: Notification) {}

    /// Clicking the Dock icon (there's one while Settings is open, even minimized) brings it forward.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.shared.show() }
        return true
    }

    @objc func updateIsBlockedApp() {
        if let frontmostAppId = TouchBarController.shared.frontmostApplicationIdentifier {
            isBlockedApp = AppSettings.blacklistedAppIds.firstIndex(of: frontmostAppId) != nil
        } else {
            isBlockedApp = false
        }
        createMenu()
    }

    @objc func requestAccessibility(_: Any?) {
        AccessibilityPermission.request()
    }

    @objc func openSettings(_: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func openPreferences(_: Any?) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [standardConfigPath]
        task.launch()
    }

    @objc func toggleControlStrip(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.showControlStripState = item.state == .off
        TouchBarController.shared.resetControlStrip()
    }

    @objc func toggleBlackListedApp(_: Any?) {
        if let appIdentifier = TouchBarController.shared.frontmostApplicationIdentifier {
            if let index = TouchBarController.shared.blacklistAppIdentifiers.firstIndex(of: appIdentifier) {
                TouchBarController.shared.blacklistAppIdentifiers.remove(at: index)
            } else {
                TouchBarController.shared.blacklistAppIdentifiers.append(appIdentifier)
            }
            
            AppSettings.blacklistedAppIds = TouchBarController.shared.blacklistAppIdentifiers
            TouchBarController.shared.updateActiveApp()
            updateIsBlockedApp()
        }
    }

    @objc func toggleHapticFeedback(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.hapticFeedbackState = item.state == .on
    }

    @objc func toggleMultitouch(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        AppSettings.multitouchGestures = item.state == .on
        TouchBarController.shared.basicView?.legacyGesturesEnabled = item.state == .on
    }

    @objc func openPreset(_: Any?) {
        let dialog = NSOpenPanel()

        dialog.title = "Choose a items.json file"
        dialog.showsResizeIndicator = true
        dialog.showsHiddenFiles = true
        dialog.canChooseDirectories = false
        dialog.canCreateDirectories = false
        dialog.allowsMultipleSelection = false
        dialog.allowedFileTypes = ["json"]
        dialog.directoryURL = NSURL.fileURL(withPath: appSupportDirectory, isDirectory: true)

        if dialog.runModal() == .OK, let path = dialog.url?.path {
            TouchBarController.shared.reloadPreset(path: path)
        }
    }

    @objc func toggleStartAtLogin(_: Any?) {
        LaunchAtLoginController().setLaunchAtLogin(!LaunchAtLoginController().launchAtLogin, for: NSURL.fileURL(withPath: Bundle.main.bundlePath))
        createMenu()
    }

    /// The menu is rebuilt each time it opens (menuNeedsUpdate), so the current
    /// app's name and the Accessibility status are always up to date.
    func createMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // No icons: macOS 26 adds one to Quit by itself, and that's enough.
        menu.addItem(withTitle: "\(Brand.name) Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        let openAtLogin = NSMenuItem(title: "Open at Login", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        openAtLogin.state = LaunchAtLoginController().launchAtLogin ? .on : .off
        menu.addItem(openAtLogin)

        if !AccessibilityPermission.isGranted {
            let allow = NSMenuItem(title: "Allow Accessibility for Media Keys…", action: #selector(requestAccessibility(_:)), keyEquivalent: "")
            menu.addItem(allow)
        }

        // Hiding the bar for the app in front, named so it's clear what it does.
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
           let name = app.localizedName {
            menu.addItem(.separator())
            let hide = NSMenuItem(title: "Hide \(Brand.name) for \u{201C}\(name)\u{201D}", action: #selector(toggleBlackListedApp(_:)), keyEquivalent: "")
            // Read the list itself; isBlockedApp is only refreshed on app switches.
            hide.state = TouchBarController.shared.blacklistAppIdentifiers.contains(app.bundleIdentifier ?? "") ? .on : .off
            menu.addItem(hide)
        }

        menu.addItem(.separator())

        let options = NSMenu()
        let haptics = options.addItem(withTitle: "Haptic Feedback", action: #selector(toggleHapticFeedback(_:)), keyEquivalent: "")
        haptics.state = AppSettings.hapticFeedbackState ? .on : .off
        let controlStrip = options.addItem(withTitle: "Hide Control Strip", action: #selector(toggleControlStrip(_:)), keyEquivalent: "")
        controlStrip.state = AppSettings.showControlStripState ? .off : .on
        let gestures = options.addItem(withTitle: "Volume & Brightness Gestures", action: #selector(toggleMultitouch(_:)), keyEquivalent: "")
        gestures.state = AppSettings.multitouchGestures ? .on : .off
        let optionsItem = menu.addItem(withTitle: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options

        let advanced = NSMenu()
        advanced.addItem(withTitle: "Edit JSON…", action: #selector(openPreferences(_:)), keyEquivalent: "")
        advanced.addItem(withTitle: "Open Preset File…", action: #selector(openPreset(_:)), keyEquivalent: "")
        let advancedItem = menu.addItem(withTitle: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = advanced

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func reloadOnDefaultConfigChanged() {
        let file = NSURL.fileURL(withPath: standardConfigPath)

        let fd = open(file.path, O_EVTONLY)

        fileSystemSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: DispatchQueue(label: "DefaultConfigChanged"))

        fileSystemSource?.setEventHandler(handler: {
            DispatchQueue.main.async {
                guard Date() > TouchBarController.shared.ignoreFileWatcherUntil else { return }
                TouchBarController.shared.reloadPreset(path: file.path)
            }
        })

        fileSystemSource?.setCancelHandler(handler: {
            close(fd)
        })

        fileSystemSource?.resume()
    }
}
