//
//  ItemStyle.swift
//  Stripe
//
//  Per-item visual styling shared by every button-based item: font, text color,
//  SF Symbol icons and rounded "pill" backgrounds. Parsed from flat JSON keys:
//
//    "symbol": "cpu", "iconColor": "#34C759",
//    "fontSize": 13, "fontWeight": "semibold", "textColor": "orange",
//    "monospacedDigits": true, "cornerRadius": 8   // or "style": "pill"
//    "pressedBackground": "#636366"                 // while touched
//    "activeBackground": "green",                   // while the item is on:
//    "activeWhen": { "app": "Safari" }              //   toggles know; other items use a rule
//    "activeSymbol": "speaker.slash.fill", "activeIconColor": "red",   // and look different while on:
//    "activeTextColor": "#FFFFFF", "activeTitle": "Muted"               // icon, colors, title
//    "haptic": "press", "hapticStrength": "strong", "hapticPattern": "double"
//    "hapticToggle": false          // toggles: no on/off feel;  "hapticStep": 5   // sliders: detent every 5%
//    "hapticOnStrength": "strong", "hapticOnPattern": "double",   // toggles: the buzz for turning on…
//    "hapticOffStrength": "light", "hapticOffPattern": "single",  // …and for turning off
//

import AppKit

struct ItemStyle {
    var fontSize: CGFloat?
    var fontWeight: NSFont.Weight?
    var textColor: NSColor?
    var monospacedDigits = false
    var cornerRadius: CGFloat?
    var symbol: String?
    var iconColor: NSColor?
    var pressedBackground: NSColor?
    var activeBackground: NSColor?
    /// When the item counts as on, for items that don't know it themselves
    /// (toggles like Do Not Disturb do). Same rules as "when".
    var activeWhen: ItemCondition?
    var activeSymbol: String?
    var activeIconColor: NSColor?
    var activeTextColor: NSColor?
    var activeTitle: String?
    var haptic = HapticStyle()

    static let barHeight: CGFloat = 30
    static let defaultFontSize: CGFloat = 15

    var affectsText: Bool {
        return fontSize != nil || fontWeight != nil || textColor != nil || monospacedDigits
    }

    /// Restyles a title while keeping colors that widgets or ANSI output set
    /// deliberately: only the default white text takes `textColor`.
    func apply(to title: NSAttributedString) -> NSAttributedString {
        guard affectsText, title.length > 0 else { return title }
        let result = NSMutableAttributedString(attributedString: title)
        let whole = NSRange(location: 0, length: result.length)

        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            let current = value as? NSFont ?? NSFont.systemFont(ofSize: ItemStyle.defaultFontSize)
            let size = fontSize ?? current.pointSize
            let weight = fontWeight ?? current.weight
            let font = monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            result.addAttribute(.font, value: font, range: range)
        }

        if let textColor = textColor {
            result.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                let current = (value as? NSColor)?.usingColorSpace(.deviceRGB)
                if current == nil || current == NSColor.white.usingColorSpace(.deviceRGB) {
                    result.addAttribute(.foregroundColor, value: textColor, range: range)
                }
            }
        }
        return result
    }

    /// This style as it looks while the item is on: its "active…" keys in place of the usual ones.
    var whileActive: ItemStyle {
        var active = self
        if let symbol = activeSymbol { active.symbol = symbol }
        if let color = activeIconColor { active.iconColor = color }
        if let color = activeTextColor { active.textColor = color }
        return active
    }

    /// The SF Symbol icon, sized to sit alongside the title text.
    var symbolImage: NSImage? {
        guard let symbol = symbol,
              let base = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: (fontSize ?? ItemStyle.defaultFontSize) + 1,
                                                 weight: fontWeight ?? .regular)
        if let iconColor = iconColor, iconColor.isWhite {
            // Solid white, like the system's own keys; hierarchical would fade the
            // secondary layers (light.max's dashes).
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [iconColor]))
        } else if let iconColor = iconColor {
            // Hierarchical, not a flat palette: a filled symbol (speaker.slash.circle.fill)
            // keeps its glyph visible against a lighter shade of the same color.
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: iconColor))
        }
        let image = base.withSymbolConfiguration(config)
        image?.isTemplate = iconColor == nil // template images render white on the Touch Bar
        return image
    }
}

extension ItemStyle: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fontSize, fontWeight, textColor, monospacedDigits, cornerRadius, symbol, iconColor, style
        case pressedBackground, activeBackground, activeWhen
        case activeSymbol, activeIconColor, activeTextColor, activeTitle
        case haptic, hapticStrength, hapticPattern, hapticToggle, hapticStep
        case hapticOnStrength, hapticOnPattern, hapticOffStrength, hapticOffPattern
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        fontWeight = try c.decodeIfPresent(String.self, forKey: .fontWeight).flatMap(NSFont.Weight.init(name:))
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor)?.namedOrHexColor
        monospacedDigits = try c.decodeIfPresent(Bool.self, forKey: .monospacedDigits) ?? false
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        iconColor = try c.decodeIfPresent(String.self, forKey: .iconColor)?.namedOrHexColor
        pressedBackground = try c.decodeIfPresent(String.self, forKey: .pressedBackground)?.namedOrHexColor
        activeBackground = try c.decodeIfPresent(String.self, forKey: .activeBackground)?.namedOrHexColor
        activeWhen = try c.decodeIfPresent(ItemCondition.self, forKey: .activeWhen)
        activeSymbol = try c.decodeIfPresent(String.self, forKey: .activeSymbol)
        activeIconColor = try c.decodeIfPresent(String.self, forKey: .activeIconColor)?.namedOrHexColor
        activeTextColor = try c.decodeIfPresent(String.self, forKey: .activeTextColor)?.namedOrHexColor
        activeTitle = try c.decodeIfPresent(String.self, forKey: .activeTitle)
        haptic = HapticStyle(when: try c.decodeIfPresent(String.self, forKey: .haptic),
                             strength: try c.decodeIfPresent(String.self, forKey: .hapticStrength),
                             pattern: try c.decodeIfPresent(String.self, forKey: .hapticPattern),
                             toggle: try c.decodeIfPresent(Bool.self, forKey: .hapticToggle),
                             step: try c.decodeIfPresent(Double.self, forKey: .hapticStep),
                             onStrength: try c.decodeIfPresent(String.self, forKey: .hapticOnStrength),
                             onPattern: try c.decodeIfPresent(String.self, forKey: .hapticOnPattern),
                             offStrength: try c.decodeIfPresent(String.self, forKey: .hapticOffStrength),
                             offPattern: try c.decodeIfPresent(String.self, forKey: .hapticOffPattern))
        if try c.decodeIfPresent(String.self, forKey: .style) == "pill", cornerRadius == nil {
            cornerRadius = ItemStyle.barHeight / 2
        }
    }
}

extension NSFont {
    var weight: NSFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat).map { NSFont.Weight($0) } ?? .regular
    }
}

extension NSFont.Weight {
    init?(name: String) {
        switch name.lowercased() {
        case "ultralight": self = .ultraLight
        case "thin": self = .thin
        case "light": self = .light
        case "regular": self = .regular
        case "medium": self = .medium
        case "semibold": self = .semibold
        case "bold": self = .bold
        case "heavy": self = .heavy
        case "black": self = .black
        default: return nil
        }
    }
}

extension String {
    /// Accepts "#RRGGBB"-style hex or a macOS system color name ("green", "orange", "gray"…).
    var namedOrHexColor: NSColor? {
        let named: [String: NSColor] = [
            "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow,
            "green": .systemGreen, "mint": .systemMint, "teal": .systemTeal, "cyan": .systemCyan,
            "blue": .systemBlue, "indigo": .systemIndigo, "purple": .systemPurple,
            "pink": .systemPink, "brown": .systemBrown, "gray": .systemGray, "grey": .systemGray,
            "white": .white, "black": .black,
        ]
        return named[lowercased()] ?? hexColor
    }
}

extension NSColor {
    /// Opaque white, whichever color space it was given in.
    var isWhite: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.99 && rgb.greenComponent > 0.99 && rgb.blueComponent > 0.99 && rgb.alphaComponent > 0.99
    }
}
