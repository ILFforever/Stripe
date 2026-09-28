//
//  StripeReadouts.swift
//  Stripe
//
//  Pieces the Stripe designs of readouts share: two small lines stacked beside
//  a figure (a clock's day and date, the weather's high and low), and a
//  little bar meter (CPU), as inline pictures in a key's title, so the key lays
//  them out like any other title.
//

import AppKit

enum StripeReadout {
    static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    static let smallFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    static let dim = NSColor(white: 1, alpha: 0.55)

    /// A figure in the readouts' bold style.
    static func figure(_ text: String, color: NSColor = .white) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: figureFont, .foregroundColor: color])
    }

    /// Text in the readouts' small, dim style.
    static func small(_ text: String, color: NSColor = dim) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: smallFont, .foregroundColor: color])
    }

    /// Two small lines, one over the other, as an inline picture centered on the
    /// line it sits in.
    static func stacked(_ top: NSAttributedString, _ bottom: NSAttributedString) -> NSAttributedString {
        let lineHeight: CGFloat = 10.5
        let width = ceil(max(top.size().width, bottom.size().width))
        let size = NSSize(width: width, height: lineHeight * 2)
        let image = NSImage(size: size, flipped: true) { _ in
            top.draw(at: NSPoint(x: 0, y: -0.5))
            bottom.draw(at: NSPoint(x: 0, y: lineHeight - 0.5))
            return true
        }
        return attachment(image, size: size)
    }

    /// Four bars rising in height, filled up to `percent`, in `color`.
    static func meter(_ percent: Double, color: NSColor) -> NSAttributedString {
        let size = NSSize(width: 4 * 3 + 3 * 1.5, height: 13)
        let lit = Int((min(max(percent, 0), 100) / 25).rounded(.up))
        let image = NSImage(size: size, flipped: false) { _ in
            for bar in 0 ..< 4 {
                let height = size.height * CGFloat(bar + 1) / 4
                let rect = NSRect(x: CGFloat(bar) * 4.5, y: 0, width: 3, height: height)
                (bar < max(lit, 1) ? color : NSColor(white: 1, alpha: 0.22)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        return attachment(image, size: size)
    }

    /// A gap of `width` points in a title.
    static func gap(_ width: CGFloat) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 15), .kern: width - 4])
    }

    private static func attachment(_ image: NSImage, size: NSSize) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centered on the figures' line.
        attachment.bounds = NSRect(x: 0, y: (figureFont.capHeight - size.height) / 2, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// Colors by load, as the CPU readout uses them: white, yellow when busy, orange when heavy.
    static func loadColor(_ percent: Double) -> NSColor {
        percent > 70 ? NSColor(srgbRed: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
            : percent > 30 ? NSColor(srgbRed: 1, green: 0xD6 / 255, blue: 0x0A / 255, alpha: 1) : .white
    }
}
