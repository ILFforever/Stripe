//
//  HapticFeedback.swift
//  MTMR
//
//  Created by Anton Palgunov on 09/04/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import IOKit

class HapticFeedback {

    // Here we have list of possible IDs for Haptic Generator Device. They are not constant
    // To find deviceID, you will need IORegistryExplorer app from Additional Tools for Xcode dmg
    // which you can download from https://developer.apple.com/download/more/?=Additional%20Tools
    // Open IORegistryExplorer app, search for "AppleMultitouchDevice" and get "Multitouch ID"
    // or "AppleMultitouchTrackpadHIDEventDriver" and get "mt-device-id"
    // There should be programmatic way to get it but I can't find, no docs for macOS :(
    private let possibleDeviceIDs: [UInt64] = [
        0x200_0000_0100_0000,   // MacBook Pro 2016/2017
        0x300_0000_8050_0000,   // MacBook Pro 2019/2018
        0x200_0000_0000_0024,   // MacBook Pro (13-inch, M1, 2020)
        0x200_0000_0000_0023    // MacBook Pro M1 13-Inch 2020 with 1tb
//        0x300000080500000,
    ]

    // you can get a plist `otool -s __TEXT __tpad_act_plist /System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport|tail -n +3|awk -F'\t' '{print $2}'|xxd -r -p`
    enum HapticType: Int32, CaseIterable {
        case back = 1
        case click = 2
        case weak = 3
        case medium = 4
        case weakMedium = 5
        case strong = 6
        case reserved1 = 15
        case reserved2 = 16
    }

    private var actuatorRef: CFTypeRef?

    static var instance = HapticFeedback()

    // MARK: - Init

    private init() {
        self.recreateDevice()
    }

    private func recreateDevice() {
        if let actuatorRef = self.actuatorRef {
            MTActuatorClose(actuatorRef)
            self.actuatorRef = nil // just in case %)
        }

        guard self.actuatorRef == nil else {
            return
        }

        // Stripe: ask the system which multitouch device has a haptic actuator
        // (on Apple silicon MacBook Pros, the trackpad), then fall back to the
        // known IDs, which only cover 2016–2020 models.
        for deviceID in HapticFeedback.actuatedDeviceIDs() + possibleDeviceIDs {
            let actuatorRef = MTActuatorCreateFromDeviceID(deviceID).takeRetainedValue()
            if actuatorRef != nil {
                self.actuatorRef = actuatorRef
                return
            }
        }
    }

    /// Multitouch devices that report "ActuationSupported".
    private static func actuatedDeviceIDs() -> [UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var ids: [UInt64] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if property("ActuationSupported") as? Bool == true, let id = property("Multitouch ID") as? NSNumber {
                ids.append(id.uint64Value)
            }
        }
        return ids
    }

    // MARK: - Tap action

    private func getActuatorIfPosible() -> CFTypeRef? {
        guard AppSettings.hapticFeedbackState else { return nil }
        guard let actuatorRef = self.actuatorRef else {
            print("guard actuatorRef == nil (no haptic device found?)")
            return nil
        }

        guard MTActuatorOpen(actuatorRef) == kIOReturnSuccess else {
            print("guard MTActuatorOpen")
            self.recreateDevice()
            return nil
        }

        return actuatorRef
    }

    func tap(type: HapticType) {
        guard let actuator = getActuatorIfPosible() else { return }

        guard MTActuatorActuate(actuator, type.rawValue, 0, 0, 0) == kIOReturnSuccess else {
            print("guard MTActuatorActuate")
            return
        }

        guard MTActuatorClose(actuator) == kIOReturnSuccess else {
            print("guard MTActuatorClose")
            return
        }
    }
}

// MARK: - Per-item haptics (Stripe)

/// How an item buzzes, from its "haptic", "hapticStrength" and "hapticPattern"
/// keys. The default is a medium buzz on press and a soft tick on release.
struct HapticStyle: Equatable {
    enum When: String {
        case both, press, release, off
    }

    enum Strength: String {
        case light, medium, strong

        var type: HapticFeedback.HapticType {
            switch self {
            case .light: return .weak
            case .medium: return .medium
            case .strong: return .strong
            }
        }
    }

    enum Phase {
        case press, release, hold
    }

    var when = When.both
    /// As set; nil when unset. Buttons press at `pressStrength`, sliders tick at `detentStrength`.
    var strength: Strength?
    var pressStrength: Strength { strength ?? .medium }
    var detentStrength: Strength { strength ?? .light }
    /// Taps per buzz: 1, 2 or 3.
    var repeats = 1
    /// For toggles: a buzz for turning on and one for turning off, instead of the release tick.
    var toggleFeel = true
    var onFeel = Feel(strength: .strong, repeats: 1)
    var offFeel = Feel(strength: .light, repeats: 1)

    /// One buzz: how strong, and how many taps.
    struct Feel: Equatable {
        var strength: Strength
        var repeats: Int
    }
    /// For sliders: a detent every this fraction of the range (0.1 = every 10%).
    var detentStep = 0.1

    init() {}

    init(when: String?, strength: String?, pattern: String?, toggle: Bool? = nil, step: Double? = nil,
         onStrength: String? = nil, onPattern: String? = nil, offStrength: String? = nil, offPattern: String? = nil) {
        self.when = when.flatMap(When.init(rawValue:)) ?? .both
        self.strength = strength.flatMap(Strength.init(rawValue:))
        repeats = HapticStyle.repeats(pattern)
        toggleFeel = toggle ?? true
        if let step = step, step >= 1, step <= 50 { detentStep = step / 100 }
        onFeel = Feel(strength: onStrength.flatMap(Strength.init(rawValue:)) ?? .strong, repeats: HapticStyle.repeats(onPattern))
        offFeel = Feel(strength: offStrength.flatMap(Strength.init(rawValue:)) ?? .light, repeats: HapticStyle.repeats(offPattern))
    }

    static func repeats(_ pattern: String?) -> Int {
        return ["double": 2, "triple": 3][pattern ?? ""] ?? 1
    }

    /// The buzz for a toggle that just turned on or off.
    func toggleFeel(turnedOn: Bool) -> Feel {
        return turnedOn ? onFeel : offFeel
    }

    /// The actuation for a phase, or nil when this style doesn't buzz then.
    func type(for phase: Phase) -> HapticFeedback.HapticType? {
        switch (phase, when) {
        case (_, .off), (.press, .release), (.release, .press): return nil
        case (.hold, _): return .strong // a press held long enough to act
        case (.press, _): return pressStrength.type
        case (.release, _): return .back
        }
    }
}

extension HapticFeedback {
    /// Plays one buzz: its strength, repeated for double and triple patterns.
    func play(_ feel: HapticStyle.Feel, after delay: TimeInterval = 0) {
        for index in 0 ..< max(feel.repeats, 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.08 * Double(index)) {
                self.tap(type: feel.strength.type)
            }
        }
    }

    /// Plays `style` for `phase`, repeating for double and triple patterns.
    func play(_ style: HapticStyle, _ phase: HapticStyle.Phase) {
        guard let type = style.type(for: phase) else { return }
        tap(type: type)
        for index in 1 ..< max(style.repeats, 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(index)) { self.tap(type: type) }
        }
    }
}

/// Ticks as a slider crosses evenly spaced marks while the user drags it, and a
/// firmer one at either end. A pause of half a second starts a new drag, so a
/// change from elsewhere in between (the volume keys) doesn't cause a stray tick.
final class SliderDetents {
    var style = HapticStyle()
    private var lastMark: Int?
    private var lastUpdate = Date.distantPast

    /// `value` is 0...1, from the user's own dragging or sliding.
    func update(_ value: Double) {
        guard style.when != .off, style.detentStep > 0 else { return }
        let mark = Int((min(max(value, 0), 1) / style.detentStep + 0.0001).rounded(.down))
        let newDrag = Date().timeIntervalSince(lastUpdate) > 0.5
        lastUpdate = Date()
        defer { lastMark = mark }
        guard !newDrag, let last = lastMark, mark != last else { return }
        let atEnd = value <= 0.001 || value >= 0.999
        HapticFeedback.instance.tap(type: atEnd ? .strong : style.detentStrength.type)
    }

}

/// Sliders that tick as they're dragged.
protocol HasSliderDetents: AnyObject {
    var detents: SliderDetents { get }
}
