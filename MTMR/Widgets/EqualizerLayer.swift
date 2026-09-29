//
//  EqualizerLayer.swift
//  Stripe
//
//  Now Playing's Equalizer design: four bars that bounce while something plays,
//  and lie flat when it's paused or nothing is. On the bar they are Core
//  Animation layers, so playing costs no redraws. Settings' pictures of the bar
//  are still frames, so they draw the same bars themselves at the moment they're
//  taken (see ItemSnapshotModel.snapshot); both read their heights from one
//  function, so the preview moves the way the bar does.
//

import AppKit

final class EqualizerLayer: CALayer {
    enum State { case moving, paused, idle }

    /// The bars are 3pt wide with 2pt between, and 16pt tall at full height.
    static let barWidth: CGFloat = 3
    static let barPitch: CGFloat = 5
    static let barCount = 4
    static let height: CGFloat = 16
    /// Room between the last bar and the title beside it.
    static let trailingGap: CGFloat = 7
    /// The clear picture that holds their place in the key, so the title sits clear of them.
    static var imageSize: NSSize {
        NSSize(width: CGFloat(barCount - 1) * barPitch + barWidth + trailingGap, height: height)
    }

    private static let restingScale: CGFloat = 0.22
    /// Heights (of full) at five evenly spaced moments of each bar's loop, the last the same as the first.
    private static let shapes: [[CGFloat]] = [[0.35, 1, 0.5, 0.8, 0.35], [0.9, 0.4, 1, 0.3, 0.9],
                                              [0.25, 0.7, 0.4, 1, 0.25], [0.7, 0.3, 0.9, 0.5, 0.7]]
    /// Each bar at its own pace, so together they don't pulse in step.
    private static let periods: [CFTimeInterval] = [0.9, 1.1, 0.8, 1.0]

    private(set) var state: State?
    /// When the bars began to move, so a still picture can catch up to where the animation is.
    private var movingSince: CFTimeInterval = 0

    override init() {
        super.init()
        name = ItemSnapshotModel.liveOverlayName
        for _ in 0 ..< EqualizerLayer.barCount {
            let bar = CALayer()
            bar.cornerRadius = EqualizerLayer.barWidth / 2
            addSublayer(bar)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Heights

    /// How tall bar `bar` is (of full) `phase` of the way (0…1) through its loop.
    static func scale(bar: Int, phase: Double) -> CGFloat {
        let points = shapes[bar]
        let segments = points.count - 1
        let position = phase * Double(segments)
        let index = min(Int(position), segments - 1)
        // Eased between the moments, so the bar slows as it turns.
        let eased = (1 - cos((position - Double(index)) * .pi)) / 2
        return points[index] + (points[index + 1] - points[index]) * CGFloat(eased)
    }

    /// How tall bar `bar` is at `time` (CACurrentMediaTime): moving, from the loop; else resting.
    func scale(bar: Int, at time: CFTimeInterval) -> CGFloat {
        guard state == .moving else { return EqualizerLayer.restingScale }
        let period = EqualizerLayer.periods[bar]
        let phase = ((time - movingSince) / period).truncatingRemainder(dividingBy: 1)
        return EqualizerLayer.scale(bar: bar, phase: phase < 0 ? phase + 1 : phase)
    }

    private static func color(for state: State) -> NSColor {
        switch state {
        case .moving: return NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
        case .paused: return NSColor(white: 1, alpha: 0.4)
        case .idle: return NSColor(white: 1, alpha: 0.25)
        }
    }

    // MARK: On the bar

    /// Sets what the bars show; moving starts the animation, the others lie flat.
    func apply(_ newState: State) {
        guard newState != state else { return }
        state = newState
        movingSince = CACurrentMediaTime()
        let color = EqualizerLayer.color(for: newState)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in (sublayers ?? []).enumerated() {
            bar.backgroundColor = color.cgColor
            bar.removeAllAnimations()
            if newState == .moving {
                // The same curve the pictures draw, sampled.
                let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
                bounce.values = (0 ... 48).map { EqualizerLayer.scale(bar: index, phase: Double($0) / 48) }
                bounce.duration = EqualizerLayer.periods[index]
                bounce.repeatCount = .infinity
                bounce.calculationMode = .linear
                bar.add(bounce, forKey: "bounce")
                bar.transform = CATransform3DIdentity
            } else {
                bar.transform = CATransform3DMakeScale(1, EqualizerLayer.restingScale, 1)
            }
        }
        CATransaction.commit()
    }

    /// Lays the bars out in `rect` (where the key's image is), each centered vertically so they
    /// grow and shrink about the middle.
    func place(in rect: NSRect) {
        frame = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in (sublayers ?? []).enumerated() {
            let transform = bar.transform
            bar.transform = CATransform3DIdentity
            bar.frame = NSRect(x: CGFloat(index) * EqualizerLayer.barPitch, y: 0,
                               width: EqualizerLayer.barWidth, height: rect.height)
            bar.transform = transform
        }
        CATransaction.commit()
    }

    // MARK: In a picture

    /// Draws the bars as they are at `time`, in the current graphics context, with the layer
    /// at `frame` (the picture's coordinates, y up).
    func drawStill(in frame: NSRect, at time: CFTimeInterval) {
        guard let state = state else { return }
        EqualizerLayer.color(for: state).setFill()
        for index in 0 ..< EqualizerLayer.barCount {
            let height = frame.height * scale(bar: index, at: time)
            let rect = NSRect(x: frame.minX + CGFloat(index) * EqualizerLayer.barPitch, y: frame.midY - height / 2,
                              width: EqualizerLayer.barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: EqualizerLayer.barWidth / 2, yRadius: EqualizerLayer.barWidth / 2).fill()
        }
    }

    /// Whether the bars are moving, so a picture of the bar needs retaking to stay current.
    var isMoving: Bool { state == .moving }
}
