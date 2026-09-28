//
//  PerformanceBarItems.swift
//  Stripe
//
//  The GPU item, and the CPU + GPU item that stacks both on one key. A tap
//  opens its page (PerformancePanel): the GPU page, or the unified one.
//  Holding opens Activity Monitor. The CPU item itself is CPUBarItem.
//
//    { "type": "gpu" }
//    { "type": "performance", "design": "chip" }   // or "minimal", "graph"
//

import AppKit

/// A tap opens the item's performance page and holding opens Activity Monitor,
/// unless the preset gives the item its own actions for those (the preset's
/// actions replace an item's own).
extension CustomButtonTouchBarItem {
    func opensPerformancePanel(_ options: PerformancePanelOptions) {
        actions.append(ItemAction(trigger: .singleTap) { PerformancePanel.shared.open(options: options) })
    }

    func opensActivityMonitor() {
        actions.append(ItemAction(trigger: .longTap) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        })
    }
}

final class GPUBarItem: CustomButtonTouchBarItem, TearDownable {
    private var timer: Timer?

    init(identifier: NSTouchBarItem.Identifier, refreshInterval: TimeInterval, panel: PerformancePanelOptions) {
        super.init(identifier: identifier, title: "")
        hideUntilFirstTitle()
        image = NSImage(systemSymbolName: "cube", accessibilityDescription: "GPU")
        opensActivityMonitor()
        opensPerformancePanel(panel)
        PerformanceStats.shared.start()
        timer = Timer.scheduledTimer(withTimeInterval: max(refreshInterval, PerformanceStats.interval), repeats: true) { [weak self] _ in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refresh() {
        guard let usage = PerformanceStats.shared.gpu?.utilization else {
            title = "—"
            return
        }
        // Like the CPU item: yellow when busy, a yellow key when very busy.
        let title = NSMutableAttributedString(attributedString: String(format: "%.0f%%", usage).defaultTouchbarAttributedString)
        let color: NSColor? = usage > 70 ? .black : usage > 30 ? .yellow : nil
        if let color = color {
            title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
        }
        attributedTitle = title
        let background: NSColor? = usage > 70 ? .yellow : nil
        if backgroundColor != background { backgroundColor = background }
    }

    func tearDown() {
        timer?.invalidate()
        timer = nil
    }
}

/// CPU on top, GPU below, in one of three designs.
final class PerformanceBarItem: CustomButtonTouchBarItem, TearDownable {
    enum Design: String, CaseIterable {
        /// A chip icon, and each figure in its graph color with a small label.
        case chip
        /// Small "CPU" / "GPU" labels and bold figures.
        case minimal
        /// A thin meter per line beside its figure.
        case graph

        var name: String {
            switch self {
            case .chip: return "Chip"
            case .minimal: return "Minimal"
            case .graph: return "Graph"
            }
        }
    }

    private let design: Design
    private let palette: PerformancePalette
    private var timer: Timer?

    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let lineHeight: CGFloat = 11
    private static let meterSize = NSSize(width: 28, height: 4)

    init(identifier: NSTouchBarItem.Identifier, design: Design, panel: PerformancePanelOptions) {
        self.design = design
        palette = panel.palette
        super.init(identifier: identifier, title: "")
        pictureView.imageScaling = .scaleNone
        pictureView.translatesAutoresizingMaskIntoConstraints = false
        opensActivityMonitor()
        opensPerformancePanel(panel)
        PerformanceStats.shared.start()
        refresh()
        // Once the first CPU figure is in (PerformanceStats.start).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: PerformanceStats.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Drawn as one picture, placed in the middle of the key by the item itself:
    /// as a two-line title it sat off center and a point high, and as the key's
    /// image the bar draws it a few points right of center.
    private let pictureView = NSImageView()
    private var keyWidth: NSLayoutConstraint?

    private func refresh() {
        let stats = PerformanceStats.shared
        // The item's own Look wins over the colors: its text color for the
        // figures, and its icon and icon color for the chip.
        let icon: NSImage? = design == .chip ? PerformanceBarItem.icon(style.symbol ?? "cpu", color: style.iconColor ?? .white) : nil
        let picture = PerformanceBarItem.picture(cpu: stats.cpu, gpu: stats.gpu?.utilization, design: design, palette: palette,
                                                 icon: icon, figureColor: style.textColor)
        pictureView.image = picture
        // The key can be rebuilt (a style change), so the picture follows it.
        if pictureView.superview !== view {
            pictureView.removeFromSuperview()
            view.addSubview(pictureView)
            NSLayoutConstraint.activate([
                pictureView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                pictureView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            keyWidth = nil
        }
        let width = ceil(picture.size.width) + 2 * PerformanceBarItem.sidePadding
        if keyWidth?.constant != width {
            keyWidth?.isActive = false
            keyWidth = view.widthAnchor.constraint(equalToConstant: width)
            keyWidth?.isActive = true
        }
    }

    /// Between the picture and the key's edges.
    private static let sidePadding: CGFloat = 10

    private static func icon(_ symbol: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: "CPU and GPU")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
    }

    /// The picture is drawn here, so the key doesn't draw the Look's icon itself.
    override var style: ItemStyle {
        didSet {
            if image != nil { image = nil }
            refresh()
        }
    }

    /// Both lines, right-aligned so they end together, after the chip icon in that design.
    static func picture(cpu: Double, gpu: Double?, design: Design, palette: PerformancePalette,
                        icon: NSImage?, figureColor: NSColor?) -> NSImage {
        let lines = self.lines(cpu: cpu, gpu: gpu, design: design, palette: palette, figureColor: figureColor)
        let textWidth = ceil(lines.map { $0.size().width }.max() ?? 0)
        let iconWidth = icon.map { ceil($0.size.width) + 5 } ?? 0
        let size = NSSize(width: iconWidth + textWidth, height: 2 * lineHeight)
        // Rendered now, into a 2x bitmap: drawn lazily, the Touch Bar redraws the
        // text in its own context, a few points off from where it was measured.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: size.height * scale)
        context.cgContext.scaleBy(x: scale, y: -scale)
        if let icon = icon {
            icon.draw(in: NSRect(x: 0, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        }
        for (index, line) in lines.enumerated() {
            let width = line.size().width
            // A point up: capitals and digits leave the bottom of each line empty.
            line.draw(at: NSPoint(x: iconWidth + textWidth - width, y: CGFloat(index) * lineHeight - 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        let picture = NSImage(size: size)
        picture.addRepresentation(rep)
        picture.isTemplate = false
        return picture
    }

    /// The CPU line and the GPU line.
    static func lines(cpu: Double, gpu: Double?, design: Design, palette: PerformancePalette,
                      figureColor: NSColor? = nil) -> [NSAttributedString] {
        // Figures padded to two digits with figure spaces (a digit wide), so the
        // lines keep their width as the figures change; "CPU" and "GPU" are all
        // but the same width too, so right-aligned they end together.
        func figure(_ value: Double?) -> String {
            let text = value.map { String(format: "%.0f%%", $0) } ?? "—"
            return String(repeating: "\u{2007}", count: max(0, 3 - text.count)) + text
        }
        let space = NSAttributedString(string: " ", attributes: [.font: valueFont])
        return [("CPU", Optional(cpu), true), ("GPU", gpu, false)].map { name, value, isCPU in
            let line = NSMutableAttributedString()
            let color = figureColor ?? palette.color(cpu: isCPU, value: value)
            let labelColor = palette.tintedLabels ? (isCPU ? palette.cpu : palette.gpu).withAlphaComponent(0.8)
                : NSColor(white: 1, alpha: 0.55)
            let label: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: labelColor]
            let plainFigure = figureColor ?? (palette.colorsPlainFigures ? color : NSColor.white)
            switch design {
            case .chip:
                line.append(NSAttributedString(string: figure(value), attributes: [.font: valueFont, .foregroundColor: color]))
                line.append(space)
                line.append(NSAttributedString(string: name, attributes: label))
            case .minimal:
                line.append(NSAttributedString(string: name, attributes: label))
                line.append(space)
                line.append(NSAttributedString(string: figure(value), attributes: [.font: valueFont, .foregroundColor: plainFigure]))
            case .graph:
                line.append(NSAttributedString(string: name, attributes: label))
                line.append(space)
                let meter = NSTextAttachment()
                meter.image = PerformanceBarItem.meter(value ?? 0, color: color)
                meter.bounds = NSRect(origin: NSPoint(x: 0, y: 1), size: meterSize)
                line.append(NSAttributedString(attachment: meter))
                line.append(space)
                line.append(NSAttributedString(string: figure(value), attributes: [.font: valueFont, .foregroundColor: NSColor.white]))
            }
            return line
        }
    }

    private static func meter(_ percent: Double, color: NSColor) -> NSImage {
        NSImage(size: meterSize, flipped: false) { rect in
            NSColor(white: 1, alpha: 0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            var filled = rect
            filled.size.width = max(rect.height, rect.width * CGFloat(min(max(percent, 0), 100) / 100))
            color.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
            return true
        }
    }

    func tearDown() {
        timer?.invalidate()
        timer = nil
    }
}
