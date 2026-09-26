//
//  PerformancePanel.swift
//  Stripe
//
//  Tapping the CPU, GPU or CPU + GPU item opens this across the whole bar, like
//  the battery overview: a slab of tiles with a back chevron at one end.
//
//    CPU + GPU:  [CPU 23% P 31 · E 12] [CORES ▂▅▁▄ ▁▁▁▁] [LAST 2 MIN ~~~] [GPU 10% 0.3 GB] [MEMORY 11.2 of 16 GB] [TOP APPS] │ ›
//    CPU:        [CPU …] [CORES …] [LAST 2 MIN ~~~] [LOAD 1.8 2.1 · 2.4] [TOP APPS] │ ›
//    GPU:        [GPU 10% Apple M2] [RENDER · TILER] [LAST 2 MIN ~~~] [GPU MEMORY] │ ›
//
//  Which page opens depends on the item tapped; each item picks its tiles
//  ("panelTiles") and which end the chevron sits at ("panelCloseSide").
//  Tiles that don't fit drop out, least important first. Data comes from
//  PerformanceStats; updates every two seconds while open.
//

import Cocoa

struct PerformancePanelOptions: Equatable {
    enum Kind: String {
        case unified, cpu, gpu

        /// The tiles this page can show, in order, and which it shows by default.
        var tiles: [Tile] {
            switch self {
            case .unified: return [.cpu, .cores, .graph, .load, .gpu, .gpuDetail, .gpuMemory, .memory, .apps]
            case .cpu: return [.cpu, .cores, .graph, .load, .memory, .apps]
            case .gpu: return [.gpu, .gpuDetail, .graph, .gpuMemory, .memory, .apps]
            }
        }

        var defaultTiles: Set<Tile> {
            switch self {
            case .unified: return [.cpu, .cores, .graph, .gpu, .memory, .apps]
            case .cpu: return [.cpu, .cores, .graph, .load, .apps]
            case .gpu: return [.gpu, .gpuDetail, .graph, .gpuMemory, .apps]
            }
        }
    }

    enum Tile: String, CaseIterable {
        case cpu, cores, graph, load, gpu, gpuDetail, gpuMemory, memory, apps

        var name: String {
            switch self {
            case .cpu: return "CPU"
            case .cores: return "Cores"
            case .graph: return "Graph"
            case .load: return "Load"
            case .gpu: return "GPU"
            case .gpuDetail: return "Render · Tiler"
            case .gpuMemory: return "GPU memory"
            case .memory: return "Memory"
            case .apps: return "Top apps"
            }
        }
    }

    var kind: Kind
    var tiles: Set<Tile>
    var palette = PerformancePalette.standard
    /// Nil: the item's side of the bar.
    var closeSide: Align?

    init(kind: Kind, tiles: Set<Tile>? = nil, closeSide: Align? = nil, palette: PerformancePalette = .standard) {
        self.kind = kind
        self.palette = palette
        self.tiles = tiles ?? kind.defaultTiles
        self.closeSide = closeSide
    }
}

extension PerformancePanelOptions {
    /// With the back button on the item's side of the bar unless the preset says otherwise.
    func onSide(of item: BarItemDefinition) -> PerformancePanelOptions {
        var options = self
        if options.closeSide == nil { options.closeSide = item.align == .left ? .left : .right }
        return options
    }
}

/// A built-in color scheme for the CPU and GPU (the "colors" key on the CPU,
/// GPU and CPU + GPU items): a color each, or Heat, which colors figures by how
/// busy they are. The graph always keeps a distinct color per series.
struct PerformancePalette: Equatable {
    let id: String
    let name: String
    /// Each series' own color: its figures (unless Heat), meter and graph line.
    let cpu: NSColor
    let gpu: NSColor
    /// Labels in the series' color too, rather than gray.
    let tintedLabels: Bool
    /// Figures and meters green, yellow or red by load.
    let heat: Bool

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static let all: [PerformancePalette] = [
        PerformancePalette(id: "heat", name: "Heat", cpu: rgb(0x64D2FF), gpu: rgb(0xFF9F0A), tintedLabels: false, heat: true),
        PerformancePalette(id: "sky", name: "Sky", cpu: rgb(0x64D2FF), gpu: rgb(0xFF9F0A), tintedLabels: false, heat: false),
        PerformancePalette(id: "vivid", name: "Vivid", cpu: rgb(0x0A84FF), gpu: rgb(0xFF375F), tintedLabels: false, heat: false),
        PerformancePalette(id: "mint", name: "Mint", cpu: rgb(0x63E6BE), gpu: rgb(0xBF5AF2), tintedLabels: false, heat: false),
        PerformancePalette(id: "neon", name: "Neon", cpu: rgb(0x5AC8FA), gpu: rgb(0xFF2D95), tintedLabels: true, heat: false),
    ]

    static let standard = all[0]

    static func named(_ id: String?) -> PerformancePalette {
        all.first { $0.id == id } ?? standard
    }

    /// What a figure (or meter) is drawn in: by load under Heat, else the series' color.
    func color(cpu isCPU: Bool, value: Double?) -> NSColor {
        guard heat else { return isCPU ? cpu : gpu }
        guard let value = value else { return NSColor(white: 1, alpha: 0.6) }
        return value > 70 ? PerformancePalette.rgb(0xFF453A) : value > 35 ? PerformancePalette.rgb(0xFFD60A) : PerformancePalette.rgb(0x30D158)
    }

    /// Whether a figure that's otherwise white takes a color (Minimal's figures).
    var colorsPlainFigures: Bool { heat || tintedLabels }
}

/// The page's views and how they're filled in; used on the bar and for the
/// preview in Settings.
final class PerformancePanelContent: NSObject {
    let options: PerformancePanelOptions
    private(set) var view: NSView!

    private let stats = PerformanceStats.shared
    private let apps = AppCPU()
    private let gpuApps = AppGPU()
    private static let samplingQueue = DispatchQueue(label: "com.ilfforever.stripe.appCPU")
    /// Which the top-apps tile lists; tapping it switches.
    private var appsShowGPU: Bool
    private let appsCaption = PanelTile.caption()
    /// Both lists are sampled while open, so switching shows figures at once.
    private var latestApps: (cpu: [AppCPU.Usage], gpu: [AppCPU.Usage]) = ([], [])
    /// Whether a sample since the baseline has come in: until then an empty list
    /// means "measuring", after it "nothing busy".
    private var appsMeasured = false
    private var shownApps: [String] = []

    private let cpuCaption = PanelTile.caption()
    private let cpuValue = PanelTile.value()
    private let coreBars = CoreBarsView()
    private let graph = UsageGraphView()
    private let loadValue = PanelTile.value()
    private let gpuCaption = PanelTile.caption()
    private let gpuValue = PanelTile.value()
    private let gpuDetailValue = PanelTile.value()
    private let gpuMemoryValue = PanelTile.value()
    private let memoryCaption = PanelTile.caption()
    private let memoryValue = PanelTile.value()
    private let appsRow = NSStackView()
    private var tileViews: [PerformancePanelOptions.Tile: PanelTile] = [:]
    private let spacer = PanelSpacer()
    private weak var row: NSStackView?

    private static let maxApps = 4
    /// Least important first.
    private static let dropOrder: [PerformancePanelOptions.Tile] = [.apps, .load, .gpuDetail, .memory, .gpuMemory, .cores]

    init(options: PerformancePanelOptions, onClose: @escaping () -> Void) {
        self.options = options
        appsShowGPU = options.kind == .gpu
        super.init()
        appsRow.orientation = .horizontal
        appsRow.spacing = 10
        graph.showsCPU = options.kind != .gpu
        graph.showsGPU = options.kind != .cpu
        graph.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        graph.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let preferred = graph.widthAnchor.constraint(equalToConstant: 260)
        preferred.priority = .init(500)
        preferred.isActive = true
        graph.heightAnchor.constraint(equalToConstant: 15).isActive = true

        var tiles: [NSView] = []
        for tile in options.kind.tiles where options.tiles.contains(tile) {
            let view: PanelTile
            switch tile {
            case .cpu: view = PanelTile(caption: cpuCaption, content: cpuValue, width: 150)
            case .cores: view = PanelTile(caption: PanelTile.caption("CORES"), content: coreBars)
            case .graph: view = PanelTile(caption: graphCaption(), content: graph, compressible: true)
            case .load: view = PanelTile(caption: PanelTile.caption("LOAD · 1 · 5 · 15 MIN"), content: loadValue, width: 140)
            case .gpu: view = PanelTile(caption: gpuCaption, content: gpuValue, width: 140)
            case .gpuDetail: view = PanelTile(caption: PanelTile.caption("RENDER · TILER"), content: gpuDetailValue, width: 110)
            case .gpuMemory: view = PanelTile(caption: PanelTile.caption("GPU MEMORY"), content: gpuMemoryValue, width: 150)
            case .memory: view = PanelTile(caption: memoryCaption, content: memoryValue, width: 140)
            case .apps:
                view = PanelTile(caption: appsCaption, content: appsRow, stretches: true)
                let tap = NSClickGestureRecognizer(target: self, action: #selector(switchApps))
                tap.allowedTouchTypes = .direct
                view.addGestureRecognizer(tap)
                showAppsCaption()
            }
            tileViews[tile] = view
            tiles.append(view)
        }
        tiles.append(spacer)
        spacer.isHidden = tileViews[.apps] != nil

        let side = options.closeSide ?? .right
        let back = PanelBackButton(pointing: side, action: onClose)
        let divider = PanelDivider()
        let views = side == .left ? [back, divider] + tiles : tiles + [divider, back]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 6
        stack.setCustomSpacing(4, after: side == .left ? back : divider)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.setHuggingPriority(.init(1), for: .horizontal)
        row = stack
        let slab = PanelSlab(content: stack)
        slab.onLayout = { [weak self] in self?.fitTiles() }
        view = slab

        stats.start()
        if tileViews[.apps] != nil {
            let apps = self.apps, gpuApps = self.gpuApps
            PerformancePanelContent.samplingQueue.async { // baselines
                _ = apps.sample(limit: 0)
                _ = gpuApps.sample(limit: 0)
            }
        }
    }

    /// "LAST 2 MIN · CPU GPU", with the series names in their graph colors.
    private func graphCaption() -> NSTextField {
        let caption = PanelTile.caption()
        let text = NSMutableAttributedString(string: "LAST 2 MIN", attributes: [.font: caption.font!, .foregroundColor: caption.textColor!])
        let series: [(String, NSColor)] = [
            graph.showsCPU ? ("CPU", options.palette.cpu) : nil,
            graph.showsGPU ? ("GPU", options.palette.gpu) : nil,
        ].compactMap { $0 }
        if series.count > 1 {
            for (index, (name, color)) in series.enumerated() {
                text.append(NSAttributedString(string: index == 0 ? " · " : " ", attributes: [.font: caption.font!, .foregroundColor: caption.textColor!]))
                text.append(NSAttributedString(string: name, attributes: [.font: caption.font!, .foregroundColor: color]))
            }
        }
        caption.attributedStringValue = text
        return caption
    }

    /// Drops the tiles that don't fit, least important first.
    private func fitTiles() {
        guard let row = row, row.frame.width > 0 else { return }
        let droppable = PerformancePanelContent.dropOrder.compactMap { tileViews[$0] }
        var dropped: [PanelTile] = []
        let appsTile = tileViews[.apps]
        func needed() -> CGFloat {
            let visible = row.arrangedSubviews.filter { view in view !== spacer && !dropped.contains { $0 === view } }
            let widths = visible.reduce(0) { $0 + ($1 === appsTile ? 110 : $1.fittingSize.width) }
            return widths + row.spacing * CGFloat(max(visible.count - 1, 0)) + row.edgeInsets.left + row.edgeInsets.right
        }
        for tile in droppable where needed() > row.frame.width {
            dropped.append(tile)
        }
        for tile in droppable {
            let hide = dropped.contains { $0 === tile }
            if tile.isHidden != hide { tile.isHidden = hide }
        }
        let spacerHidden = !(appsTile?.isHidden ?? true)
        if spacer.isHidden != spacerHidden { spacer.isHidden = spacerHidden }
    }

    func refresh() {
        let percent = { (value: Double) in String(format: "%.0f%%", value) }
        cpuCaption.stringValue = "CPU · \(stats.cores.count) CORES"
        let palette = options.palette
        var cpuParts: [(String, Bool, NSColor?)] = [(percent(stats.cpu), true, palette.color(cpu: true, value: stats.cpu))]
        if let clusters = stats.clusterLoads {
            cpuParts.append((String(format: "  P %.0f · E %.0f", clusters.performance, clusters.efficiency), false, nil))
        }
        cpuValue.attributedStringValue = PerformancePanelContent.text(cpuParts)
        coreBars.palette = palette
        coreBars.loads = stats.cores
        coreBars.efficiencyCores = stats.efficiencyCores
        graph.palette = palette
        graph.samples = stats.history

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        loadValue.attributedStringValue = PanelTile.text([(String(format: "%.1f", load[0]), true),
                                                          (String(format: "  %.1f · %.1f", load[1], load[2]), false)])

        let gpu = stats.gpu
        gpuCaption.stringValue = options.kind == .gpu ? "GPU · \(stats.chipName.uppercased())" : "GPU"
        var gpuParts: [(String, Bool, NSColor?)] = [(gpu.map { percent($0.utilization) } ?? "—", true,
                                                     palette.color(cpu: false, value: gpu?.utilization))]
        if let memory = gpu?.memoryInUse, options.kind != .gpu {
            gpuParts.append(("  " + PerformancePanelContent.gigabytes(memory), false, nil))
        }
        gpuValue.attributedStringValue = PerformancePanelContent.text(gpuParts)
        gpuDetailValue.attributedStringValue = PanelTile.text([
            (gpu?.renderer.map(percent) ?? "—", true), (" · ", false), (gpu?.tiler.map(percent) ?? "—", true),
        ])
        gpuMemoryValue.attributedStringValue = PanelTile.text([
            (gpu?.memoryInUse.map(PerformancePanelContent.gigabytes) ?? "—", true),
            (gpu?.memoryAllocated.map { "  of " + PerformancePanelContent.gigabytes($0) } ?? "", false),
        ])

        let memory = stats.memory
        let pressure: (String, NSColor) = {
            switch memory.pressure {
            case .normal: return ("NORMAL", .systemGreen)
            case .warning: return ("HIGH", .systemYellow)
            case .critical: return ("CRITICAL", .systemRed)
            }
        }()
        let caption = NSMutableAttributedString(string: "MEMORY · ", attributes: [.font: memoryCaption.font!, .foregroundColor: memoryCaption.textColor!])
        caption.append(NSAttributedString(string: pressure.0, attributes: [.font: memoryCaption.font!, .foregroundColor: pressure.1]))
        memoryCaption.attributedStringValue = caption
        memoryValue.attributedStringValue = PanelTile.text([
            (String(format: "%.1f", memory.used / 1_073_741_824), true),
            (String(format: "  of %.0f GB", memory.total / 1_073_741_824), false),
        ])

        if tileViews[.apps] != nil {
            let apps = self.apps, gpuApps = self.gpuApps
            PerformancePanelContent.samplingQueue.async { [weak self] in
                let cpu = apps.sample(limit: PerformancePanelContent.maxApps)
                let gpu = gpuApps.sample(limit: PerformancePanelContent.maxApps)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.latestApps = (cpu, gpu)
                    self.appsMeasured = true
                    self.showApps(self.appsShowGPU ? gpu : cpu)
                }
            }
        }
    }

    @objc private func switchApps() {
        appsShowGPU.toggle()
        HapticFeedback.instance.tap(type: .click)
        showAppsCaption()
        shownApps = []
        showApps(appsShowGPU ? latestApps.gpu : latestApps.cpu)
    }

    /// "TOP APPS · CPU ⇄" in the series' color, so it reads as switchable.
    private func showAppsCaption() {
        let caption = NSMutableAttributedString(string: "TOP APPS · ", attributes: [.font: appsCaption.font!, .foregroundColor: appsCaption.textColor!])
        caption.append(NSAttributedString(string: appsShowGPU ? "GPU" : "CPU", attributes: [
            .font: appsCaption.font!, .foregroundColor: appsShowGPU ? options.palette.gpu : options.palette.cpu,
        ]))
        caption.append(NSAttributedString(string: "  ⇄", attributes: [.font: appsCaption.font!, .foregroundColor: appsCaption.textColor!]))
        appsCaption.attributedStringValue = caption
    }

    private func showApps(_ all: [AppCPU.Usage]) {
        // Under half a percent reads as 0%: noise, not a busy app.
        let usage = all.filter { $0.percent >= 0.5 }
        let summary = [appsShowGPU ? "gpu" : "cpu", appsMeasured ? "" : "measuring"] + usage.map { "\($0.name) \(Int($0.percent))" }
        guard summary != shownApps || appsRow.arrangedSubviews.isEmpty else { return }
        shownApps = summary
        for view in appsRow.arrangedSubviews {
            appsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !usage.isEmpty else {
            let measuring = PanelTile.value()
            measuring.attributedStringValue = PanelTile.text([(appsMeasured ? "Idle" : "Measuring…", false)])
            appsRow.addArrangedSubview(measuring)
            return
        }
        let limit = (tileViews[.apps]?.frame.width ?? 300) - 2 * PanelTile.padding
        for app in usage {
            let entry = NSStackView()
            entry.orientation = .horizontal
            entry.spacing = 4
            if let icon = app.icon {
                let image = NSImageView(image: icon)
                image.imageScaling = .scaleProportionallyUpOrDown
                image.widthAnchor.constraint(equalToConstant: 14).isActive = true
                image.heightAnchor.constraint(equalToConstant: 14).isActive = true
                entry.addArrangedSubview(image)
            }
            let value = PanelTile.value()
            value.attributedStringValue = PanelTile.text([(String(format: "%.0f%%", app.percent), true)])
            entry.addArrangedSubview(value)
            appsRow.addArrangedSubview(entry)
            // As many as fit, busiest first.
            if appsRow.arrangedSubviews.count > 1, appsRow.fittingSize.width > limit {
                appsRow.removeArrangedSubview(entry)
                entry.removeFromSuperview()
                break
            }
        }
    }

    /// Like PanelTile.text, with an optional color per part.
    private static func text(_ parts: [(String, Bool, NSColor?)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, isValue, color) in parts {
            result.append(NSAttributedString(string: string, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: isValue ? 14 : 12, weight: isValue ? .semibold : .regular),
                .foregroundColor: color ?? (isValue ? NSColor.white : NSColor(white: 1, alpha: 0.6)),
            ]))
        }
        return result
    }

    static func gigabytes(_ bytes: Double) -> String {
        let value = bytes / 1_073_741_824
        return value < 10 ? String(format: "%.1f GB", value) : String(format: "%.0f GB", value)
    }
}

/// A bar per core, efficiency cores dimmer and set apart from performance cores.
final class CoreBarsView: NSView {
    var loads: [Double] = [] {
        didSet {
            if loads.count != oldValue.count { invalidateIntrinsicContentSize() }
            needsDisplay = true
        }
    }
    var efficiencyCores = 0
    var palette = PerformancePalette.standard

    private static let barWidth: CGFloat = 4
    private static let gap: CGFloat = 2
    private static let groupGap: CGFloat = 5

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(max(loads.count, 1))
        let groups: CGFloat = efficiencyCores > 0 && efficiencyCores < loads.count ? CoreBarsView.groupGap : 0
        return NSSize(width: count * CoreBarsView.barWidth + (count - 1) * CoreBarsView.gap + groups, height: 15)
    }

    override func draw(_: NSRect) {
        var x: CGFloat = 0
        for (index, load) in loads.enumerated() {
            if index == efficiencyCores, index > 0 { x += CoreBarsView.groupGap }
            let track = NSRect(x: x, y: 0, width: CoreBarsView.barWidth, height: bounds.height)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            let height = max(1.5, bounds.height * CGFloat(min(load, 100) / 100))
            let efficiency = index < efficiencyCores
            palette.color(cpu: true, value: load).withAlphaComponent(efficiency ? 0.6 : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: CoreBarsView.barWidth, height: height), xRadius: 1, yRadius: 1).fill()
            x += CoreBarsView.barWidth + CoreBarsView.gap
        }
    }
}

/// CPU and GPU over the last two minutes, as lines from 0 to 100%.
final class UsageGraphView: NSView {
    var samples: [PerformanceStats.Sample] = [] {
        didSet { needsDisplay = true }
    }
    var showsCPU = true
    var showsGPU = true
    var palette = PerformancePalette.standard

    override func draw(_: NSRect) {
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        guard let last = samples.last?.time else { return }
        let span = PerformanceStats.historySpan
        func line(_ value: (PerformanceStats.Sample) -> Double?, _ color: NSColor) {
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            for sample in samples {
                guard let value = value(sample) else { continue }
                let x = bounds.width * CGFloat(1 - last.timeIntervalSince(sample.time) / span)
                let y = 1 + (bounds.height - 2) * CGFloat(min(max(value, 0), 100) / 100)
                if path.isEmpty { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
            }
            color.setStroke()
            path.stroke()
        }
        if showsGPU { line({ $0.gpu }, palette.gpu) }
        if showsCPU { line({ $0.cpu }, palette.cpu) }
    }
}

/// Shows the page on the bar in place of the main bar, and keeps it up to date.
final class PerformancePanel: NSObject, NSTouchBarDelegate {
    static let shared = PerformancePanel()

    private let identifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.performancePanel")
    private var content: PerformancePanelContent?
    private var timer: Timer?

    var isOpen: Bool { timer != nil }

    func open(options: PerformancePanelOptions) {
        guard !isOpen else { return }
        let content = PerformancePanelContent(options: options) { [weak self] in self?.close() }
        self.content = content
        content.refresh()
        content.view.alphaValue = 0
        TouchBarController.shared.showSubBar(identifiers: [identifier], delegate: self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            content.view.animator().alphaValue = 1
        }
        timer = Timer.scheduledTimer(withTimeInterval: PerformanceStats.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Fades the page out, then brings back the main bar.
    func close() {
        guard isOpen, let view = content?.view else { return }
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.content?.view === view, !self.isOpen else { return }
            self.content = nil
            TouchBarController.shared.restoreMainBar()
        })
    }

    private func refresh() {
        // Something else (a preset reload) took the bar back.
        if isOpen, TouchBarController.shared.touchBar.delegate !== self {
            timer?.invalidate()
            timer = nil
            content = nil
            return
        }
        content?.refresh()
    }

    func touchBar(_: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == self.identifier, let content = content else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = content.view
        return item
    }
}
