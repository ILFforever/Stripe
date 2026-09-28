//
//  MuteBarItem.swift
//  Stripe
//
//  A mute toggle that talks to CoreAudio directly (no Accessibility permission
//  needed, unlike simulating the mute key). Its icon is the live speaker macOS
//  would show (slash when muted, else 0–3 waves by volume), on the standard key
//  background like the other keys, and it follows changes made anywhere.
//

import AudioToolbox
import Cocoa
import CoreAudio

class MuteBarItem: CustomButtonTouchBarItem, TearDownable {
    private var observer: AudioOutputObserver?

    init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier, title: "")
        actions.append(ItemAction(trigger: .singleTap) { [weak self] in self?.toggle() })
        observer = AudioOutputObserver { [weak self] in self?.refresh() }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        observer?.stop()
        observer = nil
    }

    override var style: ItemStyle {
        didSet { refresh() } // keep the live icon when the preset's style is applied
    }

    private func refresh() {
        guard let observer = observer else { return }
        if theme.liveMuteIcon {
            var live = style
            live.symbol = observer.speakerSymbol
            image = live.symbolImage
        } else {
            // MTMR's static mute icon, unless the preset gives one.
            image = style.symbolImage ?? NSImage(named: NSImage.touchBarAudioOutputMuteTemplateName)
        }
        setBuiltInActive(observer.isMuted)
    }

    private func toggle() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        let device = MuteBarItem.defaultOutputDevice
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &address),
           AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
            var value: UInt32 = (observer?.isMuted ?? false) ? 0 : 1
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            // Some outputs (e.g. HDMI) have no mute control; fall back to the mute key.
            AccessibilityPermission.requestIfNeeded()
            HIDPostAuxKey(NX_KEYTYPE_MUTE)
        }
    }

    private static var defaultOutputDevice: AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }
}
