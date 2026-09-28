//
//  BatteryPanel.swift
//  Stripe
//
//  Holding the battery item opens this across the whole bar: a raised slab of
//  tiles, like a sheet over the main bar, with a back chevron at one end.
//
//    ╭──────────────────────────────────────────────────────────────────────────────╮
//    │ [CHARGING  ] [LAST 12 HOURS  ] [USING · 45 W ] [SINCE PLUGGED IN] [TOP APPS] │ › │
//    │ [74% 1:28  ] [▆▇▇▅▅▄▄▃▅▆▇▇▆  ] [13.1 W       ] [0:40  +18%  27%/h] [◉ 29 mW ] │   │
//    ╰──────────────────────────────────────────────────────────────────────────────╯
//
//  Charge and time left, the charge over the last hours (a bar per interval,
//  colored by level), what the Mac is drawing now, time and charge since it was
//  last plugged in or unplugged with the current rate, and which apps use the
//  most. Every tile has a fixed width except the apps, which take the rest and
//  show as many as fit. A long graph (24 or 48 hours) keeps its width; tiles
//  that no longer fit drop out instead: top apps, then since unplugged, then
//  using. Updates every two seconds while open.
//
//  Configured on the battery item (BatteryPanelOptions): "panelTiles",
//  "panelGraphHours", "panelBarMinutes", and "panelCloseSide" for which end the
//  chevron sits at (the battery item's side by default). Settings shows a live
//  preview built from the same BatteryPanelContent. Data comes from BatteryStats.swift.
//

import Cocoa

struct BatteryPanelOptions: Equatable {
    enum Tile: String, CaseIterable {
        case charge, graph, power, since, apps
    }

    var tiles = Set(Tile.allCases)
    var graphHours = 12
    var barMinutes = 30
    /// Nil: the battery item's side of the bar.
    var closeSide: Align?
}

/// The panel's views and how they're filled in; used on the bar and for the
/// preview in Settings.
final class BatteryPanelContent {
    let options: BatteryPanelOptions
    /// The whole panel: a slab spanning whatever it's placed in.
    private(set) var view: NSView!

    private let apps = AppEnergy()
    /// Energy sampling walks every process, so it runs off the main thread.
    private static let samplingQueue = DispatchQueue(label: "com.ilfforever.stripe.appEnergy")
    /// What the apps tile shows now, so an unchanged refresh doesn't rebuild it.
    private var shownApps: [String] = []
    private let chargeCaption = PanelTile.caption()
    private let chargeValue = PanelTile.value()
    private let graph = ChargeGraphView()
    private let powerCaption = PanelTile.caption()
    private let powerValue = PanelTile.value()
    private let sinceCaption = PanelTile.caption()
    private let sinceValue = PanelTile.value()
    private let appsRow = NSStackView()
    private var appsTile: PanelTile?
    private var sinceTile: PanelTile?
    private var powerTile: PanelTile?
    /// Takes up the slack when the apps tile is off or dropped, so the back button stays at the end.
    private let spacer = PanelSpacer()
    private weak var row: NSStackView?
    /// The apps tile needs at least this much to show one app.
    private static let appsMinimum: CGFloat = 130

    private static let maxApps = 4

    init(options: BatteryPanelOptions, onClose: @escaping () -> Void) {
        self.options = options
        appsRow.orientation = .horizontal
        appsRow.spacing = 10

        graph.span = TimeInterval(options.graphHours) * 3600
        graph.barInterval = TimeInterval(options.barMinutes) * 60
        // About 5 points per bar, so a day of half hours stays legible. If even
        // that doesn't fit next to the battery tile, the bars get thinner rather
        // than the back button being pushed off the bar.
        let bars = CGFloat(options.graphHours * 60 / max(options.barMinutes, 1))
        let graphWidth = max(200, bars * 5)
        graph.widthAnchor.constraint(lessThanOrEqualToConstant: graphWidth).isActive = true
        graph.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let preferred = graph.widthAnchor.constraint(equalToConstant: graphWidth)
        preferred.priority = .init(500)
        preferred.isActive = true
        graph.heightAnchor.constraint(equalToConstant: 15).isActive = true

        var tiles: [NSView] = []
        for tile in BatteryPanelOptions.Tile.allCases where options.tiles.contains(tile) {
            switch tile {
            case .charge:
                tiles.append(PanelTile(caption: chargeCaption, content: chargeValue, width: 130))
            case .graph:
                tiles.append(PanelTile(caption: PanelTile.caption("LAST \(options.graphHours) HOURS"), content: graph,
                                       compressible: true))
            case .power:
                let tile = PanelTile(caption: powerCaption, content: powerValue, width: 135)
                powerTile = tile
                tiles.append(tile)
            case .since:
                let tile = PanelTile(caption: sinceCaption, content: sinceValue, width: 160)
                sinceTile = tile
                tiles.append(tile)
            case .apps:
                let apps = PanelTile(caption: PanelTile.caption("TOP APPS"), content: appsRow, stretches: true)
                appsTile = apps
                tiles.append(apps)
            }
        }
        tiles.append(spacer)
        spacer.isHidden = appsTile != nil

        let side = options.closeSide ?? .right
        let back = PanelBackButton(pointing: side, action: onClose)
        let divider = PanelDivider()
        let views = side == .left ? [back, divider] + tiles : tiles + [divider, back]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        // Spare room goes to the one view that stretches, so the back button stays at the end.
        stack.distribution = .fill
        stack.spacing = 6
        stack.setCustomSpacing(4, after: side == .left ? back : divider)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.setHuggingPriority(.init(1), for: .horizontal)
        row = stack
        let slab = PanelSlab(content: stack)
        slab.onLayout = { [weak self] in self?.fitTiles() }
        view = slab
        let apps = self.apps
        BatteryPanelContent.samplingQueue.async { _ = apps.sample() } // baseline; figures appear from the next refresh
    }

    /// Drops the tiles that don't fit, least important first. Only changes what
    /// needs changing, since each change lays the panel out again.
    private func fitTiles() {
        guard let row = row, row.frame.width > 0 else { return }
        let droppable = [appsTile, sinceTile, powerTile].compactMap { $0 }
        var dropped: [PanelTile] = []
        func needed() -> CGFloat {
            let visible = row.arrangedSubviews.filter { view in
                view !== spacer && !dropped.contains { $0 === view }
            }
            let widths = visible.reduce(0) { total, view in
                total + (view === appsTile ? BatteryPanelContent.appsMinimum : view.fittingSize.width)
            }
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
        let info = BatteryInfo()
        info.getPSInfo()
        chargeCaption.stringValue = info.onACPower ? (info.isCharging ? "CHARGING" : "ON POWER") : "BATTERY"
        chargeValue.attributedStringValue = PanelTile.text([("\(info.current)%", true), ("  \(info.timeDescription)", false)])

        let power = BatteryPower.read()
        powerCaption.stringValue = power.chargerWatts.map { "USING · \($0) W CHARGER" } ?? "USING"
        powerValue.attributedStringValue = PanelTile.text([(power.systemWatts.map(BatteryPanel.watts) ?? "—", true)])

        showSince(charge: info.current, onAC: info.onACPower)
        graph.samples = BatteryHistory.shared.samples
        if appsTile != nil {
            let apps = self.apps
            BatteryPanelContent.samplingQueue.async { [weak self] in
                let usage = apps.sample(limit: BatteryPanelContent.maxApps)
                DispatchQueue.main.async { self?.showApps(usage) }
            }
        }
    }

    /// "2:14  −26%  9%/h": time since the last plug or unplug, the charge used or
    /// gained since, and the rate over the last half hour.
    private func showSince(charge: Int, onAC: Bool) {
        let history = BatteryHistory.shared
        sinceCaption.stringValue = onAC ? "SINCE PLUGGED IN" : "SINCE UNPLUGGED"
        let since = history.lastSwitch(to: onAC)
        var parts: [(String, Bool)] = []
        if let since = since {
            let minutes = Int((Date().timeIntervalSince1970 - since.time) / 60)
            parts.append((minutes >= 24 * 60 ? "\(minutes / 1440)d \(minutes / 60 % 24)h" : String(format: "%d:%02d", minutes / 60, minutes % 60), true))
            let change = charge - since.charge
            parts.append(("  \(change > 0 ? "+" : change < 0 ? "−" : "")\(abs(change))%", false))
        } else {
            parts.append(("—", true))
        }
        if let rate = history.rate(now: charge, since: since) {
            parts.append(("  " + (abs(rate) < 1 ? "<1" : String(format: "%.0f", abs(rate))) + "%/h", false))
        }
        sinceValue.attributedStringValue = PanelTile.text(parts)
    }

    private func showApps(_ usage: [AppEnergy.Usage]) {
        let summary = usage.prefix(BatteryPanelContent.maxApps).map { "\($0.name) \(BatteryPanel.watts($0.watts))" }
        guard summary != shownApps || appsRow.arrangedSubviews.isEmpty else { return }
        shownApps = summary
        for view in appsRow.arrangedSubviews {
            appsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let top = usage.prefix(BatteryPanelContent.maxApps)
        if top.isEmpty {
            let measuring = PanelTile.value()
            measuring.attributedStringValue = PanelTile.text([("Measuring…", false)])
            appsRow.addArrangedSubview(measuring)
            return
        }
        // As many apps as fit, heaviest first.
        var room = appsRoom
        for app in top {
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
            value.attributedStringValue = PanelTile.text([(BatteryPanel.watts(app.watts), true)])
            entry.addArrangedSubview(value)
            let width = entry.fittingSize.width + (appsRow.arrangedSubviews.isEmpty ? 0 : appsRow.spacing)
            guard width <= room else { break }
            room -= width
            appsRow.addArrangedSubview(entry)
        }
        // The estimate can be a little generous; the tile's actual width has the last word.
        if let tile = appsTile, tile.frame.width > 0 {
            let limit = tile.frame.width - 2 * PanelTile.padding
            while appsRow.arrangedSubviews.count > 1, appsRow.fittingSize.width > limit,
                  let last = appsRow.arrangedSubviews.last {
                appsRow.removeArrangedSubview(last)
                last.removeFromSuperview()
            }
        }
    }

    /// Width the app entries can use: the row, less everything else. Generous
    /// before the first layout.
    private var appsRoom: CGFloat {
        guard let row = row, row.frame.width > 0 else { return 300 }
        let others = row.arrangedSubviews.filter { $0 !== appsTile && !$0.isHidden }
        let shown = row.arrangedSubviews.filter { !$0.isHidden }
        let spacing = zip(shown, shown.dropFirst()).reduce(0) { total, pair in
            let custom = row.customSpacing(after: pair.0)
            return total + (custom == NSStackView.useDefaultSpacing ? row.spacing : custom)
        }
        let used = others.reduce(0) { $0 + $1.fittingSize.width } + spacing + row.edgeInsets.left + row.edgeInsets.right
            + 2 * PanelTile.padding
        return max(0, row.frame.width - used)
    }
}

/// Shows the panel on the bar in place of the main bar, and keeps it up to date.
final class BatteryPanel: NSObject, NSTouchBarDelegate {
    static let shared = BatteryPanel()

    private let identifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.batteryPanel")
    private var content: BatteryPanelContent?
    private var timer: Timer?

    var isOpen: Bool { timer != nil }

    func open(options: BatteryPanelOptions = BatteryPanelOptions()) {
        guard !isOpen else { return }
        BatteryHistory.shared.start()
        BatteryHistory.shared.record()
        let content = BatteryPanelContent(options: options) { [weak self] in self?.close() }
        self.content = content
        content.refresh()
        content.view.alphaValue = 0
        TouchBarController.shared.showSubBar(identifiers: [identifier], delegate: self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            content.view.animator().alphaValue = 1
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Fades the panel out, then brings back the main bar.
    func close() {
        guard isOpen, let view = content?.view else { return }
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Unless it was reopened while fading out.
            guard let self = self, self.content?.view === view, !self.isOpen else { return }
            self.content = nil
            TouchBarController.shared.restoreMainBar()
        })
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        content = nil
    }

    private func refresh() {
        // Something else (a preset reload) took the bar back.
        if isOpen, TouchBarController.shared.subBarOwner !== self {
            stop()
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

    /// "12.8 W", or "90 mW" below a watt.
    static func watts(_ value: Double) -> String {
        if value >= 1 { return String(format: "%.1f W", value) }
        return String(format: "%.0f mW", max(value * 1000, 1))
    }
}

/// Empty room that stretches, standing in for the top-apps tile when it's off.
final class PanelSpacer: NSView {
    init() {
        super.init(frame: .zero)
        setContentHuggingPriority(.init(1), for: .horizontal)
        heightAnchor.constraint(equalToConstant: ItemStyle.barHeight).isActive = true
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The raised background a panel sits on, spanning the bar, so the panel reads
/// as a layer over the main bar.
final class PanelSlab: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.cornerRadius = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ItemStyle.barHeight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Take the bar's full width.
        setContentHuggingPriority(.init(1), for: .horizontal)
    }

    /// Pinned to the width the bar gives the panel, so its edges and the back
    /// button stay put as the tiles' contents change.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fullWidth?.isActive = false
        fullWidth = superview.map { widthAnchor.constraint(equalTo: $0.widthAnchor) }
        fullWidth?.isActive = true
    }

    private var fullWidth: NSLayoutConstraint?

    /// Called after each layout, e.g. to drop tiles that no longer fit.
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The thin vertical line between a panel's back button and its tiles.
final class PanelDivider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }

    override func draw(_: NSRect) {
        NSColor(white: 1, alpha: 0.25).setFill()
        bounds.fill()
    }
}

/// A chevron pointing toward the bar's edge that closes the panel. Pressing it
/// behaves like a key: a rounded highlight fades in, the chevron nudges toward
/// the edge, and there's a haptic click. It closes when the finger lifts
/// inside it; sliding off cancels.
final class PanelBackButton: NSView {
    private let symbol: String
    /// Which way the chevron nudges while pressed: toward the bar's edge.
    private let nudge: CGFloat
    private let onTap: () -> Void
    private var pressed = false {
        didSet {
            guard pressed != oldValue else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = pressed ? 0.08 : 0.2
                context.allowsImplicitAnimation = true
                layer?.backgroundColor = NSColor(white: 1, alpha: pressed ? 0.22 : 0).cgColor
            }
            needsDisplay = true
        }
    }

    init(pointing side: Align, action: @escaping () -> Void) {
        symbol = side == .left ? "chevron.left" : "chevron.right"
        nudge = side == .left ? -2 : 2
        onTap = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        // Tracks the whole press (down, moves, up), not just the tap, so the
        // highlight shows as soon as a finger lands.
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.allowedTouchTypes = .direct
        addGestureRecognizer(press)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: ItemStyle.barHeight) }

    override func draw(_: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.9)]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: "Back")?
            .withSymbolConfiguration(config) else { return }
        let size = glyph.size
        let x = (bounds.width - size.width) / 2 + (pressed ? nudge : 0)
        glyph.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        let inside = bounds.contains(recognizer.location(in: self))
        switch recognizer.state {
        case .began:
            pressed = true
            HapticFeedback.instance.tap(type: .click)
        case .changed:
            pressed = inside
        case .ended:
            pressed = false
            if inside {
                HapticFeedback.instance.tap(type: .back)
                onTap()
            }
        default:
            pressed = false
        }
    }
}

/// One section of a panel: a small caption over its content, on a rounded card.
final class PanelTile: NSView {
    static let padding: CGFloat = 10

    /// `width`: a fixed width. `stretches`: takes up whatever room is left over.
    /// `compressible`: sized by its content, which may give up room when there's none.
    init(caption: NSTextField, content: NSView, width: CGFloat? = nil, stretches: Bool = false,
         compressible: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        layer?.cornerRadius = 7

        let stack = NSStackView(views: [caption, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ItemStyle.barHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelTile.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelTile.padding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        caption.setContentCompressionResistancePriority(compressible ? .defaultLow : .required, for: .horizontal)
        if let width = width {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        setContentCompressionResistancePriority(compressible ? .defaultLow : .required, for: .horizontal)
        // Like DismissArea: the bar widens a view only if it hugs almost not at all.
        let hugging: NSLayoutConstraint.Priority = stretches ? .init(1) : .required
        setContentHuggingPriority(hugging, for: .horizontal)
        stack.setHuggingPriority(hugging, for: .horizontal)
        content.setContentHuggingPriority(hugging, for: .horizontal)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func caption(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor(white: 1, alpha: 0.5)
        return label
    }

    static func value() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// Values in white, the rest in gray.
    static func text(_ parts: [(String, Bool)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, isValue) in parts {
            result.append(NSAttributedString(string: string, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: isValue ? 14 : 12, weight: isValue ? .semibold : .regular),
                .foregroundColor: isValue ? NSColor.white : NSColor(white: 1, alpha: 0.6),
            ]))
        }
        return result
    }
}

/// Charge over the last hours as bars, like macOS's Battery settings: one per
/// interval (half an hour by default), as tall as the charge at the end of it, colored by level (red when
/// low, through yellow, to green), on a faint green band where it was on power.
final class ChargeGraphView: NSView {
    var samples: [BatteryHistory.Sample] = [] {
        didSet { needsDisplay = true }
    }

    /// How far back the graph reaches, and how long each bar covers.
    var span: TimeInterval = 12 * 3600
    var barInterval: TimeInterval = 30 * 60

    override func draw(_: NSRect) {
        let now = Date().timeIntervalSince1970
        let count = Int((span / barInterval).rounded())
        // Bars line up with the clock (e.g. 14:00, 14:30); the last one is the current half hour.
        let lastStart = (now / barInterval).rounded(.down) * barInterval
        let firstStart = lastStart - Double(count - 1) * barInterval

        guard samples.contains(where: { $0.time < now }) else {
            let text = NSAttributedString(string: "Recording…", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
            text.draw(at: NSPoint(x: 4, y: bounds.midY - text.size().height / 2))
            return
        }

        let slot = bounds.width / CGFloat(count)
        let gap = max(1.5, slot * 0.3)
        var index = samples.startIndex
        var latest: BatteryHistory.Sample?
        for bar in 0 ..< count {
            let end = firstStart + Double(bar + 1) * barInterval
            var onAC = latest?.onAC ?? false
            // Every sample in this half hour: the last one sets the bar's height,
            // and any time on power shades it.
            while index < samples.endIndex, samples[index].time < end {
                latest = samples[index]
                onAC = onAC || samples[index].onAC
                index += 1
            }
            guard let level = latest else { continue } // before recording began

            let x = CGFloat(bar) * slot
            if onAC {
                NSColor.systemGreen.withAlphaComponent(0.16).setFill()
                NSRect(x: x, y: 0, width: slot, height: bounds.height).fill()
            }
            let height = max(1.5, bounds.height * CGFloat(level.charge) / 100)
            let rect = NSRect(x: x + gap / 2, y: 0, width: slot - gap, height: height)
            ChargeGraphView.color(for: level.charge).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(1.5, rect.width / 2), yRadius: min(1.5, rect.width / 2)).fill()
        }
    }

    /// Red at 10% and below, yellow around 35%, green from 60% up.
    static func color(for charge: Int) -> NSColor {
        let t = min(max((CGFloat(charge) - 10) / 50, 0), 1)
        return NSColor(hue: t * 0.33, saturation: 0.75, brightness: 0.95, alpha: 1)
    }
}
