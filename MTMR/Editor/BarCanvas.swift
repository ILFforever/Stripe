//
//  BarCanvas.swift
//  Stripe
//
//  Drag-and-drop editing, like macOS's "Customize Touch Bar": a mock of the bar
//  with Left / Center / Right zones, and a library of every item type.
//
//  - Drag a library tile onto the bar to add it where it's dropped.
//  - Drag items along the bar to reorder them or move them between zones.
//  - Drag an item off the bar into the library to remove it.
//  - Drop a library tile or a bar item on a group to put it inside.
//
//  Drags carry "stripe:new:<type>" or "stripe:move:<uuid>" as plain text. The
//  item being dragged is also recorded in EditorSession when the drag starts,
//  so the bar can reorder live while hovering, before the drop.
//

import SwiftUI
import UniformTypeIdentifiers

extension EditorSession {
    /// Clears drag state and lets the document save what the drag changed.
    func endDrag(_ document: PresetDocument) {
        dragging = nil
        set(\.targetZone, nil)
        set(\.dropSlot, nil)
        document.holdsSaves = false
    }

    /// Whether to outline an item: the selection normally, but during a drag only
    /// the item being moved, so an earlier selection doesn't look like the target.
    func outlines(_ item: EditorItem) -> Bool {
        switch dragging {
        case let .move(id)?: return id == item.id
        case .new?: return false
        case nil: return selection == item.id
        }
    }
}

/// A position in one of the bar's sections.
struct DropSlot: Equatable {
    let align: String
    let index: Int
}

enum DragPayload {
    case new(type: String)
    case move(id: UUID)

    private static let prefix = "stripe:"

    var string: String {
        switch self {
        case let .new(type): return "\(DragPayload.prefix)new:\(type)"
        case let .move(id): return "\(DragPayload.prefix)move:\(id.uuidString)"
        }
    }

    init?(_ string: String) {
        guard string.hasPrefix(DragPayload.prefix) else { return nil }
        let body = string.dropFirst(DragPayload.prefix.count)
        if body.hasPrefix("new:") {
            self = .new(type: String(body.dropFirst(4)))
        } else if body.hasPrefix("move:"), let id = UUID(uuidString: String(body.dropFirst(5))) {
            self = .move(id: id)
        } else {
            return nil
        }
    }

    var provider: NSItemProvider { NSItemProvider(object: string as NSString) }

    /// The drop's payload: straight from the session when the drag started in this
    /// window, so the drop lands at once; otherwise read from the drag (slower).
    static func resolve(_ info: DropInfo, session: EditorSession, _ completion: @escaping (DragPayload) -> Void) -> Bool {
        if let known = session.dragging {
            completion(known)
            return true
        }
        return load(from: info, completion)
    }

    /// Reads a payload from a drop, then calls back on the main thread.
    static func load(from info: DropInfo, _ completion: @escaping (DragPayload) -> Void) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let payload = DragPayload(text) else { return }
            DispatchQueue.main.async { completion(payload) }
        }
        return true
    }
}

// MARK: - The bar

struct BarCanvas: View {
    @ObservedObject var document: PresetDocument
    @ObservedObject var session: EditorSession
    @ObservedObject var snapshots: ItemSnapshotModel

    private static let positions = [("left", "Left"), ("center", "Center"), ("right", "Right")]

    @ViewBuilder
    private func chipMenu(_ item: EditorItem) -> some View {
        Button("Edit") { session.selection = item.id }
        Button("Duplicate") { document.duplicate(item) }
        Button("Save to My Items…") { SavedItems.promptSave(item) }
        Menu("Move To") {
            ForEach(BarCanvas.positions, id: \.0) { align, title in
                Button(title) { withAnimation { document.place(item, align: align, at: .max) } }
                    .disabled(item.align == align)
            }
        }
        Divider()
        Button("Remove") {
            if session.selection == item.id { session.selection = nil }
            withAnimation { document.remove(item) }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            BarFrame(metrics: snapshots.metrics, bar: document.bar, selected: session.barPanel == .background,
                     onFrame: { session.barFrame = $0 }) {
                // Like the real bar, an empty side takes no room (and no gap), so
                // the rest sits where it will; it opens up during a drag to take drops.
                HStack(spacing: 0) {
                    if showsZone("left") {
                        zone("left")
                        Spacer().frame(width: BarMetrics.spacing)
                    }
                    zone("center").frame(maxWidth: .infinity)
                    if showsZone("right") {
                        Spacer().frame(width: BarMetrics.spacing)
                        zone("right")
                    }
                }
            }
            selectionActions
        }
    }

    /// A tab hanging from the selected item's outline, in the same blue and joined
    /// to it, with the same menu as right-clicking the item (Duplicate, Save to My
    /// Items, Move To, Remove), for people who wouldn't think to right-click.
    private var selectionActions: some View {
        GeometryReader { geometry in
            if session.dragging == nil,
               let id = session.selection, let item = document.items.first(where: { $0.id == id }),
               let chip = session.chipFrames[id] {
                let row = geometry.frame(in: .global)
                // From just inside the outline's bottom edge (drawn 2pt outside the item)
                // down into this row.
                let top = chip.maxY + 1 - row.minY
                // Just deep enough for the dots (2pt above, 12pt dots, 2pt below).
                let bottom = top + 16
                ItemActionsTab(help: "More for \(item.displayName): duplicate, save to My Items, move, remove") {
                    showMenu(for: item)
                }
                .frame(width: ItemActionsTab.width, height: bottom - top)
                .position(x: min(max(chip.midX - row.minX, 24), geometry.size.width - 24), y: (top + bottom) / 2)
                // A tab per item, so a new selection's tab drops down out of its
                // outline rather than sliding over from the last one.
                .id(id)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.12), value: session.selection)
    }

    /// The pill's menu: the same commands as right-clicking the item.
    private func showMenu(for item: EditorItem) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Duplicate") { document.duplicate(item) })
        menu.addItem(ClosureMenuItem("Save to My Items…") { SavedItems.promptSave(item) })
        let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        move.submenu = NSMenu()
        for (align, title) in BarCanvas.positions {
            let entry = ClosureMenuItem(title) { withAnimation { document.place(item, align: align, at: .max) } }
            entry.isEnabled = item.align != align
            move.submenu?.addItem(entry)
        }
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove") {
            if session.selection == item.id { session.selection = nil }
            withAnimation { document.remove(item) }
        })
        menu.autoenablesItems = false
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func showsZone(_ align: String) -> Bool {
        session.dragging != nil || !document.items(aligned: align).isEmpty
    }

    private func zone(_ align: String) -> some View {
        let items = document.items(aligned: align)
        let targeted = session.targetZone == align
        let slot = session.dropSlot?.align == align ? session.dropSlot?.index : nil
        let spacing = align == "center" ? BarMetrics.centerSpacing : BarMetrics.spacing
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                if items.isEmpty && slot == nil {
                    Text(align.capitalizedFirst)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 14)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if slot == index { dropPlaceholder }
                    BarChip(item: item, snapshot: snapshots.images[item.id],
                            isSelected: session.outlines(item) || session.targetZone == GroupDropDelegate.zone(item))
                        .opacity(snapshots.hidden.contains(item.id) ? 0.4 : 1)
                        .acceptsItems(item, align: align, document: document, session: session, snapshots: snapshots)
                        // Positions are reported as preferences, which SwiftUI recomputes
                        // on every layout (onAppear/onChange missed some).
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ChipFramesKey.self, value: [
                                item.id: ChipFrames(global: geometry.frame(in: .global),
                                                    zone: geometry.frame(in: .named(align))),
                            ])
                        })
                        .contextMenu { chipMenu(item) }
                        .onDrag {
                            session.set(\.selection, item.id)
                            session.dragging = .move(id: item.id)
                            document.holdsSaves = true
                            return DragPayload.move(id: item.id).provider
                        }
                        .padding(.leading, align == "center" ? BarMetrics.centerGap(before: index, in: items) : 0)
                }
                if let slot = slot, slot >= items.count { dropPlaceholder }
            }
            .frame(maxHeight: .infinity)
            // Room for the selection outline, which the scroll view would clip...
            .padding(BarChip.outlineRoom)
        }
        // ...taken back outside, so the items stay where they are on the real bar.
        .padding(-BarChip.outlineRoom)
        .coordinateSpace(name: align)
        .onPreferenceChange(ChipFramesKey.self) { frames in
            for (id, frame) in frames {
                session.chipFrames[id] = frame.global
                session.zoneFrames[id] = frame.zone
            }
        }
        .frame(minWidth: items.isEmpty ? 70 : nil)
        // Drawn just outside the section so it takes no room from the items, which
        // sit exactly where they will on the bar.
        .background(RoundedRectangle(cornerRadius: 7)
            // The item or gap inside carries the blue outline; the section just brightens.
            .strokeBorder(Color.white.opacity(targeted ? 0.5 : 0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .padding(-3))
        .onDrop(of: [.plainText], delegate: ZoneDropDelegate(document: document, session: session,
                                                             snapshots: snapshots, align: align))
        .fixedSize(horizontal: align != "center", vertical: false)
    }

    private var dropPlaceholder: some View {
        DropPlaceholder(preview: snapshots.preview)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

/// The bar at its real size: its contents get exactly the width and height of
/// the Touch Bar's app region, point for point, on a black bezel.
struct BarFrame<Content: View>: View {
    @ObservedObject var metrics: BarMetrics
    /// The bar's own settings, for its background.
    var bar: [String: JSONValue] = [:]
    /// Outlined when the bar itself is selected.
    var selected = false
    /// Where the bar is in the window, reported for selecting it by its empty space.
    var onFrame: (CGRect) -> Void = { _ in }
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: metrics.width, height: BarMetrics.height)
            .background(BarBackgroundFill(bar: bar))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: BarChip.outlineWidth)
                .padding(-BarChip.outlineGap - 1))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: BarFramePreference.self, value: geometry.frame(in: .global))
            })
            .onPreferenceChange(BarFramePreference.self, perform: onFrame)
            .padding(BarMetrics.bezel)
            .background(RoundedRectangle(cornerRadius: EditorStyle.barRadius).fill(Color.black))
            .frame(maxWidth: .infinity)
    }
}

private struct BarFramePreference: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Where a new item from the library will land, drawn as it will look.
struct DropPlaceholder: View {
    @ObservedObject var preview: DragPreviewModel

    var body: some View {
        Group {
            if let image = preview.image {
                Image(nsImage: image).frame(width: image.size.width, height: image.size.height)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.22)).frame(width: 60, height: 30)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(-2))
    }
}

/// The item as it looks on the bar: a live snapshot of the real item when there
/// is one, otherwise an approximation (icon, label, background).
struct BarChip: View {
    /// The selection outline (and the "•••" tab joined to it).
    static let outlineWidth: CGFloat = 3
    /// From the item's edge to the middle of the outline.
    static let outlineGap: CGFloat = 2
    /// How far the outline reaches outside the item.
    static let outlineRoom: CGFloat = 4

    @ObservedObject var item: EditorItem
    let snapshot: NSImage?
    let isSelected: Bool

    private var background: Color? {
        (item.fields["background"]?.string?.namedOrHexColor).map { Color(nsColor: $0) }
    }

    private var radius: CGFloat { CGFloat(item.cornerRadius) }

    /// Media keys and the like read best as icons; everything else gets a short
    /// label so similar icons (CPU, memory…) can be told apart.
    private var label: String? {
        if let title = item.fields["title"]?.string, !title.isEmpty { return title }
        return item.info.isIconOnly || item.isContainer ? nil : item.shortName
    }

    var body: some View {
        if item.isEmptyContainer {
            emptyGroup
        } else if let snapshot = snapshot {
            image(snapshot)
        } else if item.type == "cluster" {
            clusterApproximation
        } else {
            approximation
        }
    }

    /// Drawn just outside the item, rounded to follow its corners: the item's
    /// radius plus the gap, so the two curves run parallel.
    private var selectionOutline: some View {
        RoundedRectangle(cornerRadius: radius + BarChip.outlineGap)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: BarChip.outlineWidth)
            .padding(-BarChip.outlineGap)
    }

    private func image(_ snapshot: NSImage) -> some View {
            Image(nsImage: snapshot)
                .frame(width: snapshot.size.width, height: snapshot.size.height)
                .overlay(selectionOutline)
                .contentShape(Rectangle())
                .help(item.displayName)
    }

    /// A group, folder or popover with nothing in it yet: a place to drop items.
    /// It isn't shown on the real bar.
    private var emptyGroup: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
            Text("Drop items here")
        }
        .font(.system(size: 11))
        .foregroundColor(isSelected ? .white : .gray)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.7),
                          style: StrokeStyle(lineWidth: isSelected ? BarChip.outlineWidth : 1, dash: [3, 3])))
        .contentShape(Rectangle())
        .help("An empty \(item.info.name.lowercased()). Drag items from the library or the bar onto it.")
    }

    /// A cluster's items side by side on one background.
    private var clusterApproximation: some View {
        let children = item.children ?? []
        return HStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                if index > 0 && item.fields["dividers"]?.bool == true {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 14)
                }
                Image(systemName: child.displaySymbol)
                    .foregroundColor(.white)
                    .frame(minWidth: CGFloat(item.fields["itemWidth"]?.number ?? 30), minHeight: 30)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
        .frame(minWidth: 30, minHeight: 30)
        .background(RoundedRectangle(cornerRadius: radius)
            .fill(background ?? (item.fields["bordered"]?.bool == false ? Color.clear : Color(white: 0.22))))
        .overlay(selectionOutline)
        .contentShape(Rectangle())
        .help(item.displayName)
    }

    private var approximation: some View {
        HStack(spacing: 5) {
            Image(systemName: item.displaySymbol)
                .foregroundColor((item.fields["iconColor"]?.string?.namedOrHexColor).map { Color(nsColor: $0) } ?? .white)
            if let label = label {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110)
                    .foregroundColor((item.fields["textColor"]?.string?.namedOrHexColor).map { Color(nsColor: $0) } ?? .white)
            }
            if item.isContainer {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(.gray)
                    .help("Opens more items")
            }
            if item.fields["when"] != nil {
                Image(systemName: "eye").font(.system(size: 9)).foregroundColor(.gray)
                    .help("Only shows under some conditions")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(minWidth: 30)
        .background(RoundedRectangle(cornerRadius: radius)
            .fill(background ?? (item.fields["bordered"]?.bool == false ? Color.clear : Color(white: 0.22))))
        .overlay(selectionOutline)
        .contentShape(Rectangle())
        .help(item.displayName)
    }
}

struct ChipFrames: Equatable {
    let global: CGRect
    let zone: CGRect
}

struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [UUID: ChipFrames] = [:]
    static func reduce(value: inout [UUID: ChipFrames], nextValue: () -> [UUID: ChipFrames]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Adds a dropped library item where the bar made room for it.
private func addNewItem(_ type: String, align: String, at index: Int, document: PresetDocument,
                        session: EditorSession, snapshots: ItemSnapshotModel) {
    let item = ItemCatalog.newItem(type, align: align, document: document)
    snapshots.adoptPreview(for: item.id)
    withAnimation(.easeInOut(duration: 0.15)) {
        session.dropSlot = nil
        document.place(item, align: align, at: index)
    }
    snapshots.endPreview()
    session.selection = item.id
}

/// Dropping on a zone's empty space puts the item at the end of that zone.
struct ZoneDropDelegate: DropDelegate {
    let document: PresetDocument
    let session: EditorSession
    let snapshots: ItemSnapshotModel
    let align: String

    func dropEntered(info: DropInfo) {
        session.set(\.targetZone, align)
        reposition(at: info.location.x)
    }

    /// Where the dragged item goes is the number of items whose middle is left of
    /// the pointer. It settles rather than bouncing: after a move, the neighbour
    /// slides past the pointer in the direction that agrees with the new order.
    func reposition(at x: CGFloat) {
        session.dropTouched = Date()
        let section = document.items(aligned: align)
        func isLeft(_ item: EditorItem) -> Bool {
            guard let frame = session.zoneFrames[item.id] else { return false }
            return frame.midX < x
        }
        switch session.dragging {
        case let .move(id)?:
            guard let item = document.items.first(where: { $0.id == id }) else { return }
            let others = section.filter { $0 !== item }
            let desired = others.filter(isLeft).count
            // Already there: its index in the section counts the others before it.
            if item.align == align, section.firstIndex(where: { $0 === item }) == desired { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                document.place(item, align: align, at: desired)
            }
        case .new?:
            let slot = DropSlot(align: align, index: section.filter(isLeft).count)
            if session.dropSlot != slot {
                withAnimation(.easeInOut(duration: 0.15)) { session.dropSlot = slot }
            }
        case nil:
            break
        }
    }

    func dropExited(info _: DropInfo) {
        if session.targetZone == align { session.set(\.targetZone, nil) }
        // Entering an item inside the section also exits the section; only close
        // the gap if nothing claimed the drag right after (i.e. it left the bar).
        let exited = Date()
        DispatchQueue.main.async {
            // Letting go also exits; keep the gap open so the drop fills it seamlessly.
            guard NSEvent.pressedMouseButtons != 0 else { return }
            if session.dropTouched < exited, session.dropSlot?.align == align {
                withAnimation(.easeInOut(duration: 0.15)) { session.dropSlot = nil }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        reposition(at: info.location.x)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        session.set(\.targetZone, nil)
        let index = session.dropSlot?.align == align ? session.dropSlot?.index ?? .max : .max
        return DragPayload.resolve(info, session: session) { payload in
            switch payload {
            case let .new(type):
                addNewItem(type, align: align, at: index, document: document, session: session, snapshots: snapshots)
            case let .move(id):
                if let item = document.items.first(where: { $0.id == id }), item.align != align {
                    withAnimation { document.place(item, align: align, at: .max) }
                }
            }
            session.endDrag(document)
        }
    }
}

/// Dropping on a group, folder or popover puts the item inside it, at the end: a
/// new one from the library, or one moved from the bar. Its ends are the gaps
/// beside it, so items can still be placed next to it. Folders, popovers and
/// groups don't go inside each other.
struct GroupDropDelegate: DropDelegate {
    let group: EditorItem
    let document: PresetDocument
    let session: EditorSession
    let snapshots: ItemSnapshotModel
    /// The section of the bar the group is in.
    let align: String

    /// The session's targetZone while a drag is over this group.
    static func zone(_ group: EditorItem) -> String { "group:\(group.id)" }

    /// The bar item being moved in, if it can go inside.
    private var movingItem: EditorItem? {
        guard case let .move(id)? = session.dragging, id != group.id,
              let item = document.items.first(where: { $0.id == id }), !item.isContainer else { return nil }
        return item
    }

    private var accepts: Bool {
        switch session.dragging {
        case let .new(type)?: return !ItemCatalog.isContainer(type)
        case .move?: return movingItem != nil
        case nil: return false
        }
    }

    /// The section the group sits in: its ends, and anything that can't go
    /// inside, drop beside it instead.
    private var section: ZoneDropDelegate {
        ZoneDropDelegate(document: document, session: session, snapshots: snapshots, align: align)
    }

    /// Whether the pointer is over the middle of the group rather than one of its
    /// ends, which stand for the gaps either side of it.
    private func isInside(_ info: DropInfo) -> Bool {
        guard accepts else { return false }
        guard let width = session.zoneFrames[group.id]?.width else { return true }
        let end = min(16, width / 4)
        return info.location.x > end && info.location.x < width - end
    }

    /// The pointer in the section's coordinates, which the section places items by.
    private func sectionX(_ info: DropInfo) -> CGFloat {
        (session.zoneFrames[group.id]?.minX ?? 0) + info.location.x
    }

    func validateDrop(info _: DropInfo) -> Bool { session.dragging != nil }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropExited(info _: DropInfo) {
        if session.targetZone == GroupDropDelegate.zone(group) { session.set(\.targetZone, nil) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isInside(info) {
            session.dropTouched = Date()
            session.set(\.targetZone, GroupDropDelegate.zone(group))
            // The group is the target now, not a gap beside it.
            if session.dropSlot != nil {
                withAnimation(.easeInOut(duration: 0.15)) { session.dropSlot = nil }
            }
        } else {
            session.set(\.targetZone, align)
            section.reposition(at: sectionX(info))
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isInside(info) else { return section.performDrop(info: info) }
        session.set(\.targetZone, nil)
        switch session.dragging {
        case let .new(type)?:
            let item = ItemCatalog.newItem(type, align: "center", document: document)
            withAnimation { document.add(item, to: group) }
            snapshots.endPreview()
        case .move?:
            guard let item = movingItem else { return false }
            withAnimation {
                document.remove(item)
                item.fields["align"] = nil // items inside a group don't have a position of their own
                document.add(item, to: group)
            }
        case nil:
            return false
        }
        session.selection = group.id
        session.endDrag(document)
        return true
    }
}

extension View {
    /// Makes a group, folder or popover on the bar accept drops; other items are
    /// left as they are.
    @ViewBuilder
    func acceptsItems(_ item: EditorItem, align: String, document: PresetDocument, session: EditorSession,
                      snapshots: ItemSnapshotModel) -> some View {
        if ["cluster", "group", "popover"].contains(item.type) {
            onDrop(of: [.plainText], delegate: GroupDropDelegate(group: item, document: document,
                                                                 session: session, snapshots: snapshots,
                                                                 align: align))
        } else {
            self
        }
    }
}

// MARK: - The library

struct ItemLibrary: View {
    /// Not observed: the library only adds to it, and redrawing every tile on
    /// each edit (including each reorder during a drag) is wasted work.
    let document: PresetDocument
    @ObservedObject var session: EditorSession
    let snapshots: ItemSnapshotModel
    @ObservedObject private var saved = SavedItems.shared

    var body: some View {
        let targeted = session.targetZone == "library"
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !savedMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(SavedItems.category)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.leading, 2)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                                ForEach(savedMatches) { entry in
                                    tile(savedInfo(entry))
                                        .contextMenu {
                                            Button("Rename…") { SavedItems.promptRename(entry) }
                                            Button("Delete…") { SavedItems.confirmDelete(entry) }
                                        }
                                }
                            }
                        }
                    }
                    if matches.isEmpty && savedMatches.isEmpty {
                        Text("No items match \u{201C}\(session.search)\u{201D}")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(ItemCatalog.categories.filter { category in matches.contains { $0.category == category } },
                            id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.leading, 2)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                                ForEach(matches.filter { $0.category == category }, id: \.type) { info in
                                    tile(info)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            Divider()
            Label(targeted ? "Release to remove" : "Drag onto the bar to add, or double-click",
                  systemImage: targeted ? "trash" : "hand.draw")
                .font(.system(size: 11))
                .foregroundColor(targeted ? .red : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .background(targeted ? Color.red.opacity(0.08) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.red.opacity(targeted ? 0.6 : 0), lineWidth: 2)
            .padding(4))
        .onDrop(of: [.plainText], delegate: LibraryDropDelegate(document: document, session: session))
    }

    /// A library tile: drag it onto the bar, or double-click to add it.
    private func tile(_ info: ItemTypeInfo) -> some View {
        LibraryTile(info: info, preview: snapshots.preview, onHover: { hovering in
            hoverChanged(info.type, hovering)
        })
        .onDrag({
            session.dragging = .new(type: info.type)
            document.holdsSaves = true
            snapshots.beginPreview(of: info.type)
            return DragPayload.new(type: info.type).provider
        }, preview: {
            LibraryDragImage(info: info, preview: snapshots.preview)
        })
        .onTapGesture(count: 2) { add(info.type) }
    }

    /// A saved item as a library tile.
    private func savedInfo(_ entry: SavedItems.Entry) -> ItemTypeInfo {
        ItemTypeInfo(type: entry.libraryType, name: entry.name, symbol: entry.symbol, category: SavedItems.category,
                     defaults: [:], fields: [])
    }

    /// Saved items whose name or type contains the search text.
    private var savedMatches: [SavedItems.Entry] {
        let query = session.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return saved.entries }
        return saved.entries.filter { entry in
            [entry.name, entry.info.name].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Pointing at a tile builds its preview, so a drag from it shows the item's
    /// real look from the start; it's dropped again if no drag follows.
    private func hoverChanged(_ type: String, _ hovering: Bool) {
        let delay = hovering ? 0.12 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if hovering {
                snapshots.beginPreview(of: type)
            } else if session.dragging == nil, snapshots.preview.type == type {
                snapshots.endPreview()
            }
        }
    }

    /// Item types whose name, type or category contain the search text.
    private var matches: [ItemTypeInfo] {
        let query = session.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ItemCatalog.all }
        return ItemCatalog.all.filter { info in
            [info.name, info.type, info.category].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Double-clicking a tile adds it to the end of the center section.
    private func add(_ type: String) {
        let item = ItemCatalog.newItem(type, align: "center", document: document)
        snapshots.beginPreview(of: type)
        snapshots.adoptPreview(for: item.id)
        snapshots.endPreview()
        withAnimation { document.place(item, align: "center", at: .max) }
        session.selection = item.id
    }
}

/// What follows the pointer while dragging from the library: the item as it will
/// look on the bar, or its tile until that picture is ready.
struct LibraryDragImage: View {
    let info: ItemTypeInfo
    @ObservedObject var preview: DragPreviewModel

    var body: some View {
        if preview.type == info.type, let image = preview.image {
            Image(nsImage: image)
                .frame(width: image.size.width, height: image.size.height)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
        } else {
            Image(systemName: info.symbol)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 44, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.22)))
        }
    }
}

struct LibraryTile: View {
    let info: ItemTypeInfo
    @ObservedObject var preview: DragPreviewModel
    let onHover: (Bool) -> Void
    private let hovering = State(initialValue: false)

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: info.symbol)
                .font(.system(size: 17))
                .frame(height: 20)
            Text(info.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(hovering.wrappedValue ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering.wrappedValue = inside
            onHover(inside)
        }
        .help("Drag onto the bar, or double-click to add")
    }
}

/// Items dragged from the bar into the library are removed.
struct LibraryDropDelegate: DropDelegate {
    let document: PresetDocument
    let session: EditorSession

    func validateDrop(info _: DropInfo) -> Bool {
        if case .move? = session.dragging { return true }
        return false
    }

    func dropEntered(info _: DropInfo) {
        if case .move? = session.dragging { session.set(\.targetZone, "library") }
    }

    func dropExited(info _: DropInfo) {
        if session.targetZone == "library" { session.set(\.targetZone, nil) }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        session.set(\.targetZone, nil)
        return DragPayload.resolve(info, session: session) { payload in
            if case let .move(id) = payload, let item = document.find(id) {
                if session.selection == id { session.selection = nil }
                withAnimation { document.remove(item) }
            }
            session.endDrag(document)
        }
    }
}

/// The "•••" tab under the selected item: the selection outline's blue, with
/// small inward curves where it meets the outline, so the two read as one shape.
struct ItemActionsTab: View {
    static let width: CGFloat = 38
    let help: String
    let action: () -> Void
    private let hovering = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                TabShape(flare: 4, radius: 7)
                    .fill(Color.accentColor.opacity(hovering.wrappedValue ? 1 : 0.92))
                // Right under the outline, so it reads as part of the selection.
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(height: 12)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering.wrappedValue = inside }
        }
        .help(help)
    }
}

/// A tab hanging from a line: square top edge that flares out to meet the line,
/// rounded bottom.
struct TabShape: Shape {
    let flare: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let f = flare, r = min(radius, (rect.width - 2 * flare) / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
