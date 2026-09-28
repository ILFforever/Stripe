//
//  PerformancePanelSection.swift
//  Stripe
//
//  The "CPU Page", "GPU Page" and "Performance Page" sections of the CPU, GPU
//  and CPU + GPU inspectors: a live picture of the page holding the item
//  opens, which end its back button is at, and which tiles it shows.
//

import SwiftUI

struct PerformancePanelSection: View {
    @ObservedObject var item: EditorItem
    let kind: PerformancePanelOptions.Kind
    @ObservedObject var preview: PerformancePanelPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewImage
                .padding(.top, 10)
            Text("Tap the item to open this page across the whole bar; press and hold to open Activity Monitor.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.vertical, 8)
            FieldRow(label: "Back button", help: "Where the button that closes the page sits") {
                Picker("", selection: Binding(get: { item[string: "panelCloseSide"] ?? "" },
                                              set: { item[string: "panelCloseSide"] = $0 })) {
                    Text("Item's side").tag("")
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            FieldRow(label: "Tiles", help: "Tiles that don't fit drop out, least important first") {
                // Two rows at most, so the checkboxes stay inside the inspector.
                let tiles = kind.tiles
                let half = (tiles.count + 1) / 2
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([Array(tiles.prefix(half)), Array(tiles.dropFirst(half))], id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(row, id: \.self) { tile in
                                Toggle(tile.name, isOn: tileBinding(tile)).toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { preview.show(item) }
        .onDisappear { preview.stop() }
        .onReceive(item.objectWillChange) { _ in
            DispatchQueue.main.async { preview.show(item) }
        }
    }

    private var previewImage: some View {
        GeometryReader { geometry in
            Group {
                if let image = preview.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width)
                } else {
                    Color.clear
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
        }
        .aspectRatio(1004 / 36, contentMode: .fit)
    }

    /// The page's default tiles are stored as nothing; any other choice as the full list.
    private func tileBinding(_ tile: PerformancePanelOptions.Tile) -> Binding<Bool> {
        let current = item.fields["panelTiles"]?.array?.compactMap { $0.string }
            .compactMap(PerformancePanelOptions.Tile.init(rawValue:)) ?? Array(kind.defaultTiles)
        return Binding(get: { current.contains(tile) }, set: { on in
            let next = kind.tiles.filter { $0 == tile ? on : current.contains($0) }
            item.setRaw("panelTiles", Set(next) == kind.defaultTiles ? nil : .array(next.map { .string($0.rawValue) }))
        })
    }
}

/// Draws the page away from the bar with the options being edited, refreshing
/// every two seconds while the section is on screen.
final class PerformancePanelPreviewModel: ObservableObject {
    static let shared = PerformancePanelPreviewModel()

    @Published private(set) var image: NSImage?

    private var content: PerformancePanelContent?
    private var options: PerformancePanelOptions?
    private let host = NSView()
    private var timer: Timer?

    func show(_ item: EditorItem) {
        guard let options = PerformancePanelPreviewModel.options(of: item) else { return }
        if options != self.options {
            self.options = options
            rebuild(options)
        }
        render()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: PerformanceStats.interval, repeats: true) { [weak self] _ in
                self?.render()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The page options the bar would use for this item, read by the real parser.
    private static func options(of item: EditorItem) -> PerformancePanelOptions? {
        guard let data = JSONValue.array([item.json]).pretty().data(using: .utf8),
              let definition = data.barItemDefinitions()?.first else { return nil }
        switch definition.type {
        case let .cpu(_, panel), let .gpu(_, panel), let .performance(_, panel): return panel.onSide(of: definition)
        default: return nil
        }
    }

    private func rebuild(_ options: PerformancePanelOptions) {
        host.subviews.forEach { $0.removeFromSuperview() }
        let barWidth = TouchBarController.shared.basicView?.view.frame.width ?? 0
        host.frame = NSRect(x: 0, y: 0, width: barWidth > 0 ? barWidth : 1004, height: ItemStyle.barHeight)
        host.appearance = NSAppearance(named: .darkAqua)
        let content = PerformancePanelContent(options: options) {}
        content.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        self.content = content
    }

    private func render() {
        guard let content = content else { return }
        host.layoutSubtreeIfNeeded()
        content.refresh()
        // The top apps arrive a moment later, off the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.content === content else { return }
            self.host.layoutSubtreeIfNeeded()
            self.image = ItemSnapshotModel.snapshot(of: self.host)
        }
    }
}
