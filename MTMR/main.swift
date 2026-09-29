//
//  main.swift
//  MTMR
//
//  Explicit entry point so the app doesn't need a storyboard (and therefore
//  doesn't need Xcode's ibtool to build). MTMR is an LSUIElement agent, so the
//  storyboard's main menu was never visible anyway.
//

import Cocoa

// Asset-catalog images are shipped as loose files when building without
// actool, which drops the catalog's "template" rendering flag. Restore it.
for name in ["StatusImage", "brightnessDown", "brightnessUp", "dark-mode-off", "dark-mode-on",
             "dnd-off", "ill_down", "ill_up", "nightShiftOff"] {
    NSImage(named: name)?.isTemplate = true
}

let app = NSApplication.shared

// A main menu is only shown while Settings is open (see SettingsWindowController),
// but its key equivalents route ⌘C/⌘V/⌘X/⌘A/⌘Z to text fields (e.g. in Settings)
// either way. The storyboard used to provide it.
let mainMenu = NSMenu()
// The application menu, shown while Settings is open and Stripe has a Dock icon.
let appItem = NSMenuItem()
let appMenu = NSMenu(title: Brand.name)
appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Hide \(Brand.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
mainMenu.addItem(appItem)
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
let windowItem = NSMenuItem()
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowItem.submenu = windowMenu
mainMenu.addItem(windowItem)
app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
