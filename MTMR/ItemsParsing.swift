import AppKit
import Foundation

/// A preset is either a plain list of items (MTMR's format, still read) or a
/// Stripe document: { "stripe": 1, "bar": { … }, "items": [ … ] }.
extension Data {
    /// The items as JSON, and the bar's settings.
    func presetDocument() -> (items: Data, bar: BarSettings)? {
        guard let json = utf8string?.stripComments().data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else { return nil }
        if root is [Any] { return (json, BarSettings()) }
        guard let document = root as? [String: Any], let items = document["items"] as? [Any],
              let itemsData = try? JSONSerialization.data(withJSONObject: items) else { return nil }
        return (itemsData, BarSettings(json: document["bar"] as? [String: Any] ?? [:]))
    }

    func barItemDefinitions() -> [BarItemDefinition]? {
        guard let items = presetDocument()?.items ?? utf8string?.stripComments().data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([BarItemDefinition].self, from: items)
        } catch {
            NSLog("Stripe: invalid preset: \(error)")
            return nil // the caller shows a "bad preset" button instead of crashing
        }
    }
}

struct BarItemDefinition: Decodable {
    let type: ItemType
    let actions: [Action]
    let legacyAction: LegacyActionType
    let legacyLongAction: LegacyLongActionType
    let additionalParameters: [GeneralParameters.CodingKeys: GeneralParameter]
    /// The preset's "type", e.g. "delete" (which the item type alone can't tell from a button).
    var typeName = ""

    private enum CodingKeys: String, CodingKey {
        case type
        case actions
    }

    init(type: ItemType, actions: [Action], action: LegacyActionType, legacyLongAction: LegacyLongActionType, additionalParameters: [GeneralParameters.CodingKeys: GeneralParameter]) {
        self.type = type
        self.actions = actions
        self.legacyAction = action
        self.legacyLongAction = legacyLongAction
        self.additionalParameters = additionalParameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let actions = try container.decodeIfPresent([Action].self, forKey: .actions)
        let parametersDecoder = SupportedTypesHolder.sharedInstance.lookup(by: type, actions: actions ?? [])
        var additionalParameters = try GeneralParameters(from: decoder).parameters

        if let result = try? parametersDecoder(decoder),
            case let (itemType, builtIn, action, longAction, parameters) = result {
            parameters.forEach { additionalParameters[$0] = $1 }
            var merged = builtIn, legacy = action, legacyLong = longAction
            // The preset's actions replace an item's own for the same trigger. Keys with a
            // fixed action (escape, media keys, mute…) come back from their decoder with
            // only that action, so the preset's are merged in here; other types already
            // come back with the preset's.
            if SupportedTypesHolder.sharedInstance.hasFixedActions(type) {
                let userActions = actions ?? []
                let userAction = (try? LegacyActionType(from: decoder)) ?? .none
                let userLongAction = (try? LegacyLongActionType(from: decoder)) ?? .none
                var overridden = Set(userActions.map { $0.trigger })
                if case .none = userAction {} else { overridden.insert(.singleTap) }
                if case .none = userLongAction {} else { overridden.insert(.longTap) }
                merged = builtIn.filter { !overridden.contains($0.trigger) } + userActions
                if case .none = legacy { legacy = userAction }
                if case .none = legacyLong { legacyLong = userLongAction }
            }
            self.init(type: itemType, actions: merged, action: legacy, legacyLongAction: legacyLong, additionalParameters: additionalParameters)
        } else {
            self.init(type: .staticButton(title: "unknown"), actions: [], action: .none, legacyLongAction: .none, additionalParameters: additionalParameters)
        }
        typeName = type
    }
}

typealias ParametersDecoder = (Decoder) throws -> (
    item: ItemType,
    actions: [Action],
    legacyAction: LegacyActionType,
    legacyLongAction: LegacyLongActionType,
    parameters: [GeneralParameters.CodingKeys: GeneralParameter]
)

class SupportedTypesHolder {
    private var supportedTypes: [String: ParametersDecoder] = [
        "escape": { _ in (
            item: .staticButton(title: "esc"),
            actions: [
                Action(trigger: .singleTap, value: .keyPress(keycode: 53))
            ],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [.align: .align(.left)]
        ) },

        "delete": { _ in (
            item: .staticButton(title: "del"),
            actions: [
                Action(trigger: .singleTap, value: .keyPress(keycode: 117))
            ],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        ) },

        "brightnessUp": { _ in
            let imageParameter = GeneralParameter.image(source: #imageLiteral(resourceName: "brightnessUp"))
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_BRIGHTNESS_UP))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        "brightnessDown": { _ in
            let imageParameter = GeneralParameter.image(source: #imageLiteral(resourceName: "brightnessDown"))
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_BRIGHTNESS_DOWN))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        "illuminationUp": { _ in
            let imageParameter = GeneralParameter.image(source: #imageLiteral(resourceName: "ill_up"))
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_ILLUMINATION_UP))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        "illuminationDown": { _ in
            let imageParameter = GeneralParameter.image(source: #imageLiteral(resourceName: "ill_down"))
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_ILLUMINATION_DOWN))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        "volumeDown": { _ in
            let imageParameter = GeneralParameter.image(source: NSImage(named: NSImage.touchBarVolumeDownTemplateName)!)
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_SOUND_DOWN))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        "volumeUp": { _ in
            let imageParameter = GeneralParameter.image(source: NSImage(named: NSImage.touchBarVolumeUpTemplateName)!)
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_SOUND_UP))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        // A real toggle via CoreAudio that shows the mute state (MuteBarItem).
        "mute": { _ in (
            item: .mute,
            actions: [],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        ) },

        "previous": { _ in
            let imageParameter = GeneralParameter.image(source: NSImage(named: NSImage.touchBarRewindTemplateName)!)
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_PREVIOUS))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        // Draws its own icon, half of it lit depending on what's playing (PlayPauseBarItem).
        "play": { decoder in (
            item: .playPause(litWhilePlaying: try PlayPauseOptions(from: decoder).litWhilePlaying),
            actions: [
                Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_PLAY))
            ],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        ) },

        "next": { _ in
            let imageParameter = GeneralParameter.image(source: NSImage(named: NSImage.touchBarFastForwardTemplateName)!)
            return (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .hidKey(keycode: NX_KEYTYPE_NEXT))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.image: imageParameter]
            )
        },

        "sleep": { _ in (
            item: .staticButton(title: "☕️"),
            actions: [
                Action(trigger: .singleTap, value: .shellScript(executable: "/usr/bin/pmset", parameters: ["sleepnow"]))
            ],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        ) },

        "displaySleep": { _ in (
            item: .staticButton(title: "☕️"),
            actions: [
                Action(trigger: .singleTap, value: .shellScript(executable: "/usr/bin/pmset", parameters: ["displaysleepnow"]))
            ],
            legacyAction: .none,
            legacyLongAction: .none,
            parameters: [:]
        ) },

    ]

    static let sharedInstance = SupportedTypesHolder()

    func lookup(by type: String, actions: [Action]) -> ParametersDecoder {
        return supportedTypes[type] ?? { decoder in (
            item: try ItemType(from: decoder),
            actions: actions,
            legacyAction: try LegacyActionType(from: decoder),
            legacyLongAction: try LegacyLongActionType(from: decoder),
            parameters: [:]
        ) }
    }

    /// Types whose decoder supplies their action (escape, the media keys…) rather than the preset.
    func hasFixedActions(_ type: String) -> Bool {
        return supportedTypes[type] != nil
    }

    func register(typename: String, decoder: @escaping ParametersDecoder) {
        supportedTypes[typename] = decoder
    }

    func register(typename: String, item: ItemType, actions: [Action], legacyAction: LegacyActionType, legacyLongAction: LegacyLongActionType) {
        register(typename: typename) { _ in
            (
                item: item,
                actions,
                legacyAction,
                legacyLongAction,
                parameters: [:]
            )
        }
    }
}

enum ItemType: Decodable {
    case staticButton(title: String)
    case appleScriptTitledButton(source: SourceProtocol, refreshInterval: Double, alternativeImages: [String: SourceProtocol])
    case shellScriptTitledButton(source: SourceProtocol, refreshInterval: Double)
    case timeButton(formatTemplate: String, timeZone: String?, locale: String?)
    case battery(options: BatteryOptions)
    case cpu(refreshInterval: Double, panel: PerformancePanelOptions)
    case gpu(refreshInterval: Double, panel: PerformancePanelOptions)
    case performance(design: PerformanceBarItem.Design, panel: PerformancePanelOptions)
    case dock(autoResize: Bool, filter: String?)
    case volume
    case mute
    case playPause(litWhilePlaying: PlayPauseIcon.Half)
    case brightness(refreshInterval: Double)
    case weather(interval: Double, units: String, api_key: String, icon_type: String)
    case yandexWeather(interval: Double)
    case currency(interval: Double, from: String, to: String, full: Bool)
    case inputsource
    case music(interval: Double, disableMarquee: Bool, design: MusicBarItem.Design, tapOpens: MusicBarItem.TapOpens,
               gestures: MusicBarItem.Gestures)
    case group(items: [BarItemDefinition])
    case popover(items: [BarItemDefinition], pressAndHold: Bool, autoClose: Double?, liveIcon: Bool)
    case cluster(items: [BarItemDefinition], options: ClusterOptions)
    case nightShift
    case dnd
    case pomodoro(workTime: Double, restTime: Double, design: PomodoroBarItem.Design)
    case network(flip: Bool, units: String)
    case darkMode
    case swipe(direction: String, fingers: Int, minOffset: Float, sourceApple: SourceProtocol?, sourceBash: SourceProtocol?)
    case upnext(from: Double, to: Double, maxToShow: Int, autoResize: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case source
        case refreshInterval
        case from
        case to
        case full
        case timeZone
        case units
        case api_key
        case icon_type
        case formatTemplate
        case locale
        case image
        case url
        case longUrl
        case items
        case workTime
        case restTime
        case flip
        case autoResize
        case filter
        case disableMarquee
        case tapOpens, doubleTapDoes, holdDoes
        case alternativeImages
        case sourceApple
        case sourceBash
        case direction
        case fingers
        case minOffset
        case maxToShow
        case pressAndHold
        case autoClose
        case liveIcon
        case showIcon, showPercentage, percentInside, showTime, animate, lowThreshold, tapToCycle, holdOpens
        case panelCloseSide, panelTiles, panelGraphHours, panelBarMinutes
        case design, colors
        case dividers, spacing, itemWidth, padding
    }

    enum ItemTypeRaw: String, Decodable {
        case staticButton
        case appleScriptTitledButton
        case shellScriptTitledButton
        case timeButton
        case battery
        case cpu
        case gpu
        case performance
        case dock
        case volume
        case brightness
        case weather
        case yandexWeather
        case currency
        case inputsource
        case music
        case group
        case popover
        case cluster
        case nightShift
        case dnd
        case pomodoro
        case network
        case darkMode
        case swipe
        case upnext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemTypeRaw.self, forKey: .type)
        switch type {
        case .appleScriptTitledButton:
            let source = try container.decode(Source.self, forKey: .source)
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 1800.0
            let alternativeImages = try container.decodeIfPresent([String: Source].self, forKey: .alternativeImages) ?? [:]
            self = .appleScriptTitledButton(source: source, refreshInterval: interval, alternativeImages: alternativeImages)
            
        case .shellScriptTitledButton:
            let source = try container.decode(Source.self, forKey: .source)
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 1800.0
            self = .shellScriptTitledButton(source: source, refreshInterval: interval)

        case .staticButton:
            let title = try container.decode(String.self, forKey: .title)
            self = .staticButton(title: title)

        case .timeButton:
            let template = try container.decodeIfPresent(String.self, forKey: .formatTemplate) ?? "HH:mm"
            let timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? nil
            let locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? nil
            self = .timeButton(formatTemplate: template, timeZone: timeZone, locale: locale)

        case .battery:
            var options = BatteryOptions()
            options.showIcon = try container.decodeIfPresent(Bool.self, forKey: .showIcon) ?? options.showIcon
            options.showPercentage = try container.decodeIfPresent(Bool.self, forKey: .showPercentage) ?? options.showPercentage
            options.percentInside = try container.decodeIfPresent(Bool.self, forKey: .percentInside) ?? options.percentInside
            options.showTime = try container.decodeIfPresent(Bool.self, forKey: .showTime) ?? options.showTime
            options.animate = try container.decodeIfPresent(Bool.self, forKey: .animate) ?? options.animate
            options.lowThreshold = try container.decodeIfPresent(Int.self, forKey: .lowThreshold) ?? options.lowThreshold
            options.tapToCycle = try container.decodeIfPresent(Bool.self, forKey: .tapToCycle) ?? options.tapToCycle
            options.holdAction = try container.decodeIfPresent(String.self, forKey: .holdOpens)
                .flatMap(BatteryOptions.HoldAction.init(rawValue:)) ?? .details
            options.panel.closeSide = try container.decodeIfPresent(Align.self, forKey: .panelCloseSide)
            if let tiles = try container.decodeIfPresent([String].self, forKey: .panelTiles) {
                options.panel.tiles = Set(tiles.compactMap(BatteryPanelOptions.Tile.init(rawValue:)))
            }
            if let hours = try container.decodeIfPresent(Int.self, forKey: .panelGraphHours), (1 ... 48).contains(hours) {
                options.panel.graphHours = hours
            }
            if let minutes = try container.decodeIfPresent(Int.self, forKey: .panelBarMinutes), (5 ... 240).contains(minutes) {
                options.panel.barMinutes = minutes
            }
            self = .battery(options: options)
            
        case .cpu:
            let refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 5.0
            self = .cpu(refreshInterval: refreshInterval, panel: try ItemType.panel(.cpu, container))

        case .gpu:
            let refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 2.0
            self = .gpu(refreshInterval: refreshInterval, panel: try ItemType.panel(.gpu, container))

        case .performance:
            let design = try container.decodeIfPresent(String.self, forKey: .design)
                .flatMap(PerformanceBarItem.Design.init(rawValue:)) ?? .chip
            self = .performance(design: design, panel: try ItemType.panel(.unified, container))

        case .dock:
            let autoResize = try container.decodeIfPresent(Bool.self, forKey: .autoResize) ?? false
            let filterRegexString = try container.decodeIfPresent(String.self, forKey: .filter)
            self = .dock(autoResize: autoResize, filter: filterRegexString)

        case .volume:
            self = .volume

        case .brightness:
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 0.5
            self = .brightness(refreshInterval: interval)

        case .weather:
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 1800.0
            let units = try container.decodeIfPresent(String.self, forKey: .units) ?? "metric"
            let api_key = try container.decodeIfPresent(String.self, forKey: .api_key) ?? "32c4256d09a4c52b38aecddba7a078f6"
            let icon_type = try container.decodeIfPresent(String.self, forKey: .icon_type) ?? "text"
            self = .weather(interval: interval, units: units, api_key: api_key, icon_type: icon_type)
            
        case .yandexWeather:
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 1800.0
            self = .yandexWeather(interval: interval)

        case .currency:
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 600.0
            let from = try container.decodeIfPresent(String.self, forKey: .from) ?? "RUB"
            let to = try container.decodeIfPresent(String.self, forKey: .to) ?? "USD"
            let full = try container.decodeIfPresent(Bool.self, forKey: .full) ?? false
            self = .currency(interval: interval, from: from, to: to, full: full)

        case .inputsource:
            self = .inputsource

        case .music:
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 5.0
            let disableMarquee = try container.decodeIfPresent(Bool.self, forKey: .disableMarquee) ?? false
            let design = try container.decodeIfPresent(String.self, forKey: .design)
            let tapOpens = try container.decodeIfPresent(String.self, forKey: .tapOpens)
            var gestures = MusicBarItem.Gestures()
            if let name = try container.decodeIfPresent(String.self, forKey: .doubleTapDoes),
               let gesture = MusicBarItem.Gesture(rawValue: name) { gestures.doubleTap = gesture }
            if let name = try container.decodeIfPresent(String.self, forKey: .holdDoes),
               let gesture = MusicBarItem.Gesture(rawValue: name) { gestures.hold = gesture }
            self = .music(interval: interval, disableMarquee: disableMarquee,
                          design: design.flatMap(MusicBarItem.Design.init(rawValue:)) ?? .lines,
                          tapOpens: tapOpens.flatMap(MusicBarItem.TapOpens.init(rawValue:)) ?? .none,
                          gestures: gestures)

        case .group:
            let items = try container.decodeIfPresent([BarItemDefinition].self, forKey: .items) ?? []
            self = .group(items: items)

        case .popover:
            let items = try container.decodeIfPresent([BarItemDefinition].self, forKey: .items) ?? []
            let pressAndHold = try container.decodeIfPresent(Bool.self, forKey: .pressAndHold) ?? false
            let autoClose = try container.decodeIfPresent(Double.self, forKey: .autoClose)
            let liveIcon = try container.decodeIfPresent(Bool.self, forKey: .liveIcon) ?? true
            self = .popover(items: items, pressAndHold: pressAndHold, autoClose: autoClose, liveIcon: liveIcon)

        case .cluster:
            let items = try container.decodeIfPresent([BarItemDefinition].self, forKey: .items) ?? []
            var options = ClusterOptions()
            options.dividers = try container.decodeIfPresent(Bool.self, forKey: .dividers) ?? options.dividers
            options.spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? options.spacing
            options.itemWidth = try container.decodeIfPresent(CGFloat.self, forKey: .itemWidth)
            options.padding = try container.decodeIfPresent(CGFloat.self, forKey: .padding)
            self = .cluster(items: items, options: options)

        case .nightShift:
            self = .nightShift

        case .dnd:
            self = .dnd

        case .pomodoro:
            let workTime = try container.decodeIfPresent(Double.self, forKey: .workTime) ?? 1500.0
            let restTime = try container.decodeIfPresent(Double.self, forKey: .restTime) ?? 600.0
            let design = try container.decodeIfPresent(String.self, forKey: .design)
            self = .pomodoro(workTime: workTime, restTime: restTime,
                             design: design.flatMap(PomodoroBarItem.Design.init(rawValue:)) ?? .icon)

        case .network:
            let flip = try container.decodeIfPresent(Bool.self, forKey: .flip) ?? false
            let units = try container.decodeIfPresent(String.self, forKey: .units) ?? "dynamic"
            self = .network(flip: flip, units: units)

        case .darkMode:
            self = .darkMode
            
        case .swipe:
            let sourceApple = try container.decodeIfPresent(Source.self, forKey: .sourceApple)
            let sourceBash = try container.decodeIfPresent(Source.self, forKey: .sourceBash)
            let direction = try container.decode(String.self, forKey: .direction)
            let fingers = try container.decode(Int.self, forKey: .fingers)
            let minOffset = try container.decodeIfPresent(Float.self, forKey: .minOffset) ?? 0.0
            self = .swipe(direction: direction, fingers: fingers, minOffset: minOffset, sourceApple: sourceApple, sourceBash: sourceBash)

        case .upnext:
            let from = try container.decodeIfPresent(Double.self, forKey: .from) ?? 0 // Lower bounds of period of time in hours to search for events
            let to = try container.decodeIfPresent(Double.self, forKey: .to) ?? 12 // Upper bounds of period of time in hours to search for events
            let maxToShow = try container.decodeIfPresent(Int.self, forKey: .maxToShow) ?? 3 // 1 indexed array.  Get the 1st, 2nd, 3rd event to display multiple notifications
            let autoResize = try container.decodeIfPresent(Bool.self, forKey: .autoResize) ?? false
            let interval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 60.0
            self = .upnext(from: from, to: to, maxToShow: maxToShow, autoResize: autoResize)
        }
    }

    /// A performance page's options: "panelTiles" (only those this page has) and "panelCloseSide".
    private static func panel(_ kind: PerformancePanelOptions.Kind,
                              _ container: KeyedDecodingContainer<CodingKeys>) throws -> PerformancePanelOptions {
        let tiles = try container.decodeIfPresent([String].self, forKey: .panelTiles)
            .map { Set($0.compactMap(PerformancePanelOptions.Tile.init(rawValue:)).filter(kind.tiles.contains)) }
        return PerformancePanelOptions(kind: kind, tiles: tiles,
                                       closeSide: try container.decodeIfPresent(Align.self, forKey: .panelCloseSide),
                                       palette: PerformancePalette.named(try container.decodeIfPresent(String.self, forKey: .colors)))
    }
}

/// "litWhilePlaying": "pause" (the default: the key shows what a tap will do)
/// or "play" (it shows what's happening).
private struct PlayPauseOptions: Decodable {
    let litWhilePlaying: PlayPauseIcon.Half

    private enum CodingKeys: String, CodingKey { case litWhilePlaying }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(String.self, forKey: .litWhilePlaying)
        litWhilePlaying = value == "play" ? .play : .pause
    }
}

struct FailableDecodable<Base : Decodable> : Decodable {

    let base: Base?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.base = try? container.decode(Base.self)
    }
}

struct Action: Decodable {
    enum Trigger: String, Decodable {
        case singleTap
        case doubleTap
        case tripleTap
        case longTap
    }
    
    enum Value {
        case none
        case hidKey(keycode: Int32)
        case keyPress(keycode: Int)
        case appleScript(source: SourceProtocol)
        case shellScript(executable: String, parameters: [String])
        case custom(closure: () -> Void)
        case openUrl(url: String)
    }
    
    private enum ActionTypeRaw: String, Decodable {
        case hidKey
        case keyPress
        case appleScript
        case shellScript
        case openUrl
    }
    
    enum CodingKeys: String, CodingKey {
        case trigger
        case action
        case keycode
        case actionAppleScript
        case executablePath
        case shellArguments
        case url
    }
    
    let trigger: Trigger
    let value: Value
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        let type = try container.decodeIfPresent(ActionTypeRaw.self, forKey: .action)

        switch type {
        case .some(.hidKey):
            let keycode = try container.decode(Int32.self, forKey: .keycode)
            value = .hidKey(keycode: keycode)

        case .some(.keyPress):
            let keycode = try container.decode(Int.self, forKey: .keycode)
            value = .keyPress(keycode: keycode)

        case .some(.appleScript):
            let source = try container.decode(Source.self, forKey: .actionAppleScript)
            value = .appleScript(source: source)

        case .some(.shellScript):
            let executable = try container.decode(String.self, forKey: .executablePath)
            let parameters = try container.decodeIfPresent([String].self, forKey: .shellArguments) ?? []
            value = .shellScript(executable: executable, parameters: parameters)

        case .some(.openUrl):
            let url = try container.decode(String.self, forKey: .url)
            value = .openUrl(url: url)
        case .none:
            value = .none
        }
    }
    
    init(trigger: Trigger, value: Value) {
        self.trigger = trigger
        self.value = value
    }
}

enum LegacyActionType: Decodable {
    case none
    case hidKey(keycode: Int32)
    case keyPress(keycode: Int)
    case appleScript(source: SourceProtocol)
    case shellScript(executable: String, parameters: [String])
    case custom(closure: () -> Void)
    case openUrl(url: String)

    private enum CodingKeys: String, CodingKey {
        case action
        case keycode
        case actionAppleScript
        case executablePath
        case shellArguments
        case url
    }

    private enum ActionTypeRaw: String, Decodable {
        case hidKey
        case keyPress
        case appleScript
        case shellScript
        case openUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(ActionTypeRaw.self, forKey: .action)

        switch type {
        case .some(.hidKey):
            let keycode = try container.decode(Int32.self, forKey: .keycode)
            self = .hidKey(keycode: keycode)

        case .some(.keyPress):
            let keycode = try container.decode(Int.self, forKey: .keycode)
            self = .keyPress(keycode: keycode)

        case .some(.appleScript):
            let source = try container.decode(Source.self, forKey: .actionAppleScript)
            self = .appleScript(source: source)

        case .some(.shellScript):
            let executable = try container.decode(String.self, forKey: .executablePath)
            let parameters = try container.decodeIfPresent([String].self, forKey: .shellArguments) ?? []
            self = .shellScript(executable: executable, parameters: parameters)

        case .some(.openUrl):
            let url = try container.decode(String.self, forKey: .url)
            self = .openUrl(url: url)

        case .none:
            self = .none
        }
    }
}

enum LegacyLongActionType: Decodable {
    case none
    case hidKey(keycode: Int32)
    case keyPress(keycode: Int)
    case appleScript(source: SourceProtocol)
    case shellScript(executable: String, parameters: [String])
    case custom(closure: () -> Void)
    case openUrl(url: String)

    private enum CodingKeys: String, CodingKey {
        case longAction
        case longKeycode
        case longActionAppleScript
        case longExecutablePath
        case longShellArguments
        case longUrl
    }

    private enum LongActionTypeRaw: String, Decodable {
        case hidKey
        case keyPress
        case appleScript
        case shellScript
        case openUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let longType = try container.decodeIfPresent(LongActionTypeRaw.self, forKey: .longAction)

        switch longType {
        case .some(.hidKey):
            let keycode = try container.decode(Int32.self, forKey: .longKeycode)
            self = .hidKey(keycode: keycode)

        case .some(.keyPress):
            let keycode = try container.decode(Int.self, forKey: .longKeycode)
            self = .keyPress(keycode: keycode)

        case .some(.appleScript):
            let source = try container.decode(Source.self, forKey: .longActionAppleScript)
            self = .appleScript(source: source)

        case .some(.shellScript):
            let executable = try container.decode(String.self, forKey: .longExecutablePath)
            let parameters = try container.decodeIfPresent([String].self, forKey: .longShellArguments) ?? []
            self = .shellScript(executable: executable, parameters: parameters)

        case .some(.openUrl):
            let longUrl = try container.decode(String.self, forKey: .longUrl)
            self = .openUrl(url: longUrl)

        case .none:
            self = .none
        }
    }
}

enum GeneralParameter {
    case width(_: CGFloat)
    case image(source: SourceProtocol)
    case align(_: Align)
    case bordered(_: Bool)
    case background(_: NSColor)
    case title(_: String)
    case style(_: ItemStyle)
    case when(_: ItemCondition)
    case theme(_: Theme.Name)
    /// A glass key of its own ("glass": true), or a standard one on a glass bar (false).
    case glass(_: Bool)
    /// A color the glass is tinted with ("glassTint").
    case glassTint(_: NSColor)
}

struct GeneralParameters: Decodable {
    let parameters: [GeneralParameters.CodingKeys: GeneralParameter]

    enum CodingKeys: String, CodingKey {
        case width
        case image
        case align
        case bordered
        case background
        case title
        case matchAppId
        case style // stands for all ItemStyle keys, which are decoded together
        case when
        case theme
        case glass
        case glassTint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var result: [GeneralParameters.CodingKeys: GeneralParameter] = [:]

        if let theme = try container.decodeIfPresent(String.self, forKey: .theme).flatMap(Theme.Name.init(rawValue:)) {
            result[.theme] = .theme(theme)
        }

        result[.style] = .style(try ItemStyle(from: decoder))

        if let value = try container.decodeIfPresent(CGFloat.self, forKey: .width) {
            result[.width] = .width(value)
        }

        if let imageSource = try container.decodeIfPresent(Source.self, forKey: .image) {
            result[.image] = .image(source: imageSource)
        }

        let align = try container.decodeIfPresent(Align.self, forKey: .align) ?? .center
        result[.align] = .align(align)

        if let borderedFlag = try container.decodeIfPresent(Bool.self, forKey: .bordered) {
            result[.bordered] = .bordered(borderedFlag)
        }

        if let backgroundColor = try container.decodeIfPresent(String.self, forKey: .background)?.namedOrHexColor {
            result[.background] = .background(backgroundColor)
        }

        if let title = try container.decodeIfPresent(String.self, forKey: .title) {
            result[.title] = .title(title)
        }

        if let glass = try container.decodeIfPresent(Bool.self, forKey: .glass) {
            result[.glass] = .glass(glass)
        }

        if let tint = try container.decodeIfPresent(String.self, forKey: .glassTint)?.namedOrHexColor {
            result[.glassTint] = .glassTint(tint)
        }

        if let condition = try container.decodeIfPresent(ItemCondition.self, forKey: .when) {
            result[.when] = .when(condition)
        } else if let matchAppId = try container.decodeIfPresent(String.self, forKey: .matchAppId) {
            result[.when] = .when(ItemCondition(app: matchAppId))
        }

        parameters = result
    }
}

protocol SourceProtocol {
    var data: Data? { get }
    var string: String? { get }
    var image: NSImage? { get }
    var appleScript: NSAppleScript? { get }
}

struct Source: Decodable, SourceProtocol {
    let filePath: String?
    let base64: String?
    let inline: String?

    private enum CodingKeys: String, CodingKey {
        case filePath
        case base64
        case inline
    }

    var data: Data? {
        return base64?.base64Data ?? inline?.data(using: .utf8) ?? filePath?.fileData
    }

    var string: String? {
        return inline ?? filePath?.fileString
    }

    var image: NSImage? {
        return data?.image
    }

    var appleScript: NSAppleScript? {
        return filePath?.fileURL.appleScript ?? string?.appleScript
    }

    private init(filePath: String?, base64: String?, inline: String?) {
        self.filePath = filePath
        self.base64 = base64
        self.inline = inline
    }

    init(filePath: String) {
        self.init(filePath: filePath, base64: nil, inline: nil)
    }
}

extension NSImage: SourceProtocol {
    var data: Data? {
        return nil
    }

    var string: String? {
        return nil
    }

    var image: NSImage? {
        return self
    }

    var appleScript: NSAppleScript? {
        return nil
    }
}

extension String {
    var base64Data: Data? {
        return Data(base64Encoded: self)
    }

    var fileData: Data? {
        return try? Data(contentsOf: URL(fileURLWithPath: (self as NSString).expandingTildeInPath))
    }

    var fileString: String? {
        var encoding: String.Encoding = .utf8
        return try? String(contentsOf: URL(fileURLWithPath: (self as NSString).expandingTildeInPath), usedEncoding: &encoding)
    }

    var fileURL: URL {
        return URL(fileURLWithPath: (self as NSString).expandingTildeInPath)
    }

    var appleScript: NSAppleScript? {
        return NSAppleScript(source: self)
    }
}

extension Data {
    var utf8string: String? {
        return String(data: self, encoding: .utf8)
    }

    var image: NSImage? {
        return NSImage(data: self)?.resize(maxSize: NSSize(width: 24, height: 24))
    }
}

enum Align: String, Decodable {
    case left
    case center
    case right
}

extension URL {
    var appleScript: NSAppleScript? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSAppleScript(contentsOf: self, error: nil)
    }
}
