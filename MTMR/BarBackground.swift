//
//  BarBackground.swift
//  Stripe
//
//  What the bar shows behind its items: black (the default), a color, a
//  gradient, a pattern, or a looping video. It fills the part of the bar Stripe
//  draws (everything right of the Esc key). Set per bar, in the preset's "bar":
//
//    "bar": { "background": { "gradient": ["#5A1A73", "#0D3366"] }, "glassKeys": true }
//    "background": { "color": "#1A2440" }
//    "background": { "pattern": "honeycomb", "colors": ["#141414", "#262626"] }   // see BarPattern
//    "background": { "video": "Waves.mov", "pauseOnBattery": true }   // in Stripe's Backgrounds folder
//

import AVFoundation
import Cocoa
import IOKit.ps

/// A bar's own settings, kept with its items in the preset.
struct BarSettings: Equatable {
    var background: BarBackground = .none
    /// Keys drawn as translucent glass, so the background shows through.
    var glassKeys = false
    /// A video background stops while the Mac runs on battery.
    var pauseVideoOnBattery = true
    /// How strong glass keys are (see Glass.swift).
    var glassStyle = GlassStyle.balanced
    /// A color every glass key is tinted with, unless it has its own.
    var glassTint: NSColor?

    static let backgroundsFolder = appSupportDirectory + "/Backgrounds"

    init() {}

    /// From the preset's "bar" object; anything missing or unreadable stays at its default.
    init(json: [String: Any]) {
        glassKeys = json["glassKeys"] as? Bool ?? false
        glassStyle = (json["glassStyle"] as? String).flatMap(GlassStyle.init(rawValue:)) ?? .balanced
        glassTint = (json["glassTint"] as? String)?.namedOrHexColor
        guard let background = json["background"] as? [String: Any] else { return }
        pauseVideoOnBattery = background["pauseOnBattery"] as? Bool ?? true
        let colors = (background["colors"] as? [String])?.compactMap { $0.namedOrHexColor } ?? []
        if let color = (background["color"] as? String)?.namedOrHexColor {
            self.background = .color(color)
        } else if let gradient = (background["gradient"] as? [String])?.compactMap({ $0.namedOrHexColor }), gradient.count >= 2 {
            self.background = .gradient(gradient)
        } else if let name = background["pattern"] as? String, let pattern = BarPattern(rawValue: name) {
            self.background = .pattern(pattern, colors)
        } else if let name = background["video"] as? String {
            self.background = .video(URL(fileURLWithPath: BarSettings.backgroundsFolder + "/" + name))
        }
    }
}

/// The built-in patterns, drawn from two colors (background, lines) as small
/// seamless tiles, so they stay crisp at the bar's 30 points.
enum BarPattern: String, CaseIterable {
    case stripes, grid, dots, carbon, checker, crosshatch, diamonds, zigzag, waves, honeycomb, bricks, rings, plaid, grain

    var name: String { rawValue.capitalized }

    static let defaultColors = [NSColor(white: 0.08, alpha: 1), NSColor(white: 0.2, alpha: 1)]

    private var tileSize: NSSize {
        switch self {
        case .carbon: return NSSize(width: 8, height: 8)
        case .checker: return NSSize(width: 8, height: 8)
        case .crosshatch: return NSSize(width: 10, height: 10)
        case .zigzag: return NSSize(width: 12, height: 8)
        case .waves, .bricks: return NSSize(width: 16, height: 8)
        case .honeycomb: return NSSize(width: (3.0.squareRoot() * 5).rounded(), height: 15)
        case .rings: return NSSize(width: 14, height: 14)
        case .plaid: return NSSize(width: 16, height: 16)
        case .grain: return NSSize(width: 32, height: 32)
        default: return NSSize(width: 12, height: 12)
        }
    }

    func tile(colors: [NSColor]) -> NSImage {
        let back = colors.first ?? BarPattern.defaultColors[0]
        let front = colors.count > 1 ? colors[1] : BarPattern.defaultColors[1]
        let size = tileSize
        return NSImage(size: size, flipped: false) { rect in
            back.setFill()
            rect.fill()
            front.setFill()
            front.setStroke()
            let w = size.width, h = size.height
            func stroke(_ points: [NSPoint], width: CGFloat = 1.5) {
                let path = NSBezierPath()
                path.lineWidth = width
                path.lineJoinStyle = .round
                path.move(to: points[0])
                points.dropFirst().forEach { path.line(to: $0) }
                path.stroke()
            }
            switch self {
            case .stripes:
                stroke([NSPoint(x: -2, y: -2), NSPoint(x: w + 2, y: h + 2)], width: 2)
            case .grid:
                NSRect(x: 0, y: 0, width: w, height: 1).fill()
                NSRect(x: 0, y: 0, width: 1, height: h).fill()
            case .dots:
                NSBezierPath(ovalIn: NSRect(x: w / 2 - 1.5, y: h / 2 - 1.5, width: 3, height: 3)).fill()
            case .carbon:
                // A basketweave: pairs of short strands, alternating direction, like carbon fibre.
                let cell = w / 2
                for (x, y, across) in [(0.0, 0.0, true), (cell, 0.0, false), (0.0, cell, false), (cell, cell, true)] {
                    for strand in 0 ..< 2 {
                        let offset = CGFloat(strand) * cell / 2 + 0.5
                        if across {
                            NSRect(x: x, y: y + offset, width: cell, height: 1.2).fill()
                        } else {
                            NSRect(x: x + offset, y: y, width: 1.2, height: cell).fill()
                        }
                    }
                }
            case .checker:
                NSRect(x: 0, y: 0, width: w / 2, height: h / 2).fill()
                NSRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2).fill()
            case .crosshatch:
                stroke([NSPoint(x: -1, y: -1), NSPoint(x: w + 1, y: h + 1)], width: 1)
                stroke([NSPoint(x: -1, y: h + 1), NSPoint(x: w + 1, y: -1)], width: 1)
            case .diamonds:
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: w / 2, y: 1.5))
                diamond.line(to: NSPoint(x: w - 1.5, y: h / 2))
                diamond.line(to: NSPoint(x: w / 2, y: h - 1.5))
                diamond.line(to: NSPoint(x: 1.5, y: h / 2))
                diamond.close()
                diamond.fill()
            case .zigzag:
                stroke([NSPoint(x: 0, y: 2), NSPoint(x: w / 2, y: h - 2), NSPoint(x: w, y: 2)])
            case .waves:
                let wave = NSBezierPath()
                wave.lineWidth = 1.5
                wave.move(to: NSPoint(x: 0, y: h / 2))
                wave.curve(to: NSPoint(x: w / 2, y: h / 2), controlPoint1: NSPoint(x: w / 4, y: h - 1), controlPoint2: NSPoint(x: w / 4, y: h - 1))
                wave.curve(to: NSPoint(x: w, y: h / 2), controlPoint1: NSPoint(x: 3 * w / 4, y: 1), controlPoint2: NSPoint(x: 3 * w / 4, y: 1))
                wave.stroke()
            case .honeycomb:
                // Pointy-top hexagons of radius 5, a tile holding the parts of four.
                let r: CGFloat = 5
                for center in [NSPoint(x: w / 2, y: 0), NSPoint(x: 0, y: 1.5 * r), NSPoint(x: w, y: 1.5 * r), NSPoint(x: w / 2, y: 3 * r)] {
                    let corners = (0 ... 6).map { k -> NSPoint in
                        let angle = CGFloat.pi / 6 + CGFloat(k) * .pi / 3
                        return NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                    }
                    stroke(corners, width: 1)
                }
            case .bricks:
                NSRect(x: 0, y: 0, width: w, height: 1).fill()
                NSRect(x: 0, y: h / 2, width: w, height: 1).fill()
                NSRect(x: 0, y: 0, width: 1, height: h / 2).fill()
                NSRect(x: w / 2, y: h / 2, width: 1, height: h / 2).fill()
            case .rings:
                let ring = NSBezierPath(ovalIn: NSRect(x: w / 2 - 4, y: h / 2 - 4, width: 8, height: 8))
                ring.lineWidth = 1.2
                ring.stroke()
            case .plaid:
                front.withAlphaComponent(0.45).setFill()
                NSRect(x: 0, y: 5, width: w, height: 4).fill()
                NSRect(x: 5, y: 0, width: 4, height: h).fill()
                front.setFill()
                NSRect(x: 0, y: 13, width: w, height: 1).fill()
                NSRect(x: 13, y: 0, width: 1, height: h).fill()
            case .grain:
                // Speckles from a fixed seed, so the tile is the same every time.
                var seed: UInt32 = 0x9E3779B9
                func next() -> CGFloat {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    return CGFloat(seed >> 8) / CGFloat(1 << 24)
                }
                for _ in 0 ..< 90 {
                    front.withAlphaComponent(0.3 + 0.7 * next()).setFill()
                    NSRect(x: (next() * w).rounded(.down), y: (next() * h).rounded(.down), width: 1, height: 1).fill()
                }
            }
            return true
        }
    }
}

enum BarBackground: Equatable {
    case none
    case color(NSColor)
    /// Left to right.
    case gradient([NSColor])
    /// A built-in pattern in two colors (background, lines), repeated across the bar.
    case pattern(BarPattern, [NSColor])
    /// A video file, looping, muted.
    case video(URL)

    static func == (lhs: BarBackground, rhs: BarBackground) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case let (.color(a), .color(b)): return a == b
        case let (.gradient(a), .gradient(b)): return a == b
        case let (.pattern(a, c), .pattern(b, d)): return a == b && c == d
        case let (.video(a), .video(b)): return a == b
        default: return false
        }
    }
}

/// Holds the bar's items over its background.
final class BarBackgroundView: NSView {
    var background: BarBackground = .none {
        didSet {
            guard background != oldValue else { return }
            apply()
            frost.clear()
            setNeedsDisplayRecursively() // glass keys show the new background
        }
    }

    private let frost = FrostCache()
    private var frostSize = NSSize.zero

    /// The background blurred for glass keys of this strength; nil when there's
    /// nothing to blur (no background, or a video).
    func frosted(_ style: GlassStyle) -> NSImage? {
        frost.image(for: style, background: background, size: bounds.size)
    }

    /// How bright the background is within `rect` (0–1), for glass keys to stay readable.
    func luminance(in rect: NSRect) -> CGFloat? {
        frost.luminance(in: rect, background: background, size: bounds.size)
    }

    /// Stops a video while on battery; checked every half minute while one plays.
    var pausesVideoOnBattery = true {
        didSet { updateVideoPlayback() }
    }

    private var gradientLayer: CAGradientLayer?
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?
    private var powerTimer: Timer?

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if bounds.size != frostSize {
            frostSize = bounds.size
            frost.clear()
            setNeedsDisplayRecursively()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer?.frame = bounds
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    private func apply() {
        guard let layer = layer else { return }
        layer.backgroundColor = nil
        gradientLayer?.removeFromSuperlayer()
        gradientLayer = nil
        stopVideo()
        switch background {
        case .none:
            break
        case let .color(color):
            layer.backgroundColor = color.cgColor
        case let .gradient(colors):
            let gradient = CAGradientLayer()
            gradient.colors = colors.map { $0.cgColor }
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.frame = bounds
            layer.insertSublayer(gradient, at: 0)
            gradientLayer = gradient
        case let .pattern(pattern, colors):
            layer.backgroundColor = NSColor(patternImage: pattern.tile(colors: colors)).cgColor
        case let .video(url):
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            // Only as many pixels as the bar needs, whatever the file's size.
            item.preferredMaximumResolution = CGSize(width: 2008, height: 60)
            looper = AVPlayerLooper(player: player, templateItem: item)
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = bounds
            layer.insertSublayer(playerLayer, at: 0)
            self.playerLayer = playerLayer
            updateVideoPlayback()
            powerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.updateVideoPlayback()
            }
        }
    }

    private func updateVideoPlayback() {
        guard let player = playerLayer?.player else { return }
        let onBattery = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
        if pausesVideoOnBattery && onBattery { player.pause() } else { player.play() }
    }

    private func stopVideo() {
        powerTimer?.invalidate()
        powerTimer = nil
        playerLayer?.player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        looper = nil
    }
}
