//
//  BatteryBarItem.swift
//  MTMR
//
//  Created by Anton Palgunov on 18/04/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//
//  Stripe: a drawn battery icon whose fill tracks the charge (green while
//  charging, yellow in Low Power Mode, red when low, with a sweep animation
//  while charging), plus optional percentage and time remaining. Tapping can
//  switch to time remaining and back; holding opens the battery panel across the
//  bar (BatteryPanel.swift), Battery settings ("holdOpens": "settings"), or
//  nothing ("holdOpens": "nothing").
//
//    { "type": "battery", "showIcon": true, "showPercentage": true,
//      "percentInside": false, "showTime": false, "animate": true,
//      "lowThreshold": 20, "tapToCycle": true, "holdOpens": "details",
//      "panelTiles": ["charge", "graph", "power", "since", "apps"],
//      "panelGraphHours": 12, "panelBarMinutes": 30, "panelCloseSide": "right" }
//

import Cocoa
import IOKit.ps

struct BatteryOptions {
    var showIcon = true
    var showPercentage = true
    /// Draw the percentage inside the icon, as on iPhone.
    var percentInside = false
    var showTime = false
    var animate = true
    var lowThreshold = 20
    var tapToCycle = true
    enum HoldAction: String {
        case details, settings, nothing
    }

    var holdAction = HoldAction.details
    var panel = BatteryPanelOptions()
}

class BatteryBarItem: CustomButtonTouchBarItem, TearDownable {
    private let batteryInfo = BatteryInfo()
    private let options: BatteryOptions
    /// What holding opens, for the debug hook to open the same thing.
    var panelOptions: BatteryPanelOptions { options.panel }

    /// Whether a tap has switched to time remaining; otherwise shows what the options say.
    private var showingTimeLeft = false

    /// The charging sweep: a soft light band sliding across the fill, run by
    /// Core Animation over the static icon, so nothing is redrawn per frame.
    private let sweepClip = CALayer()
    private let sweepBand = CAGradientLayer()
    private static let bandWidth: CGFloat = 8

    init(identifier: NSTouchBarItem.Identifier, options: BatteryOptions) {
        self.options = options
        super.init(identifier: identifier, title: " ")
        contentPadding = 8 // match the breathing room of the icon keys around it

        if options.tapToCycle {
            actions.append(ItemAction(trigger: .singleTap) { [weak self] in self?.cycle() })
        }
        switch options.holdAction {
        case .details:
            let panel = options.panel
            actions.append(ItemAction(trigger: .longTap) { BatteryPanel.shared.open(options: panel) })
            BatteryHistory.shared.start() // so the panel's graph has something to show
        case .settings:
            actions.append(ItemAction(trigger: .longTap) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            })
        case .nothing:
            break
        }

        sweepClip.masksToBounds = true
        sweepBand.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.65).cgColor,
                            NSColor(white: 1, alpha: 0).cgColor]
        sweepBand.startPoint = CGPoint(x: 0, y: 0.5)
        sweepBand.endPoint = CGPoint(x: 1, y: 0.5)
        sweepClip.addSublayer(sweepBand)
        (view as? CustomHeightButton)?.onLayout = { [weak self] in self?.placeSweep() }

        batteryInfo.start { [weak self] in
            self?.refresh()
        }
        // Low Power Mode changes the fill color but doesn't post a battery notification.
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromNotification),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        batteryInfo.stop()
        sweepClip.removeFromSuperlayer()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: What's shown

    private struct Display {
        var icon: Bool
        var percentage: Bool
        var time: Bool
    }

    /// Tapping switches between the battery (as the options configure it) and
    /// time remaining.
    private var display: Display {
        if showingTimeLeft {
            return Display(icon: options.showIcon, percentage: false, time: true)
        }
        return Display(icon: options.showIcon, percentage: options.showPercentage, time: options.showTime)
    }

    private func cycle() {
        showingTimeLeft.toggle()
        refresh()
    }

    @objc private func refreshFromNotification() {
        DispatchQueue.main.async { self.refresh() }
    }

    func refresh() {
        batteryInfo.getPSInfo()
        let display = self.display
        let showPercentInside = display.icon && display.percentage && options.percentInside

        guard theme.drawnBattery else {
            // The MTMR theme: MTMR's text battery.
            image = nil
            attributedTitle = mtmrTitle
            updateAnimation()
            return
        }
        image = display.icon ? batteryIcon(percentInside: showPercentInside) : nil

        var parts: [String] = []
        if display.percentage && !showPercentInside { parts.append("\(batteryInfo.current)%") }
        if display.time { parts.append(batteryInfo.timeDescription) }
        let text = parts.joined(separator: "  ")
        let title = NSMutableAttributedString(attributedString: text.defaultTouchbarAttributedString)
        if isLow {
            title.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: title.length))
        }
        attributedTitle = title

        updateAnimation()
    }

    /// How MTMR showed the battery: "⚡️64%" while charging, with the time
    /// remaining small and raised beside it, and red at 10% and below.
    private var mtmrTitle: NSAttributedString {
        let onAC = batteryInfo.onACPower
        let percent = batteryInfo.current
        let minutes = onAC ? batteryInfo.timeToFull : batteryInfo.timeToEmpty
        let color: NSColor = percent <= 10 && !onAC ? .red : .white
        let title = NSMutableAttributedString(string: (onAC && percent < 100 ? "⚡️" : "") + "\(percent)%", attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 15), .baselineOffset: 1,
        ])
        if minutes > 0 {
            title.append(NSAttributedString(string: String(format: " %d:%02d", minutes / 60, minutes % 60), attributes: [
                .foregroundColor: color, .font: NSFont.systemFont(ofSize: 8), .baselineOffset: 7,
            ]))
        }
        return title
    }

    // MARK: Icon

    private var isLow: Bool {
        return !batteryInfo.onACPower && batteryInfo.current <= options.lowThreshold
    }

    private var fillColor: NSColor {
        if batteryInfo.isCharging || (batteryInfo.onACPower && batteryInfo.current >= 100) { return .systemGreen }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .systemYellow }
        if isLow { return .systemRed }
        return .white
    }

    /// The icon's body size; inside-percentage icons are larger, and wider still
    /// with a bolt beside the number.
    private func bodySize(percentInside: Bool) -> NSSize {
        return percentInside ? NSSize(width: batteryInfo.onACPower ? 40 : 34, height: 16) : NSSize(width: 27, height: 13)
    }

    /// Where the fill is drawn within the icon, and its corner radius.
    private func fillRect(bodySize: NSSize) -> (rect: NSRect, radius: CGFloat) {
        let body = NSRect(origin: .zero, size: bodySize).insetBy(dx: 0.5, dy: 0.5)
        let inner = body.insetBy(dx: 2, dy: 2)
        let innerRadius = max(bodySize.height * 0.3 - 2, 1)
        let level = CGFloat(max(0, min(100, batteryInfo.current))) / 100
        var filled = inner
        filled.size.width = max(inner.width * level, level > 0 ? innerRadius * 2 : 0)
        return (filled, innerRadius)
    }

    private func batteryIcon(percentInside: Bool) -> NSImage {
        let bodySize = self.bodySize(percentInside: percentInside)
        let size = NSSize(width: bodySize.width + 3, height: bodySize.height)
        let fill = fillColor
        let charging = batteryInfo.isCharging
        let onAC = batteryInfo.onACPower
        let percent = batteryInfo.current
        let (filled, innerRadius) = fillRect(bodySize: bodySize)

        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(origin: .zero, size: bodySize).insetBy(dx: 0.5, dy: 0.5)
            let radius = bodySize.height * 0.3

            // Outline and the terminal nub.
            NSColor(white: 1, alpha: 0.45).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            outline.lineWidth = 1
            outline.stroke()
            let nub = NSRect(x: bodySize.width + 0.5, y: bodySize.height * 0.32, width: 2, height: bodySize.height * 0.36)
            NSColor(white: 1, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: nub, xRadius: 1, yRadius: 1).fill()

            // Fill proportional to the charge (the charging sweep is layered over it; see placeSweep).
            fill.setFill()
            NSBezierPath(roundedRect: filled, xRadius: innerRadius, yRadius: innerRadius).fill()

            if percentInside {
                // Dark text on the fill reads well on every fill color.
                // White with a soft shadow reads over the fill and the empty part alike.
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(white: 0, alpha: 0.7)
                shadow.shadowBlurRadius = 1.5
                let text = NSAttributedString(string: "\(percent)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .shadow: shadow,
                ])
                let textSize = text.size()
                let x = body.midX - textSize.width / 2 - (onAC ? 5 : 0)
                text.draw(at: NSPoint(x: x, y: body.midY - textSize.height / 2))
            }

            if onAC {
                // A bolt while plugged in, outlined so it shows over any fill.
                let boltSize = bodySize.height * (percentInside ? 0.6 : 0.95)
                let config = NSImage.SymbolConfiguration(pointSize: boltSize, weight: .black)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [charging ? .white : NSColor(white: 1, alpha: 0.9)]))
                if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Charging")?
                    .withSymbolConfiguration(config) {
                    let b = bolt.size
                    let x = percentInside ? body.maxX - b.width - 4 : body.midX - b.width / 2
                    let rect = NSRect(x: x, y: body.midY - b.height / 2, width: b.width, height: b.height)
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor(white: 0, alpha: 0.9)
                    shadow.shadowBlurRadius = 1.5
                    shadow.set()
                    bolt.draw(in: rect)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Animation

    private var animating: Bool {
        return options.animate && display.icon && batteryInfo.isCharging && batteryInfo.current < 100
    }

    private func updateAnimation() {
        placeSweep()
    }

    /// Lays the sweep over the icon's fill while charging, and removes it otherwise.
    /// Called on every refresh and layout, since the fill's size and place change.
    private func placeSweep() {
        guard animating, let button = view as? NSButton, let cell = button.cell, button.image != nil else {
            if sweepClip.superlayer != nil { sweepClip.removeFromSuperlayer() }
            return
        }
        button.wantsLayer = true
        guard let host = button.layer else { return }
        let bodySize = self.bodySize(percentInside: display.percentage && options.percentInside)
        let (fill, radius) = fillRect(bodySize: bodySize)
        let imageRect = cell.imageRect(forBounds: button.bounds)
        // The fill is centred vertically in the icon, so this holds whether or
        // not the layer's geometry is flipped.
        let frame = NSRect(x: imageRect.minX + fill.minX, y: imageRect.midY - fill.height / 2,
                           width: fill.width, height: fill.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if sweepClip.superlayer !== host { host.addSublayer(sweepClip) }
        let changed = sweepClip.frame != frame
        sweepClip.frame = frame
        sweepClip.cornerRadius = radius
        sweepBand.frame = CGRect(x: -BatteryBarItem.bandWidth, y: 0, width: BatteryBarItem.bandWidth, height: frame.height)
        CATransaction.commit()

        guard changed || sweepBand.animation(forKey: "sweep") == nil else { return }
        // About two seconds per sweep, then a short pause.
        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        let start = -BatteryBarItem.bandWidth / 2, end = frame.width + BatteryBarItem.bandWidth / 2
        sweep.values = [start, end, end]
        sweep.keyTimes = [0, 0.77, 1]
        sweep.duration = 2.6
        sweep.repeatCount = .infinity
        sweepBand.add(sweep, forKey: "sweep")
    }
}

class BatteryInfo: NSObject {
    var current: Int = 0
    var timeToEmpty: Int = 0
    var timeToFull: Int = 0
    var isCharged: Bool = false
    var isCharging: Bool = false
    var ACPower: String = ""
    var notifyBlock: () -> Void = {}
    var loop: CFRunLoopSource?

    var onACPower: Bool { ACPower == kIOPSACPowerValue }

    func start(notifyBlock: @escaping () -> Void) {
        self.notifyBlock = notifyBlock
        // Unretained: the item owns this object and calls stop() before releasing it.
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else {
                return
            }

            let watcher = Unmanaged<BatteryInfo>.fromOpaque(ctx).takeUnretainedValue()
            watcher.notifyBlock()
        }, context).takeRetainedValue() as CFRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), loop, CFRunLoopMode.defaultMode)
    }

    func stop() {
        notifyBlock = {}
        guard let loop = self.loop else {
            return
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), loop, CFRunLoopMode.defaultMode)
        self.loop = nil
    }

    func getPSInfo() {
        let psInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let psList = IOPSCopyPowerSourcesList(psInfo).takeRetainedValue() as [CFTypeRef]

        for ps in psList {
            if let psDesc = IOPSGetPowerSourceDescription(psInfo, ps).takeUnretainedValue() as? [String: Any] {
                if let current = psDesc[kIOPSCurrentCapacityKey] as? Int {
                    self.current = current
                }

                if let timeToEmpty = psDesc[kIOPSTimeToEmptyKey] as? Int {
                    self.timeToEmpty = timeToEmpty
                }

                if let timeToFull = psDesc[kIOPSTimeToFullChargeKey] as? Int {
                    self.timeToFull = timeToFull
                }

                if let isCharged = psDesc[kIOPSIsChargedKey] as? Bool {
                    self.isCharged = isCharged
                }

                if let isCharging = psDesc[kIOPSIsChargingKey] as? Bool {
                    self.isCharging = isCharging
                }

                if let ACPower = psDesc[kIOPSPowerSourceStateKey] as? String {
                    self.ACPower = ACPower
                }
            }
        }
    }

    /// e.g. "2:05 left", "0:40 to full", "Charged", or "—" while macOS is still estimating.
    var timeDescription: String {
        if onACPower {
            if isCharged || current >= 100 { return "Charged" }
            return timeToFull > 0 ? String(format: "%d:%02d to full", timeToFull / 60, timeToFull % 60) : "—"
        }
        return timeToEmpty > 0 ? String(format: "%d:%02d left", timeToEmpty / 60, timeToEmpty % 60) : "—"
    }
}
