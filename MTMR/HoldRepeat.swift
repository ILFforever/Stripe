//
//  HoldRepeat.swift
//  MTMR
//
//  Stripe: brightness and volume keys that keep stepping while held, by the
//  item's "holdStep" percent, showing the volume overlay, with a buzz each
//  step that builds while holding up and fades while holding down.
//

import AppKit

/// What a held key adjusts, and which way.
struct HoldRepeat {
    enum Level {
        case brightness, volume
    }

    let level: Level
    /// +1 for up keys, -1 for down keys.
    let direction: Double

    /// For the system keys that step brightness or volume; nil for any other key.
    init?(hidKey keycode: Int32) {
        switch keycode {
        case NX_KEYTYPE_BRIGHTNESS_UP: (level, direction) = (.brightness, 1)
        case NX_KEYTYPE_BRIGHTNESS_DOWN: (level, direction) = (.brightness, -1)
        case NX_KEYTYPE_SOUND_UP: (level, direction) = (.volume, 1)
        case NX_KEYTYPE_SOUND_DOWN: (level, direction) = (.volume, -1)
        default: return nil
        }
    }

    /// 0...1.
    var value: Double {
        get {
            switch level {
            case .brightness: return Double(BrightnessViewController.getBrightness())
            case .volume: return Double(VolumeViewController.getInputGain())
            }
        }
        nonmutating set {
            let clamped = min(max(newValue, 0), 1)
            switch level {
            case .brightness: BrightnessViewController.setBrightness(level: Float(clamped))
            case .volume: _ = VolumeViewController.setInputGain(Float32(clamped))
            }
        }
    }

    /// Moves one step (0...1) and returns the new level, or nil at the end already.
    func step(by amount: Double) -> Double? {
        if level == .brightness, DisplayServices.brightness == nil {
            // No built-in display to set directly: the system key's own step, instead.
            HIDPostAuxKey(direction > 0 ? NX_KEYTYPE_BRIGHTNESS_UP : NX_KEYTYPE_BRIGHTNESS_DOWN)
            return value
        }
        let current = value
        let next = min(max(current + direction * amount, 0), 1)
        guard abs(next - current) > 0.0001 else { return nil }
        value = next
        return next
    }

    /// The buzz for the `count`th step of a hold (from 0): holding up builds from
    /// light to strong, holding down fades from strong to light, a band every 4 steps.
    func strength(atStep count: Int) -> HapticStyle.Strength {
        let ramp: [HapticStyle.Strength] = direction > 0 ? [.light, .medium, .strong] : [.strong, .medium, .light]
        return ramp[min(count / 4, ramp.count - 1)]
    }

    /// Shows the system's volume overlay, as the keys do. Brightness shows its
    /// own when it changes, so it's left alone (showing it too doubles it).
    func showOverlay(_ value: Double) {
        guard level == .volume else { return }
        MediaKeys.showLevelOverlay(value <= 0 ? 4 : 3, level: value)
    }
}
