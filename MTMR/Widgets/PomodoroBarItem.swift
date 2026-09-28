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
            item: .pomodoro(workTime: workTime ?? 1500.00, restTime: restTime ?? 300),
            actions: [],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        )
    }

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

    init(identifier: NSTouchBarItem.Identifier, workTime: TimeInterval, restTime: TimeInterval) {
        self.workTime = workTime
        self.restTime = restTime
        super.init(identifier: identifier, title: defaultTitle)
        showIdle()
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

    /// Stripe: a timer icon while idle; MTMR: the tomato.
    private func showIdle() {
        guard theme.stripeWidgets else {
            title = defaultTitle
            return
        }
        title = ""
        if style.symbol == nil { image = stripeSymbol("timer") }
    }

    /// Stripe: a ring that empties as the time runs out (red working, green
    /// resting), beside the time left in bold.
    private func showRunning() {
        guard theme.stripeWidgets else {
            title = defaultTitle + " " + timeLeftString
            return
        }
        let total = max(typeTime == .work ? workTime : restTime, 1)
        let color = typeTime == .rest ? NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
        image = PomodoroBarItem.ring(remaining: Double(timeLeft) / total, color: color)
        attributedTitle = StripeReadout.figure(timeLeftString)
    }

    private static func ring(remaining: Double, color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2.4
            NSColor(white: 1, alpha: 0.22).setStroke()
            track.stroke()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(max(remaining, 0), 1)), clockwise: true)
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
