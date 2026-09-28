//
//  SavedItems.swift
//  Stripe
//
//  "My Items": whole items saved from the bar to reuse, with their look,
//  actions, conditions and contents (a group keeps its items). Each is a file
//  in the library folder of Stripe's Application Support folder:
//
//    { "name": "Media keys", "item": { "type": "cluster", "items": [ … ] } }
//
//  They appear at the top of the library and are added like any library item.
//  They travel through drag and drop as the type "saved:<id>", which
//  ItemCatalog.newItem turns back into the saved item.
//

import AppKit
import SwiftUI

final class SavedItems: ObservableObject {
    static let shared = SavedItems()

    struct Entry: Identifiable {
        let id: String
        var name: String
        let item: [String: JSONValue]

        /// The library type standing for this entry.
        var libraryType: String { SavedItems.prefix + id }
        var info: ItemTypeInfo { ItemCatalog.info(for: item["type"]?.string ?? "unknown") }
        var symbol: String { item["symbol"]?.string ?? info.symbol }
    }

    static let prefix = "saved:"
    static let category = "My Items"

    @Published private(set) var entries: [Entry] = []
    private let folder = appSupportDirectory + "/library"

    private init() {
        load()
    }

    func entry(for libraryType: String) -> Entry? {
        guard libraryType.hasPrefix(SavedItems.prefix) else { return nil }
        let id = String(libraryType.dropFirst(SavedItems.prefix.count))
        return entries.first { $0.id == id }
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        entries = files.filter { $0.hasSuffix(".json") }.compactMap { file in
            guard let text = try? String(contentsOfFile: folder + "/" + file, encoding: .utf8),
                  let root = (try? JSONValue.parse(text))?.object,
                  let item = root["item"]?.object else { return nil }
            let id = String(file.dropLast(5))
            return Entry(id: id, name: root["name"]?.string ?? id, item: item)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Saves a copy of `item` (without its position, which is chosen when it's added).
    func save(_ item: EditorItem, name: String) {
        guard var json = item.json.object else { return }
        json["align"] = nil
        write(Entry(id: UUID().uuidString, name: name, item: json))
    }

    func rename(_ entry: Entry, to name: String) {
        var renamed = entry
        renamed.name = name
        write(renamed)
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(atPath: path(entry.id))
        load()
    }

    private func write(_ entry: Entry) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let root = JSONValue.object(["name": .string(entry.name), "item": .object(entry.item)])
        try? Data((root.pretty() + "\n").utf8).write(to: URL(fileURLWithPath: path(entry.id)))
        load()
    }

    private func path(_ id: String) -> String {
        return folder + "/" + id + ".json"
    }

    // MARK: Prompts

    /// Asks for a name, then saves the item to My Items.
    static func promptSave(_ item: EditorItem) {
        guard let name = askName(title: "Save to My Items",
                                 message: "Save “\(item.displayName)” to the library, with its look, actions and contents, to add again later.",
                                 initial: item.displayName, button: "Save") else { return }
        shared.save(item, name: name)
    }

    static func promptRename(_ entry: Entry) {
        guard let name = askName(title: "Rename “\(entry.name)”", message: "", initial: entry.name, button: "Rename") else { return }
        shared.rename(entry, to: name)
    }

    static func confirmDelete(_ entry: Entry) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(entry.name)” from My Items?"
        alert.informativeText = "Items already on the bar aren't affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { shared.delete(entry) }
    }

    private static func askName(title: String, message: String, initial: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? initial : name
    }
}
