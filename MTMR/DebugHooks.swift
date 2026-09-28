//
//  DebugHooks.swift
//  Stripe
//
//  Lets a developer drive the bar without touching it (e.g. when working on a
//  headless Mac, paired with `screencapture -b` to see the result). Only active
//  when launched with STRIPE_DEBUG=1:
//
//    open --env STRIPE_DEBUG=1 build/Stripe.app
//    swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.ilfforever.stripe.debug"), object: "popover", deliverImmediately: true)'
//
//  Commands: "performance [cpu|gpu]" (open that performance page), "popover" (expand the first popover), "group" (open the first group),
//  "dismiss" (return to the main bar), "settings" (open the editor window),
//  "select N" (select the Nth top-level item in the editor), "tap NAME" (tap the
//  first item whose identifier contains NAME, e.g. "tap battery"), "press NAME"
//  (hold down the first button whose identifier or title contains NAME, to see
//  its pressed color), "release" (let go of every held button), "battery" (open
//  the battery panel; "battery left" puts its back chevron on the left).
//

import Cocoa

enum DebugHooks {
    static let notification = Notification.Name("com.ilfforever.stripe.debug")

    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["STRIPE_DEBUG"] == "1" else { return }
        NSLog("Stripe debug hooks enabled")
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            handle(command: note.object as? String ?? "")
        }
    }

    private static func handle(command: String) {
        let items = TouchBarController.shared.items.values
        NSLog("Stripe debug command: \(command)")
        switch command {
        case "popover":
            (items.first { $0 is PopoverBarItem } as? PopoverBarItem)?.expand()
        case "group":
            (items.first { $0 is GroupBarItem } as? GroupBarItem)?.open()
        case "settings":
            SettingsWindowController.shared.show()
        case let command where command.hasPrefix("background"):
            // Trying out bar backgrounds: "background color|gradient|pattern|video <path>|none".
            let parts = command.split(separator: " ", maxSplits: 2).map(String.init)
            let background: BarBackground
            switch parts.count > 1 ? parts[1] : "none" {
            case "color": background = .color(NSColor(srgbRed: 0.10, green: 0.14, blue: 0.30, alpha: 1))
            case "gradient": background = .gradient([NSColor(srgbRed: 0.35, green: 0.10, blue: 0.45, alpha: 1),
                                                     NSColor(srgbRed: 0.05, green: 0.20, blue: 0.40, alpha: 1)])
            case "pattern": background = .pattern(BarPattern(rawValue: parts.count > 2 ? parts[2] : "") ?? .stripes, [])
            case "video" where parts.count > 2: background = .video(URL(fileURLWithPath: parts[2]))
            default: background = .none
            }
            TouchBarController.shared.basicView?.background?.background = background
        case let page where page.hasPrefix("performance"):
            // "performance", "performance cpu" or "performance gpu": opens that page.
            let kind = PerformancePanelOptions.Kind(rawValue: String(page.dropFirst(12))) ?? .unified
            PerformancePanel.shared.open(options: PerformancePanelOptions(kind: kind, closeSide: .right))
        case let pane where pane.hasPrefix("pane "):
            // "pane library", "pane outline" or "pane bars": the left pane's tab.
            SettingsWindowController.shared.session.leftPane = String(pane.dropFirst(5))
        case "select bar", "select background":
            SettingsWindowController.shared.session.barPanel = .background
        case "select theme":
            SettingsWindowController.shared.session.barPanel = .theme
        case let select where select.hasPrefix("select "):
            // "select 3" selects the 4th top-level item in the editor; "select 3.1"
            // the 2nd item inside it (a folder, group or popover), and so on.
            let editor = SettingsWindowController.shared
            var list = editor.document.items
            var found: EditorItem?
            for part in select.dropFirst(7).split(separator: ".") {
                guard let index = Int(part), list.indices.contains(index) else { found = nil; break }
                found = list[index]
                list = found?.children ?? []
            }
            if let item = found { editor.session.selection = item.id }
        case let pane where pane.hasPrefix("pane "):
            // "pane outline" or "pane library" switches the editor's left pane.
            SettingsWindowController.shared.session.leftPane = String(pane.dropFirst(5))
        case let search where search.hasPrefix("search "):
            // "search vol" types into the editor's sidebar search.
            SettingsWindowController.shared.session.search = String(search.dropFirst(7))
        case let tap where tap.hasPrefix("tap "):
            // "tap battery" taps the first item whose identifier contains "battery".
            let name = tap.dropFirst(4).lowercased()
            let match = TouchBarController.shared.items
                .first { $0.key.rawValue.lowercased().contains(name) }?.value as? CustomButtonTouchBarItem
            match?.callActions(for: .singleTap)
        case let press where press.hasPrefix("press "):
            let name = press.dropFirst(6).lowercased()
            let match = TouchBarController.shared.items.first { identifier, item in
                identifier.rawValue.lowercased().contains(name)
                    || ((item as? CustomButtonTouchBarItem)?.title.lowercased().contains(name) ?? false)
            }?.value as? CustomButtonTouchBarItem
            match?.isPressed = true
        case "release":
            for case let item as CustomButtonTouchBarItem in items {
                item.isPressed = false
            }
        case "battery", "battery left":
            // With the battery item's own settings when it's on the bar.
            var options = (items.first { $0 is BatteryBarItem } as? BatteryBarItem)?.panelOptions ?? BatteryPanelOptions()
            if command == "battery left" { options.closeSide = .left }
            BatteryPanel.shared.open(options: options)
        case let add where add.hasPrefix("add "):
            // "add cpu", or "add saved:<id>" for a My Items entry: adds it to the end of the center, as a double-click in the library does.
            let editor = SettingsWindowController.shared
            let item = ItemCatalog.newItem(String(add.dropFirst(4)), align: "center", document: editor.document)
            editor.document.place(item, align: "center", at: .max)
            editor.session.selection = item.id
        case let tab where tab.hasPrefix("tab "):
            // "tab style" shows the editor's Style tab (item, style, behavior, advanced).
            UserDefaults.standard.set(String(tab.dropFirst(4)), forKey: "inspector.tab")
        case "dismiss":
            for case let item as PopoverBarItem in items {
                item.collapse()
            }
            TouchBarController.shared.restoreMainBar()
        default:
            NSLog("Stripe debug: unknown command \(command)")
        }
    }
}
