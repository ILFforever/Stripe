import AppKit
import AVFoundation
import Cocoa
import CoreAudio

class BrightnessViewController: NSCustomTouchBarItem, SlidableItem, TearDownable, HasSliderDetents {
    let detents = SliderDetents()
    private var timer: Timer?

    private(set) var sliderItem: CustomSlider!

    init(identifier: NSTouchBarItem.Identifier, refreshInterval: Double, image: NSImage? = nil) {
        super.init(identifier: identifier)

        if image == nil {
            sliderItem = CustomSlider()
            // The MTMR theme keeps MTMR's plain slider: the system knob, no panel or end icons.
            // (Set first: the range and value set below live in the cell.)
            if !Theme.current.sliderPanels {
                sliderItem.cell = CustomSliderCell()
                // A plain slider has no width of its own; a preset "width" still wins.
                let width = sliderItem.widthAnchor.constraint(equalToConstant: 240)
                width.priority = .defaultLow
                width.isActive = true
            }
        } else {
            sliderItem = CustomSlider(knob: image!)
        }
        sliderItem.target = self
        sliderItem.action = #selector(BrightnessViewController.sliderValueChanged(_:))
        sliderItem.minValue = 0.0
        sliderItem.maxValue = 100.0
        sliderItem.floatValue = BrightnessViewController.getBrightness() * 100

        view = image == nil && Theme.current.sliderPanels ? sliderItem.withEndIcons(min: "sun.min.fill", max: "sun.max.fill") : sliderItem

        let timer = Timer.scheduledTimer(timeInterval: refreshInterval, target: self, selector: #selector(BrightnessViewController.updateBrightnessSlider), userInfo: nil, repeats: true)
        RunLoop.current.add(timer, forMode: RunLoop.Mode.common)
        self.timer = timer
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        timer?.invalidate()
    }

    deinit {
        sliderItem.unbind(NSBindingName.value)
    }

    @objc func updateBrightnessSlider() {
        DispatchQueue.main.async {
            self.sliderItem.floatValue = BrightnessViewController.getBrightness() * 100
        }
    }

    /// 0...1, used by press-and-hold sliding on a collapsed popover.
    var sliderValue: Double {
        get { return Double(BrightnessViewController.getBrightness()) }
        set {
            let clamped = min(max(newValue, 0), 1)
            BrightnessViewController.setBrightness(level: Float(clamped))
            sliderItem.floatValue = Float(clamped * 100)
            detents.update(clamped)
        }
    }

    @objc func sliderValueChanged(_ sender: Any) {
        if let sliderItem = sender as? NSSlider {
            BrightnessViewController.setBrightness(level: Float32(sliderItem.intValue) / 100.0)
            detents.update(Double(sliderItem.intValue) / 100)
        }
    }

    /// The built-in display's brightness, 0...1.
    static func getBrightness() -> Float32 {
        if let level = DisplayServices.brightness { return level }
        if #available(OSX 10.13, *) {
            return Float32(CoreDisplay_Display_GetUserBrightness(0))
        } else {
            var level: Float32 = 0.5
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"))

            IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &level)
            return level
        }
    }

    static func setBrightness(level: Float) {
        if DisplayServices.setBrightness(level) { return }
        if #available(OSX 10.13, *) {
            CoreDisplay_Display_SetUserBrightness(0, Double(level))
        } else {
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"))

            IODisplaySetFloatParameter(service, 1, kIODisplayBrightnessKey as CFString, level)
            IOObjectRelease(service)
        }
    }
}

/// The built-in display's brightness through DisplayServices, which works on
/// Apple silicon, where CoreDisplay's setter does nothing. Nil or false when
/// there's no built-in display online (a closed lid) or the call fails.
enum DisplayServices {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Setter.self) }

    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var brightness: Float? {
        guard let getter = getter, let display = builtInDisplay else { return nil }
        var level: Float = 0
        return getter(display, &level) == 0 ? level : nil
    }

    static func setBrightness(_ level: Float) -> Bool {
        guard let setter = setter, let display = builtInDisplay else { return false }
        return setter(display, level) == 0
    }
}
