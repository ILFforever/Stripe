//
//  SettingsWindow.swift
//  Stripe
//
//  The editor window's controller.
//

import Combine
import SwiftUI

/// Owns the editor window. Closing it just hides it; the app keeps running. Stripe is
/// an agent app with no Dock icon, so while this window is open it becomes a regular
/// app (a Dock icon to find and come back to it, and a menu bar), and is an agent
/// again once it's closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var pressMonitor: Any?
    let document = PresetDocument(path: standardConfigPath)
    let session = EditorSession()
    private lazy var snapshots = ItemSnapshotModel(document: document, session: session)
    private var selectionWatch: AnyCancellable?

    /// The item on a deck's front card under the last press on the canvas, with its
    /// view on the bar: what a drag starting there picks up, rather than the whole deck.
    func deckItem(underPressIn deck: EditorItem) -> (item: EditorItem, view: NSView)? {
        let bar = TouchBarController.shared
        guard deck.type == "cards", let press = session.pressPoint, let chip = session.chipFrames[deck.id], chip.contains(press),
              bar.currentPresetPath == document.path, bar.orderedIdentifiers.count == document.items.count,
              let position = document.items.firstIndex(where: { $0 === deck }),
              let cards = bar.items[bar.orderedIdentifiers[position]] as? CardsBarItem,
              let hit = cards.item(atFraction: (press.x - chip.minX) / max(chip.width, 1)),
              let card = deck.children?[safe: hit.card], let item = card.children?[safe: hit.item] else { return nil }
        return (item, hit.view)
    }

    /// Ends the library's drag preview, for drops landing outside the bar canvas (a card in the inspector).
    func endLibraryPreview() { snapshots.endPreview() }

    /// Selecting a card, or an item on one, turns its deck on the bar to that card,
    /// so the canvas (a picture of the bar) shows the card being edited.
    private func showCard(holding id: UUID?) {
        guard let item = document.find(id) else { return }
        let chain = document.ancestors(of: item) + [item]
        guard let cardLevel = chain.firstIndex(where: { $0.type == "card" }), cardLevel == 1 else { return }
        let deck = chain[0], card = chain[1]
        let bar = TouchBarController.shared
        guard bar.currentPresetPath == document.path, bar.orderedIdentifiers.count == document.items.count,
              let position = document.items.firstIndex(where: { $0 === deck }),
              let cards = bar.items[bar.orderedIdentifiers[position]] as? CardsBarItem,
              let index = deck.children?.firstIndex(where: { $0 === card }) else { return }
        cards.show(card: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.snapshots.refresh() }
    }

    func show() {
        if window == nil {
            // Show the new items as soon as the bar has redrawn after a save.
            document.onSaved = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.snapshots.refresh() }
            }
            selectionWatch = session.$selection.removeDuplicates().sink { [weak self] id in self?.showCard(holding: id) }
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
                self.session.pressPoint = point
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
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
        NSApp.setActivationPolicy(.accessory)
    }
}
