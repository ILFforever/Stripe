//
//  PomodoroBarItem.swift
//  MTMR
//
//  Created by Daniel Apatin on 10.05.2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa

class PomodoroBarItem: CustomButtonTouchBarItem, Widget, TearDownable {
    func tearDown() {
        timer?.cancel()
        timer = nil
    }

    static let identifier = "com.toxblh.mtmr.pomodoro."
    static let name = "pomodoro"
    static let decoder: ParametersDecoder = { decoder in
        enum CodingKeys: String, CodingKey {
            case workTime
            case restTime
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workTime = try container.decodeIfPresent(Double.self, forKey: .workTime)
        let restTime = try container.decodeIfPresent(Double.self, forKey: .restTime)

        return (
            item: .pomodoro(workTime: workTime ?? 1500.00, restTime: restTime ?? 300, design: .icon),
            actions: [],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        )
    }

    /// Stripe's designs ("design"); the MTMR theme keeps its tomato.
    enum Design: String {
        /// A timer icon; while running, a ring emptying beside the time left.
        case icon
        /// An empty ring and the focus length, so it shows what a tap starts.
        case ready
        /// Two lines: what a tap and a hold start; while running, when it ends.
        case stacked
        /// A dark red "Focus" pill; while running, it fills as the time passes.
        case pill
    }

    /// The Start pill's color while idle (Theme's StripeKeys sets it).
    static let pillColor = NSColor(srgbRed: 0x5C / 255, green: 0x1F / 255, blue: 0x1B / 255, alpha: 1)
    private static let red = NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
    private static let green = NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)

    private enum TimeTypes {
        case work
        case rest
        case none
    }

    private let defaultTitle = "🍅 "
    private let workTime: TimeInterval
    private let restTime: TimeInterval
    private var typeTime: TimeTypes = .none {
        didSet { setBuiltInActive(typeTime != .none) }
    }
    private var timer: DispatchSourceTimer?

    private var timeLeft: Int = 0
    private var timeLeftString: String {
        return String(format: "%.2i:%.2i", timeLeft / 60, timeLeft % 60)
    }

    private let design: Design

    init(identifier: NSTouchBarItem.Identifier, workTime: TimeInterval, restTime: TimeInterval, design: Design = .icon) {
        self.workTime = workTime
        self.restTime = restTime
        self.design = design
        super.init(identifier: identifier, title: defaultTitle)
        if design == .stacked, theme.stripeWidgets { contentPadding = 10 } // room around the two lines
        showIdle()
        // Measured again whenever the key is rebuilt, e.g. once the preset's style is applied.
        finishViewConfiguration = { [weak self] in self?.holdWidth() }
        holdWidth()
        actions.append(contentsOf: [
            ItemAction(trigger: .singleTap) { [weak self] in self?.startStopWork() },
            ItemAction(trigger: .longTap) { [weak self] in self?.startStopRest() }
        ])
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.cancel()
        timer = nil
    }

    @objc func startStopWork() {
        typeTime = .work
        startStopTimer()
    }

    @objc func startStopRest() {
        typeTime = .rest
        startStopTimer()
    }

    func startStopTimer() {
        timer == nil ? start() : reset()
    }

    private func start() {
        timeLeft = Int(typeTime == .work ? workTime : restTime)
        let queue: DispatchQueue = DispatchQueue(label: "Timer")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer?.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        timer?.setEventHandler(handler: tick)
        timer?.resume()

        NSSound.beep()
    }

    private func finish() {
        if typeTime != .none {
            sendNotification()
        }

        reset()
    }

    private func reset() {
        typeTime = .none
        timer?.cancel()
        timer = nil
        showIdle()
    }

    /// The idle look in the chosen design; MTMR: the tomato.
    private func showIdle() {
        guard theme.stripeWidgets else {
            title = defaultTitle
            return
        }
        activeFill = nil
        switch design {
        case .icon:
            title = ""
            if style.symbol == nil { image = stripeSymbol("timer") }
        case .ready:
            image = PomodoroBarItem.ring(remaining: 0, color: PomodoroBarItem.red, trackAlpha: 0.35)
            attributedTitle = StripeReadout.figure(PomodoroBarItem.clock(workTime), color: StripeReadout.dim)
        case .stacked:
            if style.symbol == nil { image = stripeSymbol("timer")?.tinted(PomodoroBarItem.red) }
            attributedTitle = PomodoroBarItem.twoLines("Focus \(PomodoroBarItem.minutes(workTime))",
                                                       "Hold: \(PomodoroBarItem.minutes(restTime)) break")
        case .pill:
            if style.symbol == nil {
                image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 1, green: 0x69 / 255, blue: 0x61 / 255, alpha: 1)])))
            }
            let text = NSMutableAttributedString(string: "Focus", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            text.append(NSAttributedString(string: " \(Int(workTime / 60))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular), .foregroundColor: StripeReadout.dim,
            ]))
            attributedTitle = text
        }
    }

    /// The running look in the chosen design; red while working, green resting.
    private func showRunning() {
        guard theme.stripeWidgets else {
            title = defaultTitle + " " + timeLeftString
            return
        }
        let total = max(typeTime == .work ? workTime : restTime, 1)
        let remaining = Double(timeLeft) / total
        let color = typeTime == .rest ? PomodoroBarItem.green : PomodoroBarItem.red
        switch design {
        case .icon, .ready:
            image = PomodoroBarItem.ring(remaining: remaining, color: color)
            attributedTitle = StripeReadout.figure(timeLeftString)
        case .stacked:
            image = PomodoroBarItem.ring(remaining: remaining, color: color)
            let end = DateFormatter.localizedString(from: Date().addingTimeInterval(TimeInterval(timeLeft)),
                                                    dateStyle: .none, timeStyle: .short)
            attributedTitle = PomodoroBarItem.twoLines("\(timeLeftString) left", "\(typeTime == .rest ? "Break" : "Focus") · ends \(end)",
                                                       figure: true)
        case .pill:
            image = nil
            attributedTitle = StripeReadout.figure(timeLeftString)
            activeFill = progressFill(done: 1 - remaining, color: color.blended(withFraction: 0.45, of: .black) ?? color)
        }
    }

    private var widthConstraint: NSLayoutConstraint?
    private var measuring = false

    /// Fixes the key at the wider of its idle and running looks, so it doesn't
    /// change size when tapped. The Icon design is left alone: a small
    /// idle key is the point of it.
    private func holdWidth() {
        guard theme.stripeWidgets, design != .icon, !measuring, let button = view as? NSButton else { return }
        measuring = true
        defer { measuring = false }
        showIdle()
        let idle = button.intrinsicContentSize.width
        // The running look at its widest: the longer of the two times.
        let left = timeLeft
        timeLeft = Int(max(workTime, restTime))
        showRunning()
        let running = button.intrinsicContentSize.width
        timeLeft = left
        typeTime == .none ? showIdle() : showRunning()
        widthConstraint?.isActive = false
        // A little slack for the end time, whose width varies with the hour.
        // A fixed width, not a minimum: nothing about a tap (the shorter running
        // text, the press) may move the keys beside it.
        widthConstraint = view.widthAnchor.constraint(equalToConstant: ceil(max(idle, running)) + 4)
        // Just under required, so a "width" set in the preset still wins.
        widthConstraint?.priority = .init(999)
        widthConstraint?.isActive = true
    }

    /// The pill's background: `color` up to `done` of its width, the key's gray after.
    private func progressFill(done: Double, color: NSColor) -> NSColor? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            CustomButtonTouchBarItem.standardKeyColor.setFill()
            rect.fill()
            color.setFill()
            NSRect(x: 0, y: 0, width: rect.width * CGFloat(min(max(done, 0), 1)), height: rect.height).fill()
            return true
        }
        return NSColor(patternImage: image)
    }

    /// "25 min", or "90 s" under a minute.
    private static func minutes(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
    }

    /// "25:00".
    private static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%.2i:%.2i", Int(seconds) / 60, Int(seconds) % 60)
    }

    /// A bold line over a smaller dim one, spaced to sit clear of the key's edges.
    private static func twoLines(_ top: String, _ bottom: String, figure: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 12
        paragraph.maximumLineHeight = 12
        let text = NSMutableAttributedString(string: top, attributes: [
            .font: figure ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) : NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: "\n" + bottom, attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: StripeReadout.dim, .paragraphStyle: paragraph,
        ]))
        return text
    }

    private static func ring(remaining: Double, color: NSColor, trackAlpha: CGFloat = 0.22) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2.4
            NSColor(white: 1, alpha: trackAlpha).setStroke()
            track.stroke()
            guard remaining > 0 else { return true }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(remaining, 1)), clockwise: true)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func tick() {
        timeLeft -= 1
        DispatchQueue.main.async {
            if self.timeLeft >= 0 {
                self.showRunning()
            } else {
                self.finish()
            }
        }
    }

    private func sendNotification() {
        let notification: NSUserNotification = NSUserNotification()
        notification.title = "Pomodoro"
        notification.informativeText = typeTime == .work ? "it's time to rest your mind!" : "It's time to work!"
        notification.soundName = "Submarine"
        NSUserNotificationCenter.default.deliver(notification)
    }
}
