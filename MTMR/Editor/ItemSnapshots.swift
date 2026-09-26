//
//  ItemSnapshots.swift
//  Stripe
//
//  Live pictures of the real bar items for the editor's bar. The bar builds its
//  items in preset order, so the editor's Nth item is the bar's Nth item, as long
//  as the editor's file is the one on the bar and has no unsaved edits. When
//  those don't hold, the previous pictures stay and the rest fall back to drawn
//  chips.
//

import AppKit

/// The picture of the item being dragged from the library, kept apart from the
/// bar's pictures so only the views showing it redraw when it changes.
final class DragPreviewModel: ObservableObject {
    @Published fileprivate(set) var image: NSImage?
    fileprivate(set) var type: String?
}

/// The size of the real bar's app region (everything right of the Esc key), kept
/// apart from the pictures so the window's layout only redraws when it changes.
final class BarMetrics: ObservableObject {
    /// 1004pt on a 13" MacBook Pro with the Control Strip hidden; measured from
    /// the bar once it's showing.
    @Published fileprivate(set) var width: CGFloat = 1004
    static let height: CGFloat = 30
    /// Between items, and between each section.
    static let spacing: CGFloat = 8
    /// Between the center section's items.
    static let centerSpacing: CGFloat = 1
    /// The editor's black edge around the app region: room for the section and
    /// selection outlines.
    static let bezel: CGFloat = 7
}

final class ItemSnapshotModel: ObservableObject {
    @Published private(set) var images: [UUID: NSImage] = [:]
    /// Items the bar isn't showing right now, e.g. because of a "when" condition.
    @Published private(set) var hidden = Set<UUID>()

    /// The item being dragged from the library, drawn from a real, off-bar
    /// instance of it, so the bar can show exactly what will be added.
    let preview = DragPreviewModel()
    let metrics = BarMetrics()

    private let document: PresetDocument
    private let session: EditorSession
    private var timer: Timer?
    private var previewItem: NSTouchBarItem?
    /// When the mouse button was seen up during a drag.
    private var releasedDuringDrag: Date?

    init(document: PresetDocument, session: EditorSession) {
        self.document = document
        self.session = session
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // SwiftUI doesn't report a cancelled drag; notice it by the mouse staying
        // up. A real drop arrives a few hundred milliseconds after the release, so
        // allow for that before giving up on it.
        if session.dragging != nil, NSEvent.pressedMouseButtons == 0 {
            let released = releasedDuringDrag ?? Date()
            releasedDuringDrag = released
            if Date().timeIntervalSince(released) > 1 {
                session.endDrag(document)
                endPreview()
                releasedDuringDrag = nil
            }
        } else {
            releasedDuringDrag = nil
        }
        // Nothing is redrawn during a press or a drag: it costs frames mid-drag, and
        // redrawing an item as a press begins would cancel dragging it.
        guard NSEvent.pressedMouseButtons == 0, session.dragging == nil else { return }
        // Before a drag starts, the preview of the pointed-at library tile stays live.
        if previewItem != nil { snapshotPreview() }

        let bar = TouchBarController.shared
        if let width = bar.basicView?.view.window?.frame.width, width > 0, width != metrics.width {
            metrics.width = width
        }
        let identifiers = bar.orderedIdentifiers
        guard bar.currentPresetPath == document.path, !document.hasPendingSave,
              identifiers.count == document.items.count else { return }

        var images: [UUID: NSImage] = [:]
        var hidden = Set<UUID>()
        for (item, identifier) in zip(document.items, identifiers) {
            guard let view = bar.items[identifier]?.view else {
                hidden.insert(item.id)
                continue
            }
            if let image = ItemSnapshotModel.snapshot(of: view) {
                images[item.id] = image
            }
        }
        self.images = images
        self.hidden = hidden
    }

    // MARK: Library drag preview

    func beginPreview(of type: String) {
        guard preview.type != type else { return }
        endPreview()
        preview.type = type
        let editorItem = ItemCatalog.newItem(type, align: "center", document: document)
        let identifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.preview." + UUID().uuidString)
        guard let data = JSONValue.array([editorItem.json]).pretty().data(using: .utf8),
              let definition = data.barItemDefinitions()?.first,
              let item = TouchBarController.shared.createItem(forIdentifier: identifier, definition: definition),
              item.view != nil else { return }
        previewItem = item
        snapshotPreview()
        // Widgets fill in their first reading a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.snapshotPreview() }
    }

    func endPreview() {
        if let item = previewItem { tearDownItems([item]) }
        previewItem = nil
        preview.type = nil
        if preview.image != nil { preview.image = nil }
    }

    /// Shows the preview picture for a just-dropped item until the bar has built it.
    func adoptPreview(for id: UUID) {
        if let image = preview.image { images[id] = image }
    }

    private func snapshotPreview() {
        guard let view = previewItem?.view else { return }
        // Off the bar, the view needs the bar's dark look and a size of its own.
        view.appearance = NSAppearance(named: .darkAqua)
        let size = view.fittingSize
        view.setFrameSize(NSSize(width: max(size.width, 30), height: 30))
        view.layoutSubtreeIfNeeded()
        preview.image = ItemSnapshotModel.snapshot(of: view)
    }

    static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
