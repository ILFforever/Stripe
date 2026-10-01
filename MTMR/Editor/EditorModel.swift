//
//  EditorModel.swift
//  Stripe
//
//  The editor's document: a preset file as a tree of editable items. Every
//  change is saved (debounced) and the bar reloads, so edits show up live.
//

import AppKit
import Combine
import SwiftUI

/// One item in a preset. `fields` is the item's raw JSON object minus "items";
/// a group's or popover's children live in `children`.
final class EditorItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var fields: [String: JSONValue]
    @Published var children: [EditorItem]?
    weak var document: PresetDocument?

    init(fields: [String: JSONValue], document: PresetDocument?) {
        var fields = fields
        let childValues = fields.removeValue(forKey: "items")?.array
        self.fields = fields
        self.document = document
        children = childValues?.compactMap { $0.object }.map { EditorItem(fields: $0, document: document) }
    }

    var type: String { fields["type"]?.string ?? "unknown" }
    var info: ItemTypeInfo { ItemCatalog.info(for: type) }
    var isContainer: Bool { children != nil }
    /// A group, folder or popover with nothing in it: hidden on the real bar, and
    /// a place to drop items in the editor.
    var isEmptyContainer: Bool {
        ["cluster", "group", "popover"].contains(type) && (children?.isEmpty ?? true)
    }

    /// Drawn Stripe's way (see StripeKeys) rather than MTMR's.
    var usesStripeLook: Bool { fields["theme"]?.string != "mtmr" }

    /// Drawn without a key unless it's given one, in the look it has (see StripeKeys).
    var borderlessByDefault: Bool {
        if usesStripeLook {
            if StripeKeys.keyedToggles.contains(type) { return false }
            if type == "cpu" || StripeKeys.bareReadouts.contains(type) { return true }
            // Now Playing: Two lines, Progress and the Mini player sit on a key; the others don't.
            if type == "music" { return !["lines", "progress", "player"].contains(fields["design"]?.string ?? "lines") }
        }
        return info.borderlessByDefault
    }

    /// The corner rounding it has with nothing set: Stripe's text buttons are pills.
    var defaultCornerRadius: Double {
        usesStripeLook && StripeKeys.pillTypes.contains(type) ? Double(StripeKeys.pillRadius) : 6
    }

    /// The rounding it's drawn with.
    var cornerRadius: Double {
        if fields["style"]?.string == "pill" { return Double(ItemStyle.barHeight / 2) }
        return fields["cornerRadius"]?.number ?? defaultCornerRadius
    }

    var align: String {
        get { fields["align"]?.string ?? (type == "escape" ? "left" : "center") }
        set { self[string: "align"] = (newValue == "center" && type != "escape") ? nil : newValue }
    }

    /// What the sidebar shows: the title if there is one; for scripts, what they
    /// run (e.g. "status.sh ram"); otherwise the type's name.
    var displayName: String {
        if let title = fields["title"]?.string, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let script = fields[path: "source.inline"]?.string ?? fields[path: "source.filePath"]?.string {
            let firstLine = script.split(separator: "\n").first.map(String.init) ?? script
            let words = firstLine.split(separator: " ").map { ($0 as NSString).lastPathComponent }
            let summary = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !summary.isEmpty { return summary.count > 32 ? String(summary.prefix(31)) + "…" : summary }
        }
        return info.name
    }

    var displaySymbol: String { fields["symbol"]?.string ?? info.symbol }

    /// A short label for the bar canvas: the title, a script's last word
    /// ("status.sh ram" → "ram"), or the type's name.
    var shortName: String {
        if let title = fields["title"]?.string, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if fields[path: "source.inline"] != nil || fields[path: "source.filePath"] != nil,
           let last = displayName.split(separator: " ").last {
            return String(last)
        }
        return info.name
    }

    var json: JSONValue {
        var result = fields
        if let children = children {
            result["items"] = .array(children.map { $0.json })
        }
        return .object(result)
    }

    // Typed accessors for bindings. Setting nil/"" removes the key, so the
    // saved JSON only contains what the user actually set.

    subscript(string path: String) -> String? {
        get { fields[path: path]?.string }
        set {
            fields[path: path] = (newValue?.isEmpty ?? true) ? nil : .string(newValue!)
            changed()
        }
    }

    subscript(number path: String) -> Double? {
        get { fields[path: path]?.number }
        set {
            fields[path: path] = newValue.map { .number($0) }
            changed()
        }
    }

    subscript(bool path: String) -> Bool? {
        get { fields[path: path]?.bool }
        set {
            fields[path: path] = newValue.map { .bool($0) }
            changed()
        }
    }

    func setRaw(_ path: String, _ value: JSONValue?) {
        fields[path: path] = value
        changed()
    }

    func replaceAll(with json: [String: JSONValue]) {
        var json = json
        let childValues = json.removeValue(forKey: "items")?.array
        fields = json
        if childValues != nil || children != nil {
            children = childValues?.compactMap { $0.object }.map { EditorItem(fields: $0, document: document) } ?? []
        }
        changed()
    }

    func changed() {
        objectWillChange.send()
        document?.scheduleSave()
    }
}

final class PresetDocument: ObservableObject {
    @Published private(set) var path: String
    @Published var items: [EditorItem] = []
    /// The bar's own settings (background, glass keys): the preset's "bar".
    @Published private(set) var bar: [String: JSONValue] = [:]
    @Published var loadError: String?
    @Published var lastSaved: Date?

    /// Called after each save, once the bar has reloaded.
    var onSaved: (() -> Void)?

    private var saveWork: DispatchWorkItem?
    private var backedUpPaths = Set<String>()

    // Undo history: the preset's text after each save.
    private var savedText: String?
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(path: String) {
        self.path = path
        load()
    }

    var displayName: String {
        if path == standardConfigPath { return "All apps" }
        let bundleId = (path as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
        return PresetDocument.appName(for: bundleId) ?? bundleId
    }

    static func appName(for bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func open(path: String) {
        flushSave()
        self.path = path
        undoStack = []
        redoStack = []
        load()
    }

    func load() {
        loadError = nil
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            items = []
            bar = [:]
            return
        }
        do {
            read(try JSONValue.parse(text))
            savedText = serialized
        } catch {
            items = []
            loadError = "Couldn't read \((path as NSString).lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Structure edits

    func items(aligned align: String) -> [EditorItem] {
        return items.filter { $0.align == align }
    }

    func add(_ item: EditorItem, to parent: EditorItem?) {
        if let parent = parent {
            parent.children = (parent.children ?? []) + [item]
            parent.changed()
        } else {
            items.append(item)
            scheduleSave()
        }
    }

    func remove(_ item: EditorItem) {
        if let index = items.firstIndex(where: { $0 === item }) {
            items.remove(at: index)
        } else {
            for container in allContainers() {
                if let index = container.children?.firstIndex(where: { $0 === item }) {
                    container.children?.remove(at: index)
                    container.objectWillChange.send()
                }
            }
        }
        scheduleSave()
    }

    func duplicate(_ item: EditorItem) {
        guard let json = item.json.object else { return }
        let copy = EditorItem(fields: json, document: self)
        if let index = items.firstIndex(where: { $0 === item }) {
            items.insert(copy, at: index + 1)
        } else if let container = allContainers().first(where: { $0.children?.contains { $0 === item } ?? false }),
                  let index = container.children?.firstIndex(where: { $0 === item }) {
            container.children?.insert(copy, at: index + 1)
            container.objectWillChange.send()
        }
        scheduleSave()
    }

    /// Reorders within one alignment section; offsets are relative to that section.
    func move(inSection align: String, from source: IndexSet, to destination: Int) {
        var section = items(aligned: align)
        section.move(fromOffsets: source, toOffset: destination)
        var iterator = section.makeIterator()
        items = items.map { $0.align == align ? iterator.next()! : $0 }
        scheduleSave()
    }

    /// Puts a top-level item at `index` within a position's section, moving it
    /// there if it's already on the bar. Used by drag and drop on the bar canvas.
    func place(_ item: EditorItem, align: String, at index: Int) {
        // Built on a copy and assigned once, so observers see one change, not three.
        var list = items
        list.removeAll { $0 === item }
        if item.align != align { item.align = align }
        let section = list.filter { $0.align == align }
        if index < section.count, let target = list.firstIndex(where: { $0 === section[index] }) {
            list.insert(item, at: target)
        } else if let last = section.last, let target = list.firstIndex(where: { $0 === last }) {
            list.insert(item, at: target + 1)
        } else {
            list.append(item)
        }
        items = list
        scheduleSave()
    }

    func move(in container: EditorItem, from source: IndexSet, to destination: Int) {
        container.children?.move(fromOffsets: source, toOffset: destination)
        container.changed()
    }

    func find(_ id: UUID?) -> EditorItem? {
        guard let id = id else { return nil }
        func search(_ list: [EditorItem]) -> EditorItem? {
            for item in list {
                if item.id == id { return item }
                if let found = search(item.children ?? []) { return found }
            }
            return nil
        }
        return search(items)
    }

    /// The folder, group or popover an item is inside, if any.
    func parent(of item: EditorItem) -> EditorItem? {
        return allContainers().first { $0.children?.contains { $0 === item } ?? false }
    }

    /// The containers an item is inside, outermost first.
    func ancestors(of item: EditorItem) -> [EditorItem] {
        var chain: [EditorItem] = []
        var current = item
        while let parent = parent(of: current) {
            chain.insert(parent, at: 0)
            current = parent
        }
        return chain
    }

    private func allContainers() -> [EditorItem] {
        func collect(_ list: [EditorItem]) -> [EditorItem] {
            return list.filter { $0.isContainer } + list.flatMap { collect($0.children ?? []) }
        }
        return collect(items)
    }

    // MARK: Saving

    func scheduleSave(after delay: TimeInterval = 0.5) {
        objectWillChange.send()
        if holdsSaves {
            needsSave = true
            return
        }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Edits the bar hasn't loaded yet.
    var hasPendingSave: Bool { needsSave || (saveWork.map { !$0.isCancelled } ?? false) }

    /// While true (during a drag on the bar), edits wait until the drop instead of
    /// saving, so the real bar doesn't reload under the pointer on every hover.
    var holdsSaves = false {
        didSet {
            if !holdsSaves, needsSave {
                needsSave = false
                // Soon after the drop, once the editor has drawn the result.
                scheduleSave(after: 0.1)
            }
        }
    }
    private var needsSave = false

    func flushSave() {
        if let work = saveWork, !work.isCancelled {
            work.cancel()
            save()
        }
    }

    /// Always a Stripe document; a plain list (MTMR's format) is read, and
    /// becomes a document the next time it's saved.
    private var serialized: String {
        var root: [String: JSONValue] = ["stripe": .number(1), "items": .array(items.map { $0.json })]
        if !bar.isEmpty { root["bar"] = .object(bar) }
        return JSONValue.object(root).pretty() + "\n"
    }

    private func read(_ root: JSONValue) {
        let list = root.array ?? root.object?["items"]?.array ?? []
        bar = root.object?["bar"]?.object ?? [:]
        items = list.compactMap { $0.object }.map { EditorItem(fields: $0, document: self) }
    }

    /// Sets one of the bar's settings, e.g. "background.gradient" or "glassKeys".
    func setBar(_ path: String, _ value: JSONValue?) {
        var updated = bar
        updated[path: path] = value
        guard updated != bar else { return }
        bar = updated
        scheduleSave()
    }

    /// Replaces the bar's background with another kind (or none).
    func setBarBackground(_ background: [String: JSONValue]?) {
        var updated = bar
        updated["background"] = background.map { .object($0) }
        guard updated != bar else { return }
        bar = updated
        scheduleSave()
    }

    func undo() {
        flushSave()
        guard let previous = undoStack.popLast(), let current = savedText else { return }
        redoStack.append(current)
        restore(previous)
    }

    func redo() {
        flushSave()
        guard let next = redoStack.popLast(), let current = savedText else { return }
        undoStack.append(current)
        restore(next)
    }

    private func restore(_ text: String) {
        guard let root = try? JSONValue.parse(text) else { return }
        read(root)
        write(text)
    }

    private func save() {
        saveWork = nil
        let text = serialized
        guard text != savedText else { return }
        if let previous = savedText {
            undoStack.append(previous)
            redoStack = []
        }
        write(text)
    }

    private func write(_ text: String) {
        backUpOnce()
        savedText = text
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            // Not atomic on purpose: an atomic write replaces the file, which would
            // detach the file watcher that reloads the bar on external edits.
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            lastSaved = Date()
            TouchBarController.shared.reloadAfterEdit()
            onSaved?()
        } catch {
            loadError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Saving rewrites the file without comments, so keep the original once.
    private func backUpOnce() {
        guard !backedUpPaths.contains(path), FileManager.default.fileExists(atPath: path) else { return }
        backedUpPaths.insert(path)
        let backup = path + ".bak"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.copyItem(atPath: path, toPath: backup)
    }
}

// MARK: - Item catalog

enum FieldKind {
    case text(placeholder: String)
    case multiline
    case number(placeholder: String)
    case toggle(default: Bool)
    case choice([String])
}

struct FieldSpec: Identifiable {
    let path: String
    let label: String
    let kind: FieldKind
    var id: String { path }
}

struct ItemTypeInfo {
    let type: String
    let name: String
    let symbol: String
    let category: String
    let defaults: [String: JSONValue]
    let fields: [FieldSpec]
    /// A ready-made item the library adds whole (e.g. brightness down and up in
    /// a group); its "type" is the item's real type.
    var template: [String: JSONValue]? = nil
    var isContainer: Bool { ["group", "popover", "cluster"].contains(template?["type"]?.string ?? type) }
    /// Drawn without a key unless the preset asks for one ("bordered": true).
    var borderlessByDefault: Bool {
        ["timeButton", "music", "dnd", "nightShift", "darkMode", "appleScriptTitledButton"].contains(type)
    }

    // What the inspector offers for this type, so it only shows controls that do something.

    /// Swipe gestures aren't drawn on the bar.
    var isVisibleOnBar: Bool { type != "swipe" }
    /// Buttons (and popovers, which are buttons) take the full set of styling options.
    /// Buttons (popovers and folders are buttons too). Dock and Up Next are scrolling strips.
    var supportsButtonStyling: Bool { !["cluster", "volume", "brightness", "swipe", "dock", "upnext"].contains(type) }
    /// Clusters take a background and shape for the key their items share.
    var supportsBackground: Bool { supportsButtonStyling || type == "cluster" }
    var supportsIcon: Bool { supportsButtonStyling }
    var supportsActions: Bool { !isContainer && !["volume", "brightness", "swipe", "dock", "upnext"].contains(type) }
    /// The built-in designs the Style tab offers for this type, and the preset
    /// key that picks one. MTMR's classic look is one of them where it differs.
    var designs: (key: String, fallback: String, options: [(id: String, name: String, help: String)])? {
        if type == "performance" {
            return ("design", PerformanceBarItem.Design.chip.rawValue, [
                ("chip", "Chip", "A chip icon, and each figure in its graph color"),
                ("minimal", "Minimal", "Small CPU and GPU labels beside bold figures"),
                ("graph", "Graph", "A thin meter beside each figure"),
            ])
        }
        if type == "music" {
            return ("design", MusicBarItem.Design.lines.rawValue, [
                ("lines", "Two lines", "Artwork, and the title over the artist and how far in it is"),
                ("progress", "Progress", "A thin bar under the title fills with the track"),
                ("equalizer", "Equalizer", "Bars that move while something plays"),
                ("player", "Mini player", "Previous, play/pause and next on the same key"),
                ("ring", "Ring", "Round artwork in a ring that fills with the track"),
            ])
        }
        if type == "pomodoro" {
            return ("design", PomodoroBarItem.Design.icon.rawValue, [
                ("icon", "Icon", "A timer icon; while running, a ring and the time left"),
                ("ready", "Ready time", "An empty ring and the focus length, so you see what a tap starts"),
                ("stacked", "Stacked", "What a tap and a hold start, on two lines; while running, when it ends"),
                ("pill", "Start pill", "A red Focus button; while running, it fills as the time passes"),
            ])
        }
        guard let classic = mtmrLook else { return nil }
        return ("theme", "stripe", [("stripe", "Stripe", "Stripe's look"), ("mtmr", "MTMR classic", classic)])
    }

    /// Which performance page holding it opens, if any.
    var performancePage: PerformancePanelOptions.Kind? {
        switch type {
        case "cpu": return .cpu
        case "gpu": return .gpu
        case "performance": return .unified
        default: return nil
        }
    }

    /// What the MTMR look changes for this type, if it has one ("theme": "mtmr").
    var mtmrLook: String? {
        switch type {
        case "battery": return "Text, like ⚡️64% with the time remaining raised beside it"
        case "play": return "A static play/pause icon"
        case "mute": return "A static mute icon"
        case "volume", "brightness": return "A plain slider, without the panel and end icons"
        case "escape": return "Regular-weight “esc”"
        case "delete": return "“del” as text"
        case "brightnessDown", "brightnessUp", "illuminationDown", "illuminationUp":
            return "MTMR's own icon, on a key of its own"
        case "staticButton": return "A standard key with regular-weight text"
        case "appleScriptTitledButton": return "A standard key with regular text; shows ⏳ until its first value"
        case "shellScriptTitledButton", "cpu", "currency", "weather", "yandexWeather",
             "inputsource", "music", "network":
            return "Shows ⏳ until its first value, instead of fading in"
        default: return nil
        }
    }

    /// Brightness and volume keys, which keep stepping while held.
    var repeatsWhileHeld: Bool { ["brightnessUp", "brightnessDown", "volumeUp", "volumeDown"].contains(type) }
    /// Volume and brightness sliders, which tick as they're dragged.
    var isSlider: Bool { type == "volume" || type == "brightness" }
    /// What "active" means for items that know their own on/off state.
    var builtInActiveState: String? {
        switch type {
        case "dnd": return "Do Not Disturb is on"
        case "nightShift": return "Night Shift is on"
        case "darkMode": return "Dark Mode is on"
        case "mute": return "the sound is muted"
        case "play": return "something is playing"
        case "pomodoro": return "a timer is running"
        default: return nil
        }
    }
    /// Media keys and similar read best as icons alone (on the bar canvas too).
    var isIconOnly: Bool { category == "Media" || category == "Keys" || type == "close" }
}

enum ItemCatalog {
    static let categories = ["Buttons", "Keys", "Media", "Status", "System", "Sliders", "Containers", "Other"]

    static let all: [ItemTypeInfo] = [
        // Buttons
        ItemTypeInfo(type: "staticButton", name: "Button", symbol: "rectangle.fill", category: "Buttons",
                     defaults: ["title": .string("Button")],
                     fields: [FieldSpec(path: "title", label: "Title", kind: .text(placeholder: "Button"))]),
        ItemTypeInfo(type: "shellScriptTitledButton", name: "Shell Script", symbol: "terminal", category: "Buttons",
                     defaults: ["source": .object(["inline": .string("date +%H:%M:%S")]), "refreshInterval": .number(5)],
                     fields: [FieldSpec(path: "source.inline", label: "Script (output becomes the title)", kind: .multiline),
                              FieldSpec(path: "source.filePath", label: "…or script file", kind: .text(placeholder: "~/bin/status.sh")),
                              FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "1800"))]),
        ItemTypeInfo(type: "appleScriptTitledButton", name: "AppleScript", symbol: "applescript", category: "Buttons",
                     defaults: ["source": .object(["inline": .string("return \"Hello\"")]), "refreshInterval": .number(30)],
                     fields: [FieldSpec(path: "source.inline", label: "AppleScript (result becomes the title)", kind: .multiline),
                              FieldSpec(path: "source.filePath", label: "…or script file", kind: .text(placeholder: "~/scripts/title.scpt")),
                              FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "1800"))]),

        // Keys
        simple("escape", "Escape", "escape", "Keys"),
        simple("delete", "Delete", "delete.left", "Keys"),
        // Each ready-made pair, then its keys on their own, down before up.
        pair("brightness", "Brightness", "sun.max", down: "brightnessDown", up: "brightnessUp"),
        simple("brightnessDown", "Brightness Down", "sun.min", "Keys"),
        simple("brightnessUp", "Brightness Up", "sun.max", "Keys"),
        pair("keyboardLight", "Keyboard Light", "light.max", down: "illuminationDown", up: "illuminationUp"),
        simple("illuminationDown", "Keyboard Light Down", "light.min", "Keys"),
        simple("illuminationUp", "Keyboard Light Up", "light.max", "Keys"),

        // Media
        // The ready-made groups first, then each key on its own.
        group("media", "Media Controls", "playpause.fill", ["previous", "play", "next"], category: "Media"),
        pair("volume", "Volume", "speaker.wave.2.fill", down: "volumeDown", up: "volumeUp", category: "Media"),
        simple("previous", "Previous", "backward.fill", "Media"),
        ItemTypeInfo(type: "play", name: "Play / Pause", symbol: "playpause.fill", category: "Media", defaults: [:],
                     fields: [FieldSpec(path: "litWhilePlaying", label: "Lit while playing", kind: .choice(["pause", "play"]))]),
        simple("next", "Next", "forward.fill", "Media"),
        simple("volumeDown", "Volume Down", "speaker.wave.1", "Media"),
        simple("volumeUp", "Volume Up", "speaker.wave.3", "Media"),
        simple("mute", "Mute", "speaker.slash", "Media"),
        ItemTypeInfo(type: "music", name: "Now Playing", symbol: "music.note", category: "Media", defaults: [:],
                     fields: [FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "5")),
                              FieldSpec(path: "disableMarquee", label: "Disable scrolling text", kind: .toggle(default: false))]),

        // Status
        ItemTypeInfo(type: "timeButton", name: "Clock", symbol: "clock", category: "Status", defaults: ["formatTemplate": .string("HH:mm")],
                     fields: [FieldSpec(path: "formatTemplate", label: "Format", kind: .text(placeholder: "HH:mm")),
                              FieldSpec(path: "timeZone", label: "Time zone", kind: .text(placeholder: "e.g. UTC or Europe/London")),
                              FieldSpec(path: "locale", label: "Locale", kind: .text(placeholder: "e.g. en_GB"))]),
        ItemTypeInfo(type: "cpu", name: "CPU", symbol: "cpu", category: "Status", defaults: ["refreshInterval": .number(3)],
                     fields: [FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "5"))]),
        ItemTypeInfo(type: "gpu", name: "GPU", symbol: "cube", category: "Status", defaults: [:],
                     fields: [FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "2"))]),
        ItemTypeInfo(type: "performance", name: "CPU + GPU", symbol: "cpu", category: "Status", defaults: [:], fields: []),
        ItemTypeInfo(type: "network", name: "Network Speed", symbol: "arrow.up.arrow.down", category: "Status", defaults: ["flip": .bool(true)],
                     fields: [FieldSpec(path: "flip", label: "Upload on top", kind: .toggle(default: false)),
                              FieldSpec(path: "units", label: "Units", kind: .choice(["dynamic", "B/s", "KB/s", "MB/s", "GB/s"]))]),
        ItemTypeInfo(type: "battery", name: "Battery", symbol: "battery.75", category: "Status", defaults: [:],
                     fields: [FieldSpec(path: "showIcon", label: "Show battery icon", kind: .toggle(default: true)),
                              FieldSpec(path: "showPercentage", label: "Show percentage", kind: .toggle(default: true)),
                              FieldSpec(path: "percentInside", label: "Percentage inside the icon", kind: .toggle(default: false)),
                              FieldSpec(path: "showTime", label: "Show time remaining", kind: .toggle(default: false)),
                              FieldSpec(path: "animate", label: "Animate while charging", kind: .toggle(default: true)),
                              FieldSpec(path: "tapToCycle", label: "Tap to show time remaining", kind: .toggle(default: true)),
                              FieldSpec(path: "lowThreshold", label: "Low battery warning at (%)", kind: .number(placeholder: "20"))]),
        ItemTypeInfo(type: "weather", name: "Weather", symbol: "cloud.sun", category: "Status", defaults: [:],
                     fields: [FieldSpec(path: "api_key", label: "OpenWeatherMap API key", kind: .text(placeholder: "required")),
                              FieldSpec(path: "units", label: "Units", kind: .choice(["metric", "imperial"])),
                              FieldSpec(path: "icon_type", label: "Icons", kind: .choice(["text", "images"])),
                              FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "1800"))]),
        ItemTypeInfo(type: "currency", name: "Currency", symbol: "dollarsign.circle", category: "Status", defaults: ["from": .string("BTC"), "to": .string("USD")],
                     fields: [FieldSpec(path: "from", label: "From", kind: .text(placeholder: "BTC")),
                              FieldSpec(path: "to", label: "To", kind: .text(placeholder: "USD")),
                              FieldSpec(path: "full", label: "Show full price", kind: .toggle(default: false)),
                              FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "600"))]),
        ItemTypeInfo(type: "upnext", name: "Up Next (Calendar)", symbol: "calendar", category: "Status", defaults: [:],
                     fields: [FieldSpec(path: "from", label: "From (hours from now)", kind: .number(placeholder: "0")),
                              FieldSpec(path: "to", label: "To (hours from now)", kind: .number(placeholder: "12")),
                              FieldSpec(path: "maxToShow", label: "Max events", kind: .number(placeholder: "3")),
                              FieldSpec(path: "autoResize", label: "Auto-resize", kind: .toggle(default: false))]),
        ItemTypeInfo(type: "pomodoro", name: "Pomodoro", symbol: "timer", category: "Status", defaults: [:],
                     fields: [FieldSpec(path: "workTime", label: "Work (s)", kind: .number(placeholder: "1500")),
                              FieldSpec(path: "restTime", label: "Rest (s)", kind: .number(placeholder: "600"))]),

        // System
        simple("dnd", "Do Not Disturb", "moon.fill", "System"),
        simple("nightShift", "Night Shift", "sun.haze", "System"),
        simple("darkMode", "Dark Mode", "circle.lefthalf.filled", "System"),
        simple("inputsource", "Input Source", "globe", "System"),
        ItemTypeInfo(type: "screenshot", name: "Screenshot", symbol: "camera.viewfinder", category: "System", defaults: [:],
                     fields: [FieldSpec(path: "nativeBar", label: "Show macOS's screenshot controls while open",
                                        kind: .toggle(default: true))]),
        simple("sleep", "Sleep", "powersleep", "System"),
        simple("displaySleep", "Display Sleep", "display", "System"),
        ItemTypeInfo(type: "dock", name: "Dock", symbol: "dock.rectangle", category: "System", defaults: [:],
                     fields: [FieldSpec(path: "autoResize", label: "Auto-resize", kind: .toggle(default: false)),
                              FieldSpec(path: "filter", label: "Only apps matching (regex)", kind: .text(placeholder: "Safari|Mail"))]),

        // Sliders
        simple("volume", "Volume Slider", "slider.horizontal.3", "Sliders", defaults: ["width": .number(240)]),
        ItemTypeInfo(type: "brightness", name: "Brightness Slider", symbol: "sun.max.fill", category: "Sliders", defaults: ["width": .number(240)],
                     fields: [FieldSpec(path: "refreshInterval", label: "Refresh every (s)", kind: .number(placeholder: "0.5"))]),

        // Containers
        // A neutral icon until it's given one: with a volume slider first inside,
        // the icon follows the volume anyway ("liveIcon").
        ItemTypeInfo(type: "popover", name: "Popover", symbol: "rectangle.expand.vertical", category: "Containers",
                     defaults: ["symbol": .string("ellipsis.circle"), "pressAndHold": .bool(true)],
                     fields: [FieldSpec(path: "pressAndHold", label: "Press and hold to slide", kind: .toggle(default: false)),
                              FieldSpec(path: "liveIcon", label: "Icon shows the volume level", kind: .toggle(default: true)),
                              FieldSpec(path: "autoClose", label: "Auto-close after (s)", kind: .number(placeholder: "never"))]),
        ItemTypeInfo(type: "cluster", name: "Group", symbol: "rectangle.split.3x1", category: "Containers",
                     defaults: ["itemWidth": .number(40)],
                     fields: [FieldSpec(path: "dividers", label: "Dividers between items", kind: .toggle(default: false)),
                              FieldSpec(path: "itemWidth", label: "Minimum item width", kind: .number(placeholder: "Automatic")),
                              FieldSpec(path: "spacing", label: "Space between items", kind: .number(placeholder: "0")),
                              FieldSpec(path: "padding", label: "Padding at the ends", kind: .number(placeholder: "Automatic"))]),
        ItemTypeInfo(type: "group", name: "Folder", symbol: "folder", category: "Containers",
                     defaults: ["symbol": .string("folder.fill")], fields: []),
        simple("close", "Close Folder", "chevron.left", "Containers"),

        // Other
        ItemTypeInfo(type: "swipe", name: "Swipe Gesture", symbol: "hand.draw", category: "Other",
                     defaults: ["fingers": .number(2), "direction": .string("right")],
                     fields: [FieldSpec(path: "fingers", label: "Fingers (2–4)", kind: .number(placeholder: "2")),
                              FieldSpec(path: "direction", label: "Direction", kind: .choice(["left", "right"])),
                              FieldSpec(path: "minOffset", label: "Min distance", kind: .number(placeholder: "0")),
                              FieldSpec(path: "sourceBash.inline", label: "Shell command", kind: .multiline),
                              FieldSpec(path: "sourceApple.inline", label: "AppleScript", kind: .multiline)]),
        simple("exitTouchbar", "Exit Stripe Bar", "xmark.circle", "Other"),
    ]

    private static func simple(_ type: String, _ name: String, _ symbol: String, _ category: String,
                               defaults: [String: JSONValue] = [:]) -> ItemTypeInfo {
        return ItemTypeInfo(type: type, name: name, symbol: symbol, category: category, defaults: defaults, fields: [])
    }

    /// Library types that stand for a template rather than an item type.
    static let templatePrefix = "template:"

    /// A down and an up key side by side in one group, split by a divider.
    private static func pair(_ id: String, _ name: String, _ symbol: String, down: String, up: String,
                             category: String = "Keys") -> ItemTypeInfo {
        group(id, name, symbol, [down, up], category: category)
    }

    /// Keys side by side in one group, split by dividers: a ready-made group.
    private static func group(_ id: String, _ name: String, _ symbol: String, _ types: [String], category: String) -> ItemTypeInfo {
        ItemTypeInfo(type: templatePrefix + id, name: name, symbol: symbol, category: category, defaults: [:], fields: [],
                     template: ["type": .string("cluster"), "dividers": .bool(true), "itemWidth": .number(44), "cornerRadius": .number(8),
                                "items": .array(types.map { .object(["type": .string($0)]) })])
    }

    static func info(for type: String) -> ItemTypeInfo {
        return all.first { $0.type == type }
            ?? ItemTypeInfo(type: type, name: type, symbol: "questionmark.square", category: "Other", defaults: [:], fields: [])
    }

    static func newItem(_ type: String, align: String, document: PresetDocument) -> EditorItem {
        // An item saved to My Items: a copy of it, placed where it's added.
        if let saved = SavedItems.shared.entry(for: type) {
            var fields = saved.item
            fields["align"] = align != "center" ? .string(align) : nil
            return EditorItem(fields: fields, document: document)
        }
        let info = self.info(for: type)
        var fields = info.template ?? info.defaults
        fields["type"] = fields["type"] ?? .string(type)
        if align != "center" { fields["align"] = .string(align) }
        if info.isContainer, fields["items"] == nil {
            fields["items"] = .array([])
        }
        return EditorItem(fields: fields, document: document)
    }

    /// Whether a library type (including a saved item) is a folder, group or popover.
    static func isContainer(_ type: String) -> Bool {
        if let saved = SavedItems.shared.entry(for: type) { return saved.info.isContainer }
        return info(for: type).isContainer
    }

    /// SF Symbols offered in the icon picker; any other symbol name can be typed in.
    static let suggestedSymbols = [
        "cpu", "memorychip", "internaldrive", "network", "wifi", "antenna.radiowaves.left.and.right",
        "bolt.fill", "battery.100", "thermometer", "fanblades", "gauge", "chart.bar.fill",
        "clock", "clock.arrow.circlepath", "timer", "calendar", "alarm", "hourglass",
        "play.fill", "pause.fill", "playpause.fill", "backward.fill", "forward.fill", "music.note",
        "speaker.wave.2.fill", "speaker.slash.fill", "mic.fill", "sun.max.fill", "moon.fill", "moon.zzz.fill",
        "gearshape.fill", "slider.horizontal.3", "power", "lock.fill", "arrow.clockwise", "arrow.triangle.2.circlepath",
        "terminal", "chevron.left.forwardslash.chevron.right", "hammer.fill", "wrench.and.screwdriver.fill", "shippingbox.fill", "server.rack",
        "cup.and.saucer.fill", "bell.fill", "envelope.fill", "message.fill", "star.fill", "heart.fill",
        "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "info.circle.fill", "questionmark.circle", "plus.circle.fill",
        "house.fill", "folder.fill", "doc.fill", "trash.fill", "camera.fill", "globe",
    ]
}
