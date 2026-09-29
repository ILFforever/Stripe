//
//  Theme.swift
//  Stripe
//
//  How Stripe draws what it draws itself. Two themes:
//
//  - Stripe: the current look.
//  - MTMR: the classic look, restoring how MTMR drew the things it had: a text
//    battery ("⚡️64%" with the time raised beside it), "⏳" placeholders while
//    widgets load, static play/pause and mute icons, and plain sliders.
//
//  Chosen per item ("theme": "mtmr"; Stripe when unset), in Settings on the
//  item's Style tab. Features new in Stripe (groups, popovers, the Battery
//  Overview…) look the same in both, and styles set on an item in the preset
//  always win over the theme.
//

import AppKit

struct Theme {
    enum Name: String, CaseIterable {
        case stripe, mtmr

        var title: String {
            switch self {
            case .stripe: return "Stripe"
            case .mtmr: return "MTMR"
            }
        }
    }

    let name: Name

    /// The battery as a drawn icon (Stripe) rather than text (MTMR).
    var drawnBattery = true
    /// Widgets stay hidden until their first value, then fade in (Stripe),
    /// rather than showing "⏳" meanwhile (MTMR).
    var fadeInFirstTitle = true
    /// Play/pause lights the half a tap will do (Stripe); MTMR's icon is static.
    var litPlayPause = true
    /// Mute's icon follows the volume (Stripe); MTMR's is a static mute icon.
    var liveMuteIcon = true
    /// Sliders sit on a panel with icons at each end (Stripe); MTMR's are plain.
    var sliderPanels = true
    /// Keys and buttons drawn Stripe's way (see StripeKeys); MTMR's as MTMR drew them.
    var restyledKeys = true
    /// Readouts and toggles in Stripe's designs (clock with its date, CPU with a
    /// meter, colored network arrows, toggles lit when on…); MTMR's as it had them.
    var stripeWidgets = true

    struct CloseButton {
        var background: NSColor
        var glyph: NSColor
        var diameter: CGFloat
        var glyphSize: CGFloat
        /// Extra space between the close button and the controls it closes.
        var gap: CGFloat
    }

    var closeButton: CloseButton

    /// Matches macOS's own Touch Bar controls (measured from the system volume
    /// control): a small light-gray circle with a bold black ✕.
    static let stripe = Theme(
        name: .stripe,
        closeButton: CloseButton(
            background: NSColor(srgbRed: 0xC0 / 255, green: 0xC0 / 255, blue: 0xC0 / 255, alpha: 1),
            glyph: .black,
            diameter: 22,
            glyphSize: 10,
            gap: 20
        )
    )

    static let mtmr = Theme(name: .mtmr, drawnBattery: false, fadeInFirstTitle: false, litPlayPause: false,
                            liveMuteIcon: false, sliderPanels: false, restyledKeys: false, stripeWidgets: false, closeButton: stripe.closeButton)

    static func named(_ name: Name) -> Theme {
        return name == .mtmr ? mtmr : stripe
    }

    /// The theme of the item being built (TouchBarController.createItem sets
    /// it around each item), else Stripe's. Items keep the one they were built
    /// with (CustomButtonTouchBarItem.theme).
    static var current: Theme {
        return building ?? stripe
    }

    static var building: Theme?
}

/// Stripe's look for keys and buttons. Only fills in what the preset leaves
/// unset, so an item's own settings always win.
enum StripeKeys {
    /// Text buttons are pills.
    static let pillTypes: Set<String> = ["staticButton", "appleScriptTitledButton", "inputsource"]
    static let pillRadius = ItemStyle.barHeight / 2
    static let standardRadius: CGFloat = 6

    /// SF Symbols in place of MTMR's pictures, matching the system's own keys.
    private static let symbols = [
        "brightnessDown": "sun.min", "brightnessUp": "sun.max",
        "illuminationDown": "light.min", "illuminationUp": "light.max",
        "delete": "delete.left",
        "sleep": "moon.zzz", "displaySleep": "display",
        "volumeDown": "speaker.wave.1.fill", "volumeUp": "speaker.wave.3.fill",
        "close": "chevron.left",
    ]

    /// Toggles sit on a key in Stripe's design, lit in their own color while on.
    static let toggleColors: [String: NSColor] = [
        "dnd": NSColor(srgbRed: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255, alpha: 1),
        "nightShift": NSColor(srgbRed: 0xC4 / 255, green: 0x72 / 255, blue: 0x1A / 255, alpha: 1),
        "darkMode": NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 1, alpha: 1),
        "mute": NSColor(srgbRed: 0xC0 / 255, green: 0x39 / 255, blue: 0x2B / 255, alpha: 1),
    ]
    /// Toggles MTMR drew without a key, which Stripe puts on one.
    static let keyedToggles: Set<String> = ["dnd", "nightShift", "darkMode"]
    /// Items MTMR put on a key, which Stripe sits straight on the bar: readouts,
    /// and a folder's close chevron.
    static let bareReadouts: Set<String> = ["network", "weather", "yandexWeather", "currency", "close"]

    static func apply(to button: CustomButtonTouchBarItem, definition: BarItemDefinition) {
        let type = definition.typeName
        var style = button.style
        if Theme.current.stripeWidgets {
            if let color = toggleColors[type], style.activeBackground == nil { style.activeBackground = color }
            if keyedToggles.contains(type), definition.additionalParameters[.bordered] == nil,
               definition.additionalParameters[.background] == nil {
                button.isBordered = true
            }
            // Readouts sit straight on the bar, like the CPU.
            if bareReadouts.contains(type), definition.additionalParameters[.bordered] == nil,
               definition.additionalParameters[.background] == nil {
                button.isBordered = false
            }
        }
        // A folder shows its icon beside its name.
        if type == "group", Theme.current.stripeWidgets, style.symbol == nil, definition.additionalParameters[.image] == nil {
            style.symbol = "folder.fill"
        }
        if let symbol = symbols[type], style.symbol == nil {
            style.symbol = symbol
            if ["delete", "sleep", "displaySleep"].contains(type), definition.additionalParameters[.title] == nil { button.title = "" }
        }
        if type == "escape" || type == "group" || pillTypes.contains(type) {
            style.fontWeight = style.fontWeight ?? .medium
        }
        if pillTypes.contains(type), style.cornerRadius == nil {
            style.cornerRadius = pillRadius
        }
        // The Pomodoro's Start pill: a dark red pill.
        if case .pomodoro(_, _, design: .pill) = definition.type {
            if style.cornerRadius == nil { style.cornerRadius = pillRadius }
            if definition.additionalParameters[.background] == nil { button.backgroundColor = PomodoroBarItem.pillColor }
        }
        // Drawn by Stripe at the standard key's rounding: the system's key has a
        // minimum width and doesn't center a narrower picture in it.
        if type == "performance", style.cornerRadius == nil {
            style.cornerRadius = standardRadius
        }
        button.style = style
    }
}
