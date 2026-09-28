import AppKit
import AVFoundation
import Cocoa
import CoreAudio

class VolumeViewController: NSCustomTouchBarItem, SlidableItem, TearDownable, HasSliderDetents {
    let detents = SliderDetents()
    // Stored so tearDown() can remove exactly these blocks; they hold the item weakly.
    private lazy var routeListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        self?.audioRouteChanged(numberAddresses: count, addresses: addresses)
    }
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        self?.audioObjectPropertyListenerBlock(numberAddresses: count, addresses: addresses)
    }

    func tearDown() {
        removeLastAudioVolumeChangeListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(bitPattern: kAudioObjectSystemObject), &address, nil, routeListener)
    }

    private(set) var sliderItem: CustomSlider!
    private var currentDeviceId: AudioObjectID = AudioObjectID(0)

    init(identifier: NSTouchBarItem.Identifier, image: NSImage? = nil) {
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
        sliderItem.action = #selector(VolumeViewController.sliderValueChanged(_:))
        sliderItem.minValue = 0.0
        sliderItem.maxValue = 100.0
        sliderItem.floatValue = VolumeViewController.getInputGain() * 100

        view = image == nil && Theme.current.sliderPanels ? sliderItem.withEndIcons(min: "speaker.fill", max: "speaker.wave.3.fill") : sliderItem
        
        currentDeviceId = VolumeViewController.defaultDeviceID
        self.addAudioRouteChangedListener()
        self.addCurrentAudioVolumeChangedListener()
    }
    
    private func addAudioRouteChangedListener() {
        let audioId = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        var forPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster)
        AudioObjectAddPropertyListenerBlock(audioId, &forPropertyAddress, nil, routeListener)
    }
    

    func audioRouteChanged(numberAddresses _: UInt32, addresses _: UnsafePointer<AudioObjectPropertyAddress>) {
        self.removeLastAudioVolumeChangeListener()
        currentDeviceId = VolumeViewController.defaultDeviceID
        self.addCurrentAudioVolumeChangedListener()
        DispatchQueue.main.async {
            self.sliderItem.floatValue = VolumeViewController.getInputGain() * 100
        }
    }
    
    private func addCurrentAudioVolumeChangedListener() {
        var forPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )

        AudioObjectAddPropertyListenerBlock(VolumeViewController.defaultDeviceID, &forPropertyAddress, nil, volumeListener)
    }
    
    private func removeLastAudioVolumeChangeListener() {
        var forPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMaster
        )

        AudioObjectRemovePropertyListenerBlock(currentDeviceId, &forPropertyAddress, nil, volumeListener)
    }

    func audioObjectPropertyListenerBlock(numberAddresses _: UInt32, addresses _: UnsafePointer<AudioObjectPropertyAddress>) {
        DispatchQueue.main.async {
            self.sliderItem.floatValue = VolumeViewController.getInputGain() * 100
        }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        sliderItem.unbind(NSBindingName.value)
    }

    /// 0...1, used by press-and-hold sliding on a collapsed popover.
    var sliderValue: Double {
        get { return Double(VolumeViewController.getInputGain()) }
        set {
            let clamped = min(max(newValue, 0), 1)
            _ = VolumeViewController.setInputGain(Float32(clamped))
            sliderItem.floatValue = Float(clamped * 100)
            detents.update(clamped)
        }
    }

    @objc func sliderValueChanged(_ sender: Any) {
        if let sliderItem = sender as? NSSlider {
            _ = VolumeViewController.setInputGain(Float32(sliderItem.intValue) / 100.0)
            detents.update(Double(sliderItem.intValue) / 100)
        }
    }

    private static var defaultDeviceID: AudioObjectID {
        var deviceID: AudioObjectID = AudioObjectID(0)
        var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
        var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress()
        address.mSelector = AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice)
        address.mScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
        address.mElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func getInputGain() -> Float32 {
        var volume: Float32 = 0.5
        var size: UInt32 = UInt32(MemoryLayout.size(ofValue: volume))
        var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress()
        address.mSelector = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        address.mScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
        address.mElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        AudioObjectGetPropertyData(defaultDeviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    static func setInputGain(_ volume: Float32) -> OSStatus {
        var inputVolume: Float32 = volume

        if inputVolume == 0.0 {
            _ = VolumeViewController.setMute(mute: 1)
        } else {
            _ = VolumeViewController.setMute(mute: 0)
        }

        let size: UInt32 = UInt32(MemoryLayout.size(ofValue: inputVolume))
        var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress()
        address.mScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
        address.mElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        address.mSelector = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return AudioObjectSetPropertyData(defaultDeviceID, &address, 0, nil, size, &inputVolume)
    }

    private static func setMute(mute: Int) -> OSStatus {
        var muteVal: Int = mute
        var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress()
        address.mSelector = AudioObjectPropertySelector(kAudioDevicePropertyMute)
        let size: UInt32 = UInt32(MemoryLayout.size(ofValue: muteVal))
        address.mScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
        address.mElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMaster)
        return AudioObjectSetPropertyData(defaultDeviceID, &address, 0, nil, size, &muteVal)
    }
}
