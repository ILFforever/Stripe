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
    /// Extra room before a center item that's a group or follows one, so groups
    /// keep the edges' spacing from their neighbors (as ScrollViewItem does).
    static func centerGap(before index: Int, in items: [EditorItem]) -> CGFloat {
        guard index > 0 else { return 0 }
        return items[index].type == "cluster" || items[index - 1].type == "cluster" ? spacing - centerSpacing : 0
    }
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
        // Items with moving parts (the Equalizer's bars) are retaken faster, alone, so they move smoothly.
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshLive() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private var liveTimer: Timer?
    /// The editor's items whose bar views have bars that are moving, from the last full refresh.
    private var liveViews: [UUID: NSView] = [:]

    /// Retakes just the pictures of items with moving parts.
    private func refreshLive() {
        guard !liveViews.isEmpty, NSEvent.pressedMouseButtons == 0, session.dragging == nil else { return }
        var updated = images
        for (id, view) in liveViews where images[id] != nil {
            if let image = ItemSnapshotModel.snapshot(of: view) { updated[id] = image }
        }
        images = updated
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
        var live: [UUID: NSView] = [:]
        for (item, identifier) in zip(document.items, identifiers) {
            guard let view = bar.items[identifier]?.view else {
                hidden.insert(item.id)
                continue
            }
            if let image = ItemSnapshotModel.snapshot(of: view) {
                images[item.id] = image
            }
            if ItemSnapshotModel.equalizers(in: view).contains(where: { $0.layer.isMoving }) { live[item.id] = view }
        }
        self.images = images
        self.hidden = hidden
        liveViews = live
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

    /// Names a layer laid over an item's view (the Equalizer's bars) that pictures
    /// draw themselves; see EqualizerLayer.
    static let liveOverlayName = "com.ilfforever.stripe.liveOverlay"

    /// `view` and everything in it.
    private static func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    /// The Equalizer bars laid over `view` or anything in it, with the view each sits on.
    static func equalizers(in view: NSView) -> [(layer: EqualizerLayer, host: NSView)] {
        allViews(in: view).flatMap { host in
            (host.layer?.sublayers ?? []).compactMap { ($0 as? EqualizerLayer).map { (layer: $0, host: host) } }
        }
    }

    static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        // cacheDisplay draws a layer laid over a view as it is at rest, without its
        // animation, so the bars are kept out of it and drawn as they are now. Hidden and
        // shown again in one transaction, so the real bar never sees the change.
        let bars = equalizers(in: view)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.layer.isHidden = true }
        view.cacheDisplay(in: bounds, to: rep)
        bars.forEach { $0.layer.isHidden = false }
        CATransaction.commit()
        if !bars.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) {
            let now = CACurrentMediaTime()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for (layer, host) in bars {
                var frame = host.convert(layer.frame, to: view)
                if view.isFlipped { frame.origin.y = bounds.height - frame.maxY }
                layer.drawStill(in: frame, at: now)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A picture of what a folder or popover opens into, at the bar's real size,
/// built from off-bar copies of its items (their contents aren't on the bar
/// until it opens).
final class ContainerPreviewModel: ObservableObject {
    @Published private(set) var image: NSImage?
    private var item: NSTouchBarItem?
    private var generation = 0

    func build(_ container: EditorItem) {
        stop()
        generation += 1
        let current = generation
        let identifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.containerPreview." + UUID().uuidString)
        guard let data = JSONValue.array([container.json]).pretty().data(using: .utf8),
              let definition = data.barItemDefinitions()?.first,
              let item = TouchBarController.shared.createItem(forIdentifier: identifier, definition: definition) else { return }
        let content: NSView?
        switch item {
        case let popover as PopoverBarItem: content = popover.makePreviewView()
        case let folder as GroupBarItem: content = folder.makePreviewView()
        case let group as ClusterBarItem: content = group.view // placed where it sits, below
        default: content = nil
        }
        guard let content = content else { tearDownItems([item]); return }
        self.item = item
        // A scroll view (a folder's center section) paints a gray background off
        // the Touch Bar; on it, the bar's black shows through.
        ContainerPreviewModel.clearScrollBackgrounds(in: content)

        // The bar's app region, measured from the bar when it's showing.
        let width = TouchBarController.shared.basicView?.view.window?.frame.width ?? 1004
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: ItemStyle.barHeight))
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(content)
        if item is ClusterBarItem {
            // A group is on the bar already: picture it alone, where it sits there.
            let x = ContainerPreviewModel.barPosition(of: container)
                ?? (container.align == "right" ? width - content.fittingSize.width : 0)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: x),
                content.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                content.topAnchor.constraint(equalTo: bar.topAnchor),
                content.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            ])
        }
        // In a window, never shown, so every view and layer draws as on the bar.
        let window = NSWindow(contentRect: bar.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black // the bar's own black, not the window's gray
        window.contentView = bar
        self.window = window
        bar.layoutSubtreeIfNeeded()
        image = ContainerPreviewModel.snapshot(of: bar)
        // Widgets fill in their first reading a moment later; then the copies stop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.generation == current else { return }
            bar.layoutSubtreeIfNeeded()
            self.image = ContainerPreviewModel.snapshot(of: bar)
            self.stop()
        }
    }

    func stop() {
        if let item = item { tearDownItems([item]) }
        item = nil
        window = nil
    }

    private var window: NSWindow?

    /// Where a top-level item starts on the real bar, from the bar's own view of
    /// it (the bar builds items in preset order; see ItemSnapshotModel).
    private static func barPosition(of item: EditorItem) -> CGFloat? {
        let bar = TouchBarController.shared
        guard let document = item.document, bar.currentPresetPath == document.path,
              bar.orderedIdentifiers.count == document.items.count,
              let index = document.items.firstIndex(where: { $0 === item }),
              let view = bar.items[bar.orderedIdentifiers[index]]?.view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil).minX
    }

    private static func clearScrollBackgrounds(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    /// Renders the layers too: keys Stripe draws itself are layer backgrounds,
    /// which drawing the views alone would leave out.
    private static func snapshot(of view: NSView) -> NSImage? {
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard size.width > 0, let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        view.display()
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
