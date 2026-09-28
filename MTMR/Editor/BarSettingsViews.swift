//
//  BarSettingsViews.swift
//  Stripe
//
//  The bar as a whole in Settings: the left pane's Bars tab (the main bar and
//  each app's bar), the inspector for the selected bar's background and glass
//  keys, and the background as the live preview draws it.
//

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bars tab

struct BarsList: View {
    @ObservedObject var document: PresetDocument
    @ObservedObject var session: EditorSession

    /// The preset on the Touch Bar now (it follows the app in front), checked each second.
    private let liveState = State(initialValue: TouchBarController.shared.currentPresetPath)
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private struct Entry: Identifiable {
        let name: String
        let path: String
        let bundleId: String?
        var id: String { path }
    }

    private var entries: [Entry] {
        let all = [Entry(name: "All apps", path: standardConfigPath, bundleId: nil)]
            + PresetLibrary.appPresets().map { preset in
                Entry(name: preset.name, path: preset.path,
                      bundleId: ((preset.path as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
        let query = session.search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Menu {
                    let existing = Set(PresetLibrary.appPresets().map { $0.path })
                    ForEach(PresetLibrary.runningApps().filter { !existing.contains(PresetLibrary.appsDirectory + "/\($0.bundleId).json") },
                            id: \.bundleId) { app in
                        Button(app.name) { create(bundleId: app.bundleId) }
                    }
                    Divider()
                    Button("Choose App…", action: chooseApp)
                } label: {
                    Label("New Bar for an App", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Text("An app's bar replaces the main one while that app is in front.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .onReceive(tick) { _ in
            let live = TouchBarController.shared.currentPresetPath
            if liveState.wrappedValue != live { liveState.wrappedValue = live }
        }
    }

    private func row(_ entry: Entry) -> some View {
        let selected = document.path == entry.path
        return HStack(spacing: 8) {
            icon(for: entry)
            Text(entry.name).lineLimit(1)
            if entry.bundleId == nil {
                Text("default").font(.system(size: 11)).foregroundColor(selected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            if liveState.wrappedValue == entry.path {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                    .help("On the Touch Bar now")
            }
        }
        .foregroundColor(selected ? .white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { open(entry.path) }
        .contextMenu {
            if entry.bundleId != nil {
                Button("Reset to All Apps") { reset(entry) }
                Divider()
                Button("Delete Bar…") { delete(entry) }
            }
        }
    }

    @ViewBuilder
    private func icon(for entry: Entry) -> some View {
        if let id = entry.bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "rectangle.3.group").frame(width: 18, height: 18)
        }
    }

    private func open(_ path: String) {
        guard document.path != path else { return }
        session.selection = nil
        session.barPanel = nil
        document.open(path: path)
    }

    private func create(bundleId: String) {
        if let path = PresetLibrary.createAppPreset(bundleId: bundleId) { open(path) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
        create(bundleId: bundleId)
    }

    /// Starts the app's bar over as a copy of the main one.
    private func reset(_ entry: Entry) {
        let alert = NSAlert()
        alert.messageText = "Reset the bar for \(entry.name)?"
        alert.informativeText = "It becomes a copy of the main bar again."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(atPath: entry.path)
        try? FileManager.default.copyItem(atPath: standardConfigPath, toPath: entry.path)
        if document.path == entry.path { document.load() }
        TouchBarController.shared.reloadAfterEdit()
    }

    private func delete(_ entry: Entry) {
        let alert = NSAlert()
        alert.messageText = "Delete the bar for \(entry.name)?"
        alert.informativeText = "That app will use the main bar again."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if document.path == entry.path { open(standardConfigPath) }
        try? FileManager.default.removeItem(atPath: entry.path)
        TouchBarController.shared.reloadAfterEdit()
    }
}

// MARK: - Theme inspector

/// How the whole bar looks. For now its keys: standard gray or glass, for every
/// key that doesn't choose its own.
struct ThemeInspector: View {
    @ObservedObject var document: PresetDocument

    private var glassHelp: String {
        switch GlassStyle(rawValue: document.bar["glassStyle"]?.string ?? "") ?? .balanced {
        case .subtle: return "A soft frost and a light fill"
        case .balanced: return "Clearly frosted: patterns go soft"
        case .strong: return "Heavily frosted and brighter"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme").font(.system(size: 17, weight: .semibold))
                        Text("How the whole bar looks · \(document.displayName)").foregroundColor(.secondary)
                    }
                }
                InspectorGroup(title: "Keys", symbol: "square.on.square") {
                    FieldRow(label: "Keys", help: "For every key that doesn't choose its own, on its Style tab") {
                        Picker("", selection: Binding(get: { document.bar["glassKeys"]?.bool == true ? "glass" : "standard" },
                                                      set: { document.setBar("glassKeys", $0 == "glass" ? .bool(true) : nil) })) {
                            Text("Standard").tag("standard")
                            Text("Glass").tag("glass")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if document.bar["glassKeys"]?.bool == true {
                        FieldRow(label: "Glass", help: glassHelp) {
                            Picker("", selection: Binding(get: { document.bar["glassStyle"]?.string ?? GlassStyle.balanced.rawValue },
                                                          set: { document.setBar("glassStyle", $0 == GlassStyle.balanced.rawValue ? nil : .string($0)) })) {
                                ForEach(GlassStyle.allCases, id: \.self) { style in
                                    Text(style.name).tag(style.rawValue)
                                }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        GlassTintRow(help: "Every glass key washed with a color, unless it has its own",
                                     value: Binding(get: { document.bar["glassTint"]?.string },
                                                    set: { document.setBar("glassTint", $0.map { .string($0) }) }))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What stays solid").font(.caption.weight(.semibold))
                    Text("A key's own Background (Color, None or Standard), its pressed color, and its color while it's on all show instead of glass. So do widgets that color their own key, like CPU when it's busy. Sliders, the Dock and Up Next have no key to make glass. Over a video background, glass keys get the fill but not the frosting.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Background inspector

struct BarInspector: View {
    @ObservedObject var document: PresetDocument

    /// Ready-made gradients: the first of the Premade Themes.
    static let gradients: [(name: String, colors: [String])] = [
        ("Aurora", ["#5A1A73", "#0D3366"]), ("Sunset", ["#FF6A3D", "#7A1F5C"]), ("Lagoon", ["#0F4C5C", "#1B998B"]),
        ("Dusk", ["#1A2440", "#3A1C4A"]), ("Ember", ["#3D0C02", "#9A2A0A"]),
    ]

    private var background: [String: JSONValue] { document.bar["background"]?.object ?? [:] }

    /// Whether the chosen fill is mostly light, where white text struggles.
    private var isLight: Bool {
        let hexes: [String]
        switch kind {
        case "color": hexes = [background["color"]?.string].compactMap { $0 }
        case "gradient": hexes = background["gradient"]?.array?.compactMap { $0.string } ?? []
        case "pattern": hexes = [background["colors"]?.array?.first?.string].compactMap { $0 }
        default: hexes = []
        }
        let levels = hexes.compactMap { $0.namedOrHexColor?.usingColorSpace(.sRGB) }
            .map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent }
        return !levels.isEmpty && levels.reduce(0, +) / CGFloat(levels.count) > 0.6
    }

    private var kind: String {
        for key in ["color", "gradient", "pattern", "video"] where background[key] != nil { return key }
        return "none"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BarBackgroundFill(bar: document.bar)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background").font(.system(size: 17, weight: .semibold))
                        Text("Behind the whole Touch Bar · \(document.displayName)").foregroundColor(.secondary)
                    }
                }
                InspectorGroup(title: "Fill", symbol: "paintbrush") {
                    FieldRow(label: "Type", help: "Behind every item, right of the Esc key") {
                        Picker("", selection: Binding(get: { kind }, set: setKind)) {
                            Text("None").tag("none")
                            Text("Color").tag("color")
                            Text("Gradient").tag("gradient")
                            Text("Pattern").tag("pattern")
                            Text("Video").tag("video")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    kindRows
                }
                if isLight {
                    Text("Light backgrounds make white text hard to read. Glass keys darken to stay readable, but readouts that sit straight on the bar (like CPU or the clock) don't; a darker fill works best.")
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if document.bar["background"] != nil, document.bar["glassKeys"]?.bool != true {
                    Text("Tip: glass keys let the background show through. Turn them on in Theme.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var kindRows: some View {
        switch kind {
        case "color":
            FieldRow(label: "Color") { colorWell("background.color", fallback: "#1A2440") }
        case "gradient":
            FieldRow(label: "Colors", help: "Left to right") {
                HStack(spacing: 6) {
                    colorWell("background.gradient", index: 0, fallback: "#5A1A73")
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    colorWell("background.gradient", index: 1, fallback: "#0D3366")
                }
            }
            FieldRow(label: "Premade", help: "Premade Themes") {
                HStack(spacing: 6) {
                    ForEach(BarInspector.gradients, id: \.name) { preset in
                        Button(action: { document.setBar("background.gradient", .array(preset.colors.map { .string($0) })) }) {
                            LinearGradient(colors: preset.colors.compactMap { $0.namedOrHexColor }.map { Color(nsColor: $0) },
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 40, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                                    background["gradient"]?.array?.compactMap { $0.string } == preset.colors ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: background["gradient"]?.array?.compactMap { $0.string } == preset.colors ? 2 : 0.5))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            }
        case "pattern":
            FieldRow(label: "Pattern", help: BarPattern(rawValue: background["pattern"]?.string ?? "")?.name) {
                patternGrid
            }
            FieldRow(label: "Colors", help: "Background, then lines") {
                HStack(spacing: 6) {
                    colorWell("background.colors", index: 0, fallback: "#141414")
                    colorWell("background.colors", index: 1, fallback: "#333333")
                }
            }
        case "video":
            FieldRow(label: "Video", help: background["video"]?.string ?? "None chosen") {
                Button("Choose Video…", action: chooseVideo)
            }
            ToggleRow(label: "Pause on battery", help: "Playing a video uses about 5% CPU",
                      defaultValue: true,
                      value: Binding(get: { background["pauseOnBattery"]?.bool },
                                     set: { document.setBar("background.pauseOnBattery", $0 == false ? .bool(false) : nil) }))
        default:
            EmptyView()
        }
    }

    /// Every pattern as a thumbnail in the chosen colors, seven to a row.
    private var patternGrid: some View {
        let chosen = background["pattern"]?.string ?? BarPattern.stripes.rawValue
        let colors = (background["colors"]?.array?.compactMap { $0.string?.namedOrHexColor }) ?? []
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 7), spacing: 6) {
            ForEach(BarPattern.allCases, id: \.self) { pattern in
                Button(action: { document.setBar("background.pattern", .string(pattern.rawValue)) }) {
                    Image(nsImage: pattern.tile(colors: colors.isEmpty ? [NSColor(white: 0.12, alpha: 1), NSColor(white: 0.45, alpha: 1)] : colors))
                        .resizable(resizingMode: .tile)
                        .frame(width: 40, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(chosen == pattern.rawValue ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                        lineWidth: chosen == pattern.rawValue ? 2 : 0.5))
                }
                .buttonStyle(.plain)
                .help(pattern.name)
            }
        }
        .fixedSize()
    }

    /// A color well for a hex string at `path`, or at `index` in the list there.
    private func colorWell(_ path: String, index: Int? = nil, fallback: String) -> some View {
        let current: String = {
            let value = document.bar[path: path]
            if let index = index { return value?.array?[safe: index]?.string ?? fallback }
            return value?.string ?? fallback
        }()
        return ColorPicker("", selection: Binding(
            get: { Color(nsColor: current.namedOrHexColor ?? .black) },
            set: { color in
                let hex = JSONValue.string(NSColor(color).hexString)
                if let index = index {
                    var list = document.bar[path: path]?.array ?? []
                    while list.count <= index { list.append(.string(fallback)) }
                    list[index] = hex
                    document.setBar(path, .array(list))
                } else {
                    document.setBar(path, hex)
                }
            }
        ), supportsOpacity: false)
        .labelsHidden()
    }

    private func setKind(_ kind: String) {
        switch kind {
        case "color": document.setBarBackground(["color": .string("#1A2440")])
        case "gradient": document.setBarBackground(["gradient": .array(BarInspector.gradients[0].colors.map { .string($0) })])
        case "pattern": document.setBarBackground(["pattern": .string(BarPattern.stripes.rawValue)])
        case "video": chooseVideo()
        default: document.setBarBackground(nil)
        }
    }

    /// Copies the chosen video into Stripe's Backgrounds folder, so moving or
    /// deleting the original doesn't break the bar.
    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let folder = URL(fileURLWithPath: BarSettings.backgroundsFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(source.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(number).\(source.pathExtension)")
            number += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            document.setBarBackground(["video": .string(destination.lastPathComponent)])
        } catch {
            NSLog("Stripe: couldn't copy the video: \(error)")
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - The background in the live preview

/// The bar's background as the preview draws it: the same colors and patterns,
/// and a still frame of a video.
struct BarBackgroundFill: View {
    let bar: [String: JSONValue]

    private var settings: BarSettings {
        guard let data = JSONValue.object(bar).pretty().data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return BarSettings() }
        return BarSettings(json: json)
    }

    var body: some View {
        switch settings.background {
        case .none:
            Color.black
        case let .color(color):
            Color(nsColor: color)
        case let .gradient(colors):
            LinearGradient(colors: colors.map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing)
        case let .pattern(pattern, colors):
            Image(nsImage: pattern.tile(colors: colors)).resizable(resizingMode: .tile)
        case let .video(url):
            if let frame = VideoStill.image(for: url) {
                Image(nsImage: frame).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
    }
}

/// One frame from a video, remembered per file.
enum VideoStill {
    private static var cache: [URL: NSImage] = [:]

    static func image(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
        generator.maximumSize = CGSize(width: 2008, height: 400)
        guard let frame = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) else { return nil }
        let image = NSImage(cgImage: frame, size: .zero)
        cache[url] = image
        return image
    }
}
