//
//  BatteryPanelSection.swift
//  Stripe
//
//  The Battery inspector's "Battery Overview" section: a live picture of the panel
//  that holding the battery item opens, and its options (what holding does,
//  which end the back button is at, which tiles show, and the graph's range).
//

import SwiftUI

struct BatteryPanelSection: View {
    @ObservedObject var item: EditorItem
    @ObservedObject var preview: BatteryPanelPreviewModel

    private var holdAction: String { item[string: "holdOpens"] ?? "details" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewImage
                .padding(.top, 10)
            Text("Press and hold the battery item to open the overview across the whole bar.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.vertical, 8)

            FieldRow(label: "Press and hold") {
                Picker("", selection: Binding(get: { holdAction },
                                              set: { item[string: "holdOpens"] = $0 == "details" ? nil : $0 })) {
                    Text("Opens overview").tag("details")
                    Text("Opens Battery settings").tag("settings")
                    Text("Nothing").tag("nothing")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }

            Group {
                FieldRow(label: "Back button", help: "Where the button that closes the overview sits") {
                    Picker("", selection: Binding(get: { item[string: "panelCloseSide"] ?? "" },
                                                  set: { item[string: "panelCloseSide"] = $0 })) {
                        Text("Battery's side").tag("")
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "Tiles", help: "Top apps takes whatever room is left") {
                    HStack(spacing: 12) {
                        ForEach(BatteryPanelSection.tiles, id: \.0) { tile, name in
                            Toggle(name, isOn: tileBinding(tile)).toggleStyle(.checkbox)
                        }
                    }
                }
                FieldRow(label: "Graph covers") {
                    Picker("", selection: numberBinding("panelGraphHours", default: 12)) {
                        Text("6 hours").tag(6)
                        Text("12 hours").tag(12)
                        Text("24 hours").tag(24)
                        Text("48 hours").tag(48)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "One bar per") {
                    Picker("", selection: numberBinding("panelBarMinutes", default: 30)) {
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("Hour").tag(60)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .disabled(holdAction != "details")
            .opacity(holdAction == "details" ? 1 : 0.45)
        }
        .onAppear { preview.show(item) }
        .onDisappear { preview.stop() }
        .onReceive(item.objectWillChange) { _ in
            // After the change lands.
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
            .opacity(holdAction == "details" ? 1 : 0.45)
        }
        // The bar is about 1004 × 30 points, plus a little room around it.
        .aspectRatio(1004 / 36, contentMode: .fit)
    }

    static let tiles: [(String, String)] = [("charge", "Battery"), ("graph", "Graph"), ("power", "Using"),
                                            ("since", "Since unplugged"), ("apps", "Top apps")]

    /// All tiles is the default, so the key is only written when some are off.
    private func tileBinding(_ tile: String) -> Binding<Bool> {
        let all = BatteryPanelSection.tiles.map { $0.0 }
        let current = item.fields["panelTiles"]?.array?.compactMap { $0.string } ?? all
        return Binding(get: { current.contains(tile) }, set: { on in
            var next = all.filter { $0 == tile ? on : current.contains($0) }
            if next.count == all.count { next = [] }
            item.setRaw("panelTiles", next.isEmpty && on ? nil : .array(next.map { .string($0) }))
        })
    }

    private func numberBinding(_ path: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { Int(item[number: path] ?? Double(fallback)) },
                set: { item[number: path] = $0 == fallback ? nil : Double($0) })
    }
}

/// Draws the battery panel away from the bar, with the options being edited,
/// refreshing every two seconds while the section is on screen.
final class BatteryPanelPreviewModel: ObservableObject {
    static let shared = BatteryPanelPreviewModel()

    @Published private(set) var image: NSImage?

    private var content: BatteryPanelContent?
    private var options: BatteryPanelOptions?
    private let host = NSView()
    private var timer: Timer?

    func show(_ item: EditorItem) {
        guard let options = BatteryPanelPreviewModel.options(of: item) else { return }
        if options != self.options {
            self.options = options
            rebuild(options)
        }
        render()
        if timer == nil {
            BatteryHistory.shared.start()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.render() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The panel options the bar would use for this item, read by the real parser.
    private static func options(of item: EditorItem) -> BatteryPanelOptions? {
        guard let data = JSONValue.array([item.json]).pretty().data(using: .utf8),
              let definition = data.barItemDefinitions()?.first,
              case var .battery(options) = definition.type else { return nil }
        if options.panel.closeSide == nil { options.panel.closeSide = definition.align == .left ? .left : .right }
        return options.panel
    }

    private func rebuild(_ options: BatteryPanelOptions) {
        host.subviews.forEach { $0.removeFromSuperview() }
        let barWidth = TouchBarController.shared.basicView?.view.frame.width ?? 0
        host.frame = NSRect(x: 0, y: 0, width: barWidth > 0 ? barWidth : 1004, height: ItemStyle.barHeight)
        host.appearance = NSAppearance(named: .darkAqua)
        let content = BatteryPanelContent(options: options) {}
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
        host.layoutSubtreeIfNeeded()
        image = ItemSnapshotModel.snapshot(of: host)
    }
}
