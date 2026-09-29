//
//  Glass.swift
//  Stripe
//
//  Glass keys, done as glassmorphism: each key shows the bar's background
//  behind it frosted, under a translucent white fill, with a thin rim lit from
//  above. Pressing brightens it. Drawn in the key's own drawing, under its icon
//  and title. A video background changes every frame, so keys over one get the
//  fill without the frosting.
//
//  The strength is the bar's "glassStyle": subtle, balanced (the default) or strong.
//

import AppKit
import CoreImage

enum GlassStyle: String, CaseIterable {
    /// A soft frost and a light tint.
    case subtle
    /// The default: clearly frosted, patterns gone soft.
    case balanced
    /// Heavily frosted and brighter.
    case strong

    var name: String { rawValue.capitalized }

    /// The white fill over the frosted background: even across the key, so a
    /// row of keys doesn't repeat a highlight, and low, so the background
    /// showing through does the work.
    var tint: CGFloat {
        switch self {
        case .subtle: return 0.06
        case .balanced: return 0.09
        case .strong: return 0.13
        }
    }

    /// How far the background behind a key is blurred: a Gaussian sigma, in
    /// points. About the scale of the patterns (6–16 point tiles), so they're
    /// softened and still show through, not averaged away.
    var blurRadius: CGFloat? {
        switch self {
        case .subtle: return 1.5
        case .balanced: return 2.5
        case .strong: return 4.5
        }
    }
}

/// Glassmorphism for keys and groups: the background behind them frosted, a
/// translucent white fill, darkened as needed so white icons and titles keep
/// 4.5:1 contrast, and a thin rim lit from above. Flat: no glossy highlight,
/// no dark bevel.
enum GlassPainter {
    /// sRGB brightness above which white text drops below about 4.5:1.
    private static let readableCeiling: CGFloat = 0.42

    /// Draws a glass pane filling `rect` in `view`, rounded to `radius`.
    static func draw(in view: NSView, rect: NSRect, radius: CGFloat, pressed: Bool, style: GlassStyle, tint color: NSColor? = nil) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        // The background behind the pane, frosted.
        let backdrop = view.enclosingBarBackground
        let behind = backdrop.map { view.convert(rect, to: $0) }
        let frosted = behind.flatMap { _ in backdrop?.frosted(style) }
        if let frosted = frosted, let behind = behind {
            frosted.draw(in: rect, from: behind, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            // Nothing to frost (black, or a video): a darker base keeps the pane legible.
            NSColor(white: 0, alpha: 0.2).setFill()
            rect.fill()
        }

        // The fill: even across the key; brighter while pressed. Tinted glass
        // washes the pane with its color instead of white.
        let tint = style.tint + (pressed ? 0.1 : 0)
        let fillColor = color.map { $0.withAlphaComponent(min(0.32 + tint, 0.6)) } ?? NSColor(white: 1, alpha: tint)
        fillColor.setFill()
        rect.fill()

        // Darken just enough for white content to stay readable over bright backgrounds.
        let under = behind.flatMap { backdrop?.luminance(in: $0) } ?? 0
        let fillAlpha = fillColor.alphaComponent
        let fillLevel: CGFloat = color.flatMap { $0.usingColorSpace(.sRGB) }
            .map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? 1
        let glass = under * (1 - fillAlpha) + fillLevel * fillAlpha
        if glass > readableCeiling {
            NSColor(white: 0, alpha: 1 - readableCeiling / glass).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The rim: a thin, low-contrast edge lit from above, fading toward the bottom.
        let inner = max(radius - 0.5, 0)
        let rim = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: inner, cornerHeight: inner, transform: nil)
        let outline = rim.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(outline)
        context.clip()
        // The edge: the same all round, a little brighter along the top (one
        // light, above the whole bar, not a highlight repeated in each key's corner).
        let top = view.isFlipped ? rect.minY : rect.maxY, bottom = view.isFlipped ? rect.maxY : rect.minY
        NSGradient(colors: [NSColor(white: 1, alpha: pressed ? 0.45 : 0.3), NSColor(white: 1, alpha: pressed ? 0.3 : 0.16)])?
            .draw(from: NSPoint(x: rect.midX, y: top), to: NSPoint(x: rect.midX, y: bottom), options: [])
        context.restoreGState()
    }

    /// A faint shadow under a glass key's icon and title, to lift them off the glass.
    static let contentShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1
        return shadow
    }()
}

extension NSView {
    /// The bar background this view sits over, if any.
    var enclosingBarBackground: BarBackgroundView? {
        var view = superview
        while let current = view {
            if let background = current as? BarBackgroundView { return background }
            view = current.superview
        }
        return nil
    }

    /// Redraws this view and everything in it, e.g. glass keys after the
    /// background behind them changed.
    func setNeedsDisplayRecursively() {
        needsDisplay = true
        subviews.forEach { $0.setNeedsDisplayRecursively() }
    }
}

/// The background, blurred, for the glass keys over it; worked out once per
/// background, size and strength.
final class FrostCache {
    private var images: [GlassStyle: NSImage] = [:]
    // Rendered on the CPU without cached intermediates: the blur runs once per
    // background, and a default (GPU) context kept ~55 MB of GPU buffers alive
    // afterwards for the life of the app.
    private static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    /// The background at one pixel per 4 points, for how bright it is behind a key.
    private var brightness: (width: Int, height: Int, values: [CGFloat])?
    private var brightnessChecked = false

    func clear() {
        images = [:]
        brightness = nil
        brightnessChecked = false
    }

    /// Average brightness (0–1) of the background within `rect`; nil when there's
    /// none to measure (no background, or a video).
    func luminance(in rect: NSRect, background: BarBackground, size: NSSize) -> CGFloat? {
        if !brightnessChecked {
            brightnessChecked = true
            brightness = FrostCache.brightnessMap(background, size: size)
        }
        guard let map = brightness, size.width > 0, size.height > 0 else { return nil }
        let scaleX = CGFloat(map.width) / size.width, scaleY = CGFloat(map.height) / size.height
        let x0 = max(0, Int(rect.minX * scaleX)), x1 = min(map.width - 1, Int(rect.maxX * scaleX))
        let y0 = max(0, Int(rect.minY * scaleY)), y1 = min(map.height - 1, Int(rect.maxY * scaleY))
        guard x1 >= x0, y1 >= y0 else { return nil }
        var total: CGFloat = 0
        for y in y0 ... y1 { for x in x0 ... x1 { total += map.values[y * map.width + x] } }
        return total / CGFloat((x1 - x0 + 1) * (y1 - y0 + 1))
    }

    private static func brightnessMap(_ background: BarBackground, size: NSSize) -> (width: Int, height: Int, values: [CGFloat])? {
        guard let image = render(background, size: size) else { return nil }
        let width = max(1, Int(size.width / 4)), height = max(1, Int(size.height / 4))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Rows come out top first; flip them so they match the view's (unflipped) y.
        var values = [CGFloat](repeating: 0, count: width * height)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let i = ((height - 1 - row) * width + column) * 4
                let r = CGFloat(pixels[i]), g = CGFloat(pixels[i + 1]), b = CGFloat(pixels[i + 2])
                values[row * width + column] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            }
        }
        return (width, height, values)
    }

    func image(for style: GlassStyle, background: BarBackground, size: NSSize) -> NSImage? {
        guard let radius = style.blurRadius, size.width > 0, size.height > 0 else { return nil }
        if let cached = images[style] { return cached }
        guard let sharp = FrostCache.render(background, size: size),
              let blurred = FrostCache.blur(sharp, radius: radius) else { return nil }
        let image = NSImage(cgImage: blurred, size: size)
        images[style] = image
        return image
    }

    /// The background drawn at 2x, as the bar shows it; nil for none or video.
    private static func render(_ background: BarBackground, size: NSSize) -> CGImage? {
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = NSRect(origin: .zero, size: size)
        switch background {
        case .none, .video:
            NSGraphicsContext.restoreGraphicsState()
            return nil
        case let .color(color):
            color.setFill()
            rect.fill()
        case let .gradient(colors):
            NSGradient(colors: colors)?.draw(in: rect, angle: 0)
        case let .pattern(pattern, colors):
            // Tiled by hand: a pattern color in an off-screen context can come out
            // as one flat color, which leaves the glass nothing to show.
            let tile = pattern.tile(colors: colors)
            let tileSize = tile.size
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    tile.draw(in: NSRect(x: x, y: y, width: tileSize.width, height: tileSize.height))
                    x += tileSize.width
                }
                y += tileSize.height
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Blurred without darkening the edges, and a touch more saturated, as
    /// frosted glass looks.
    private static func blur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius * 2)) // at 2x
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.12])
            .cropped(to: input.extent)
        let result = context.createCGImage(blurred, from: input.extent)
        context.clearCaches()
        return result
    }
}
