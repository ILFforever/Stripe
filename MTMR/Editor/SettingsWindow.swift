//
//  SettingsWindow.swift
//  Stripe
//
//  The editor window's controller.
//

import SwiftUI

/// Owns the editor window. Closing it just hides it; the app keeps running.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var pressMonitor: Any?
    let document = PresetDocument(path: standardConfigPath)
    let session = EditorSession()
    private lazy var snapshots = ItemSnapshotModel(document: document, session: session)

    func show() {
        if window == nil {
            // Show the new items as soon as the bar has redrawn after a save.
            document.onSaved = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.snapshots.refresh() }
            }
            let view = SettingsView(document: document, session: session, snapshots: snapshots)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "\(Brand.name) Settings"
            // A unified title bar that the SwiftUI header draws into.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // No NSToolbar: it would sit over the header and swallow its clicks.
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("StripeSettings")
            window.delegate = self
            if !window.setFrameUsingName("StripeSettings") { window.center() }
            self.window = window
            // Select an item on the bar as soon as it's pressed. A SwiftUI gesture
            // would do this too, but it keeps the item from being dragged.
            pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self, event.window === self.window, let point = self.pointerInContent() else { return event }
                // Only items in the preset as it is now: reloading it (reopening this
                // window, undo) gives every item a new id, and the old ids' frames
                // would otherwise still claim the same spots.
                self.session.chipFrames = self.session.chipFrames.filter { self.document.find($0.key) != nil }
                self.session.zoneFrames = self.session.zoneFrames.filter { self.document.find($0.key) != nil }
                if let hit = self.session.chipFrames.first(where: { $0.value.contains(point) })?.key {
                    self.session.set(\.selection, hit)
                } else if self.session.barFrame.contains(point) {
                    // The bar's empty space: the bar itself.
                    self.session.set(\.barPanel, .background)
                }
                return event
            }
        } else {
            document.load() // pick up edits made elsewhere while the window was closed
        }
        snapshots.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The pointer in SwiftUI's global coordinates for this window (content view,
    /// top-left origin), the space `EditorSession.chipFrames` is recorded in.
    func pointerInContent() -> CGPoint? {
        guard let window = window, let content = window.contentView else { return nil }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: point.x, y: content.bounds.height - point.y)
    }

    func windowWillClose(_: Notification) {
        document.flushSave()
        snapshots.stop()
    }
}
