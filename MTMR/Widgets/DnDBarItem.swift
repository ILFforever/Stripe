//
//  DnDBarItem.swift
//  MTMR
//
//  Created by Anton Palgunov on 29/08/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import AppKit

class DnDBarItem: CustomButtonTouchBarItem, TearDownable {
    private var timer: Timer!

    func tearDown() {
        timer?.invalidate()
    }

    init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier, title: "")
        isBordered = false
        if !theme.stripeWidgets { setWidth(value: 32) } // MTMR's narrow key; Stripe sizes it like other keys

        actions.append(ItemAction(trigger: .singleTap) { [weak self] in self?.DnDToggle() })

        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)

        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func DnDToggle() {
        DoNotDisturb.toggle { [weak self] in self?.refresh() }
    }

    @objc func refresh() {
        let on = DoNotDisturb.isEnabled
        if theme.stripeWidgets {
            if style.symbol == nil { image = stripeSymbol(on ? "moon.fill" : "moon") }
        } else {
            image = on ? #imageLiteral(resourceName: "dnd-on") : #imageLiteral(resourceName: "dnd-off")
        }
        setBuiltInActive(DoNotDisturb.isEnabled)
    }
}

/// Do Not Disturb, as a Focus. macOS 12 replaced the old setting (which MTMR
/// wrote, and which macOS now ignores) with Focus, and gives other apps no way
/// to switch it. So the key runs a shortcut the user makes once in Shortcuts,
/// "Stripe Do Not Disturb", whose one action is Set Focus › Do Not Disturb ›
/// Toggle.
public enum DoNotDisturb {
    static let shortcutName = "Stripe Do Not Disturb"
    /// What Stripe last set, for when the Focus file can't be read.
    private static var lastSet = false
    private static let queue = DispatchQueue(label: "com.ilfforever.stripe.dnd")

    /// Whether a Focus is on: from the file macOS keeps while one is, else
    /// what Stripe last set (so it can be wrong after a change made elsewhere).
    static var isEnabled: Bool {
        let path = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return lastSet }
        return entries.contains { !(($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty }
    }

    /// Runs the shortcut off the main thread, then calls `done` on it. Without
    /// the shortcut, explains how to make it.
    static func toggle(done: @escaping () -> Void) {
        queue.async {
            let ran = run(["run", shortcutName])
            DispatchQueue.main.async {
                if ran {
                    lastSet.toggle()
                } else {
                    explainSetup()
                }
                done()
            }
        }
    }

    /// Runs /usr/bin/shortcuts; true if it exited cleanly.
    private static func run(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func explainSetup() {
        let alert = NSAlert()
        alert.messageText = "Make the \u{201C}\(shortcutName)\u{201D} shortcut"
        alert.informativeText = """
        macOS doesn't let apps switch Focus, so the Do Not Disturb key runs a shortcut. \
        In Shortcuts, make a new shortcut named \u{201C}\(shortcutName)\u{201D} with one action: \
        Set Focus, set to toggle Do Not Disturb. Then tap the key again.
        """
        alert.addButton(withTitle: "Open Shortcuts")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
