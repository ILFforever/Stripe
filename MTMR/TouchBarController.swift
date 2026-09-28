//
//  TouchBar.swift
//  MTMR
//
//  Created by Anton Palgunov on 18/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa

struct ExactItem {
    let identifier: NSTouchBarItem.Identifier
    let presetItem: BarItemDefinition
}

private let userAppSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
let appSupportDirectory = userAppSupport.appending("/\(Brand.name)")
let standardConfigPath = appSupportDirectory.appending("/items.json")
private let legacyConfigPath = userAppSupport.appending("/\(Brand.legacyName)/items.json")

extension ItemType {
    var identifierBase: String {
        switch self {
        case .staticButton(title: _):
            return "com.toxblh.mtmr.staticButton."
        case .appleScriptTitledButton(source: _):
            return "com.toxblh.mtmr.appleScriptButton."
        case .shellScriptTitledButton(source: _):
            return "com.toxblh.mtmr.shellScriptButton."
        case .timeButton(formatTemplate: _, timeZone: _, locale: _):
            return "com.toxblh.mtmr.timeButton."
        case .battery:
            return "com.toxblh.mtmr.battery."
        case .cpu:
            return "com.toxblh.mtmr.cpu."
        case .gpu:
            return "com.ilfforever.stripe.gpu."
        case .performance:
            return "com.ilfforever.stripe.performance."
        case .dock(autoResize: _, filter: _):
            return "com.toxblh.mtmr.dock"
        case .volume:
            return "com.toxblh.mtmr.volume"
        case .mute:
            return "com.ilfforever.stripe.mute."
        case .playPause:
            return "com.ilfforever.stripe.playPause."
        case .brightness(refreshInterval: _):
            return "com.toxblh.mtmr.brightness"
        case .weather(interval: _, units: _, api_key: _, icon_type: _):
            return "com.toxblh.mtmr.weather"
        case .yandexWeather(interval: _):
            return "com.toxblh.mtmr.yandexWeather"
        case .currency(interval: _, from: _, to: _, full: _):
            return "com.toxblh.mtmr.currency"
        case .inputsource:
            return "com.toxblh.mtmr.inputsource."
        case .music(interval: _):
            return "com.toxblh.mtmr.music."
        case .group(items: _):
            return "com.toxblh.mtmr.groupBar."
        case .popover:
            return "com.ilfforever.stripe.popover."
        case .cluster:
            return "com.ilfforever.stripe.cluster."
        case .nightShift:
            return "com.toxblh.mtmr.nightShift."
        case .dnd:
            return "com.toxblh.mtmr.dnd."
        case .pomodoro(interval: _):
            return PomodoroBarItem.identifier
        case .network(flip: _):
            return NetworkBarItem.identifier
        case .darkMode:
            return DarkModeBarItem.identifier
        case .swipe(direction: _, fingers: _, minOffset: _, sourceApple: _, sourceBash: _):
            return "com.toxblh.mtmr.swipe."
        case .upnext(from: _, to: _, maxToShow: _, autoResize: _):
            return "com.connorgmeehan.mtmrup.next."
        }
    }
}

extension NSTouchBarItem.Identifier {
    static let controlStripItem = NSTouchBarItem.Identifier("com.toxblh.mtmr.controlStrip")
}

class TouchBarController: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarController()

    var touchBar: NSTouchBar!

    /// The preset chosen by the user (items.json, or one opened from the menu).
    fileprivate var lastPresetPath = ""
    /// The preset on screen: `lastPresetPath`, or a per-app preset from apps/<bundle-id>.json.
    private(set) var currentPresetPath = ""
    var jsonItems: [BarItemDefinition] = []
    var itemDefinitions: [NSTouchBarItem.Identifier: BarItemDefinition] = [:]
    var items: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    var leftIdentifiers: [NSTouchBarItem.Identifier] = []
    var centerIdentifiers: [NSTouchBarItem.Identifier] = []
    var rightIdentifiers: [NSTouchBarItem.Identifier] = []
    /// Every item's identifier in preset order, so the editor can match its items to the bar's.
    private(set) var orderedIdentifiers: [NSTouchBarItem.Identifier] = []
    /// Each item's JSON (keys sorted), to spot items that didn't change on a reload.
    private var itemKeys: [NSTouchBarItem.Identifier: String] = [:]
    var basicViewIdentifier = NSTouchBarItem.Identifier("com.toxblh.mtmr.scrollView.".appending(UUID().uuidString))
    var basicView: BasicView?
    var swipeItems: [SwipeItem] = []

    var blacklistAppIdentifiers: [String] = []
    var frontmostApplicationIdentifier: String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private override init() {
        super.init()
        SupportedTypesHolder.sharedInstance.register(
            typename: "exitTouchbar",
            item: .staticButton(title: "exit"),
            actions: [
                Action(trigger: .singleTap, value: .custom(closure: { [weak self] in self?.dismissTouchBar() }))
            ],
            legacyAction: .none,
            legacyLongAction: .none
        )

        SupportedTypesHolder.sharedInstance.register(typename: "close") { _ in
            (
                item: .staticButton(title: ""),
                actions: [
                    Action(trigger: .singleTap, value: .custom(closure: { [weak self] in
                        guard let `self` = self else { return }
                        // Closing a folder: back to the main bar, which stops the folder's items.
                        // Anywhere else, "close" reloads the preset, as it always has.
                        if GroupBarItem.shown != nil {
                            self.restoreMainBar()
                        } else {
                            self.reloadPreset(path: self.lastPresetPath)
                        }
                    }))
                ],
                legacyAction: .none,
                legacyLongAction: .none,
                parameters: [.width: .width(30), .image: .image(source: (NSImage(named: NSImage.stopProgressFreestandingTemplateName))!)])
        }

        blacklistAppIdentifiers = AppSettings.blacklistedAppIds

        ConditionMonitor.shared.onChange = { [weak self] in
            // Don't rebuild the main bar underneath an open group or popover.
            guard let self = self, self.touchBar?.delegate === self else { return }
            self.updateActiveApp()
        }
        ConditionMonitor.shared.start()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        reloadStandardConfig()
    }

    /// Loads a preset into the bar that's already showing. Items whose JSON didn't
    /// change keep running as they are; only new or changed ones are built (see
    /// createItems), so an edit doesn't blank the bar or restart every widget.
    func createAndUpdatePreset(newJsonItems: [BarItemDefinition], keys: [String]? = nil) {
        if touchBar == nil {
            touchBar = NSTouchBar()
        }
        // An open group or popover may belong to an item that's about to change.
        if subBarOwner != nil {
            for case let popover as PopoverBarItem in items.values {
                popover.collapse()
            }
            if subBarOwner != nil { restoreMainBar() }
        }

        var reusable: [String: [NSTouchBarItem.Identifier]] = [:]
        for identifier in orderedIdentifiers {
            if let key = itemKeys[identifier] { reusable[key, default: []].append(identifier) }
        }

        jsonItems = newJsonItems
        itemDefinitions = [:]
        leftIdentifiers = []
        centerIdentifiers = []
        rightIdentifiers = []
        orderedIdentifiers = []
        itemKeys = [:]
        visibleIdentifiers = nil
        ConditionMonitor.shared.reset()

        loadItemDefinitions(jsonItems: jsonItems, keys: keys?.count == jsonItems.count ? keys : nil, reusing: reusable)

        updateActiveApp()
    }

    /// Each item of a preset file as JSON with sorted keys, for comparing reloads.
    static func itemKeys(of data: Data?) -> [String]? {
        guard let json = data?.presetDocument()?.items,
              let array = (try? JSONSerialization.jsonObject(with: json)) as? [Any] else { return nil }
        return array.map { item in
            (try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString
        }
    }
    
    /// The items currently built and shown; nil forces a rebuild.
    private var visibleIdentifiers: Set<NSTouchBarItem.Identifier>?

    func prepareTouchBar() {
        // Rebuild only when the set of visible items changes (e.g. an app switch
        // that toggles a "when" condition), and stop the items being replaced.
        let visible = Set(itemDefinitions.filter { isVisible($0.value) }.keys)
        // Items inside a cluster show and hide in place, without a rebuild.
        for case let cluster as ClusterBarItem in items.values {
            cluster.updateVisibility()
        }
        updateActiveStates(items.values)
        if visible == visibleIdentifiers {
            return
        }
        visibleIdentifiers = visible
        let created = createItems(visible)
        updateActiveStates(created)

        let centerItems = centerIdentifiers.compactMap({ (identifier) -> NSTouchBarItem? in
            items[identifier]
        })

        let centerScrollArea = NSTouchBarItem.Identifier("com.toxblh.mtmr.scrollArea.".appending(UUID().uuidString))
        let scrollArea = ScrollViewItem(identifier: centerScrollArea, items: centerItems)
        
        let leftItems = leftIdentifiers.compactMap({ (identifier) -> NSTouchBarItem? in
            items[identifier]
        })
        let rightItems = rightIdentifiers.compactMap({ (identifier) -> NSTouchBarItem? in
            items[identifier]
        })

        let barItems = leftItems + [scrollArea] + rightItems
        if let basicView = basicView {
            // Swap the views inside the bar that's showing; re-presenting a new bar
            // would blank it for a moment.
            basicView.setItems(barItems, swipeItems: swipeItems)
        } else {
            basicViewIdentifier = NSTouchBarItem.Identifier("com.toxblh.mtmr.scrollView.".appending(UUID().uuidString))
            basicView = BasicView(identifier: basicViewIdentifier, items: barItems, swipeItems: swipeItems)
            applyBarSettings()
            basicView?.legacyGesturesEnabled = AppSettings.multitouchGestures
            touchBar.delegate = self
            touchBar.defaultItemIdentifiers = [basicViewIdentifier]
        }
        fadeIn(created)
    }

    /// New items appear with a short fade rather than popping in. Items still
    /// waiting for their first title fade in themselves when it arrives.
    private func fadeIn(_ newItems: [NSTouchBarItem]) {
        for item in newItems {
            if (item as? CustomButtonTouchBarItem)?.isAwaitingFirstTitle == true { continue }
            guard let view = item.view else { continue }
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                view.animator().alphaValue = 1
            }
        }
    }

    @objc func activeApplicationChanged(_: Notification) {
        updateActiveApp()
    }

    /// apps/<bundle-id>.json in the config folder, if the frontmost app has one.
    private var perAppPresetPath: String? {
        guard let bundleId = frontmostApplicationIdentifier else { return nil }
        let path = appSupportDirectory.appending("/apps/\(bundleId).json")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func updateActiveApp() {
        let desiredPreset = perAppPresetPath ?? lastPresetPath
        if !desiredPreset.isEmpty, desiredPreset != currentPresetPath {
            loadPreset(path: desiredPreset) // calls back into updateActiveApp
            return
        }
        if frontmostApplicationIdentifier != nil && blacklistAppIdentifiers.firstIndex(of: frontmostApplicationIdentifier!) != nil {
            dismissTouchBar()
        } else {
            prepareTouchBar()
            if touchBarContainsAnyItems() {
                presentTouchBar()
            } else {
                dismissTouchBar()
            }
        }
    }
    
    func touchBarContainsAnyItems() -> Bool {
        return items.count != 0 || swipeItems.count != 0
    }

    func reloadStandardConfig() {
        let presetPath = standardConfigPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: presetPath) {
            try? fm.createDirectory(atPath: appSupportDirectory, withIntermediateDirectories: true, attributes: nil)
            // Import an existing MTMR config before falling back to the bundled default.
            if fm.fileExists(atPath: legacyConfigPath) {
                try? fm.copyItem(atPath: legacyConfigPath, toPath: presetPath)
            } else if let defaultPreset = Bundle.main.path(forResource: "defaultPreset", ofType: "json") {
                try? fm.copyItem(atPath: defaultPreset, toPath: presetPath)
            }
        }

        reloadPreset(path: presetPath)
    }

    func reloadPreset(path: String) {
        lastPresetPath = path
        loadPreset(path: perAppPresetPath ?? path)
    }

    /// Set when the editor saves, so the file watcher doesn't reload a second time.
    private(set) var ignoreFileWatcherUntil = Date.distantPast

    /// Reloads the bar after the editor saved a preset (items.json or a per-app one).
    func reloadAfterEdit() {
        ignoreFileWatcherUntil = Date().addingTimeInterval(1)
        currentPresetPath = "" // force a reload even if the same preset is showing
        reloadPreset(path: lastPresetPath)
    }

    private func loadPreset(path: String) {
        currentPresetPath = path
        let data = path.fileData
        let items = data?.barItemDefinitions() ?? [BarItemDefinition(type: .staticButton(title: "bad preset"), actions: [], action: .none, legacyLongAction: .none, additionalParameters: [:])]
        let settings = data?.presetDocument()?.bar ?? BarSettings()
        // Glass is part of how each key is built, so switching it rebuilds them all.
        let rebuild = settings.glassKeys != CustomButtonTouchBarItem.glass || settings.glassStyle != CustomButtonTouchBarItem.glassStyle
        CustomButtonTouchBarItem.glass = settings.glassKeys
        CustomButtonTouchBarItem.glassStyle = settings.glassStyle
        let tintChanged = settings.glassTint != CustomButtonTouchBarItem.glassTint
        CustomButtonTouchBarItem.glassTint = settings.glassTint
        barSettings = settings
        createAndUpdatePreset(newJsonItems: items, keys: rebuild || tintChanged ? nil : TouchBarController.itemKeys(of: data))
        applyBarSettings()
    }

    /// The bar settings of the preset on the bar (its background, glass keys).
    private(set) var barSettings = BarSettings()

    func applyBarSettings() {
        guard let view = basicView?.background else { return }
        view.pausesVideoOnBattery = barSettings.pauseVideoOnBattery
        view.background = barSettings.background
    }

    /// `reusing` maps an item's JSON to identifiers of identical items already on
    /// the bar; a match takes over that identifier, and with it the live item.
    func loadItemDefinitions(jsonItems: [BarItemDefinition], keys: [String]? = nil,
                             reusing reusable: [String: [NSTouchBarItem.Identifier]] = [:]) {
        var reusable = reusable
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH-mm-ss"
        let time = dateFormatter.string(from: Date())
        for (index, item) in jsonItems.enumerated() {
            let key = keys?[index]
            let identifier: NSTouchBarItem.Identifier
            if let key = key, let reused = reusable[key]?.first {
                reusable[key]?.removeFirst()
                identifier = reused
            } else {
                identifier = NSTouchBarItem.Identifier(item.type.identifierBase.appending(time + "--" + UUID().uuidString))
            }
            if let key = key { itemKeys[identifier] = key }
            itemDefinitions[identifier] = item
            orderedIdentifiers.append(identifier)
            if item.align == .left {
                leftIdentifiers.append(identifier)
            }
            if item.align == .right {
                rightIdentifiers.append(identifier)
            }
            if item.align == .center {
                centerIdentifiers.append(identifier)
            }
        }
    }

    /// Builds the visible items, keeping any already built for the same identifier,
    /// and stops the ones no longer shown. Returns the newly built items.
    @discardableResult
    func createItems(_ visible: Set<NSTouchBarItem.Identifier>) -> [NSTouchBarItem] {
        tearDownItems(swipeItems)
        swipeItems = []
        var next: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
        var created: [NSTouchBarItem] = []

        for (identifier, definition) in itemDefinitions where visible.contains(identifier) {
            if let existing = items[identifier] {
                next[identifier] = existing
                continue
            }
            guard let item = createItem(forIdentifier: identifier, definition: definition) else { continue }
            if let swipe = item as? SwipeItem {
                swipeItems.append(swipe)
            } else {
                next[identifier] = item
                created.append(item)
            }
        }

        tearDownItems(items.filter { next[$0.key] == nil }.map { $0.value })
        items = next
        return created
    }

    /// Turns items with an "activeWhen" rule on or off.
    func updateActiveStates<S: Sequence>(_ items: S) where S.Element == NSTouchBarItem {
        for case let button as CustomButtonTouchBarItem in items {
            if let rule = button.style.activeWhen {
                button.isActive = rule.isSatisfied(frontmost: NSWorkspace.shared.frontmostApplication)
            }
        }
    }

    /// Whether an item's "when" condition (if any) currently holds. Folders and
    /// popovers with nothing in them are left off, like empty groups.
    func isVisible(_ definition: BarItemDefinition) -> Bool {
        switch definition.type {
        case let .group(items), let .popover(items, _, _, _):
            if items.isEmpty { return false }
        default: break
        }
        guard case let .when(condition)? = definition.additionalParameters[.when] else { return true }
        return condition.isSatisfied(frontmost: NSWorkspace.shared.frontmostApplication)
    }

    @objc func setupControlStripPresence() {
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        let item = NSCustomTouchBarItem(identifier: .controlStripItem)
        item.view = NSButton(image: #imageLiteral(resourceName: "StatusImage"), target: self, action: #selector(presentTouchBar))
        NSTouchBarItem.addSystemTrayItem(item)
        updateControlStripPresence()
    }

    func updateControlStripPresence() {
        let showMtmrButtonOnControlStrip = touchBarContainsAnyItems()
        DFRElementSetControlStripPresenceForIdentifier(.controlStripItem, showMtmrButtonOnControlStrip)
    }

    /// Shows `identifiers` (vended by `delegate`) in place of the main bar. Only one
    /// system-modal bar can be shown, so sub-bars take over the main one.
    /// What's showing in place of the main bar (a folder, popover or page), if anything.
    private(set) weak var subBarOwner: NSTouchBarDelegate?
    private let subBarIdentifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.subBar")
    private var subBarItem: NSCustomTouchBarItem?

    /// Shows a folder, popover or page in place of the main bar: its items in a
    /// row, over the bar's background, like the main bar.
    func showSubBar(identifiers: [NSTouchBarItem.Identifier], delegate: NSTouchBarDelegate) {
        subBarOwner = delegate
        let views = identifiers.compactMap { delegate.touchBar?(touchBar, makeItemForIdentifier: $0)?.view }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        let background = BarBackgroundView(content: row)
        background.pausesVideoOnBattery = barSettings.pauseVideoOnBattery
        background.background = barSettings.background
        let item = NSCustomTouchBarItem(identifier: subBarIdentifier)
        item.view = background
        subBarItem = item
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = []
        touchBar.defaultItemIdentifiers = [subBarIdentifier]
        presentTouchBar()
    }

    /// Returns from a sub-bar to the main bar.
    func restoreMainBar() {
        if let folder = GroupBarItem.shown {
            GroupBarItem.shown = nil
            folder.tearDown()
        }
        subBarOwner = nil
        subBarItem = nil
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = []
        touchBar.defaultItemIdentifiers = [basicViewIdentifier]
        presentTouchBar()
    }

    @objc func presentTouchBar() {
        if AppSettings.showControlStripState {
            presentSystemModal(touchBar, systemTrayItemIdentifier: .controlStripItem)
        } else {
            presentSystemModal(touchBar, placement: 1, systemTrayItemIdentifier: .controlStripItem)
        }
        updateControlStripPresence()
    }

    @objc private func dismissTouchBar() {
        if touchBarContainsAnyItems() {
            minimizeSystemModal(touchBar)
        }
        updateControlStripPresence()
    }

    @objc func resetControlStrip() {
        dismissTouchBar()
        updateActiveApp()
    }

    func touchBar(_: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == basicViewIdentifier {
            return basicView
        }
        if identifier == subBarIdentifier {
            return subBarItem
        }

        return nil
    }

    func createItem(forIdentifier identifier: NSTouchBarItem.Identifier, definition item: BarItemDefinition) -> NSTouchBarItem? {
        // The item's own look (MTMR or Stripe), for everything it builds now; items
        // built inside another (a group's) take their parent's unless they set one.
        let outer = Theme.building
        if case let .theme(name)? = item.additionalParameters[.theme] { Theme.building = Theme.named(name) }
        defer { Theme.building = outer }
        var barItem: NSTouchBarItem!
        switch item.type {
        case let .staticButton(title: title):
            barItem = CustomButtonTouchBarItem(identifier: identifier, title: title)
        case let .appleScriptTitledButton(source: source, refreshInterval: interval, alternativeImages: alternativeImages):
            barItem = AppleScriptTouchBarItem(identifier: identifier, source: source, interval: interval, alternativeImages: alternativeImages)
        case let .shellScriptTitledButton(source: source, refreshInterval: interval):
            barItem = ShellScriptTouchBarItem(identifier: identifier, source: source, interval: interval)
        case let .timeButton(formatTemplate: template, timeZone: timeZone, locale: locale):
            barItem = TimeTouchBarItem(identifier: identifier, formatTemplate: template, timeZone: timeZone, locale: locale)
        case var .battery(options):
            // The panel's back chevron defaults to the battery item's side of the bar.
            if options.panel.closeSide == nil { options.panel.closeSide = item.align == .left ? .left : .right }
            barItem = BatteryBarItem(identifier: identifier, options: options)
        case let .cpu(refreshInterval: refreshInterval, panel: panel):
            barItem = CPUBarItem(identifier: identifier, refreshInterval: refreshInterval, panel: panel.onSide(of: item))
        case let .gpu(refreshInterval: refreshInterval, panel: panel):
            barItem = GPUBarItem(identifier: identifier, refreshInterval: refreshInterval, panel: panel.onSide(of: item))
        case let .performance(design: design, panel: panel):
            barItem = PerformanceBarItem(identifier: identifier, design: design, panel: panel.onSide(of: item))
        case let .dock(autoResize: autoResize, filter: regexString):
            if let regexString = regexString {
                guard let regex = try? NSRegularExpression(pattern: regexString, options: []) else {
                    barItem = CustomButtonTouchBarItem(identifier: identifier, title: "Bad regex")
                    break
                }
                barItem = AppScrubberTouchBarItem(identifier: identifier, autoResize: autoResize, filter: regex)
            } else {
                barItem = AppScrubberTouchBarItem(identifier: identifier, autoResize: autoResize)
            }
        case .mute:
            barItem = MuteBarItem(identifier: identifier)
        case let .playPause(litWhilePlaying):
            barItem = PlayPauseBarItem(identifier: identifier, litWhilePlaying: litWhilePlaying)
        case .volume:
            if case let .image(source)? = item.additionalParameters[.image] {
                barItem = VolumeViewController(identifier: identifier, image: source.image)
            } else {
                barItem = VolumeViewController(identifier: identifier)
            }
        case let .brightness(refreshInterval: interval):
            if case let .image(source)? = item.additionalParameters[.image] {
                barItem = BrightnessViewController(identifier: identifier, refreshInterval: interval, image: source.image)
            } else {
                barItem = BrightnessViewController(identifier: identifier, refreshInterval: interval)
            }
        case let .weather(interval: interval, units: units, api_key: api_key, icon_type: icon_type):
            barItem = WeatherBarItem(identifier: identifier, interval: interval, units: units, api_key: api_key, icon_type: icon_type)
        case let .yandexWeather(interval: interval):
            barItem = YandexWeatherBarItem(identifier: identifier, interval: interval)
        case let .currency(interval: interval, from: from, to: to, full: full):
            barItem = CurrencyBarItem(identifier: identifier, interval: interval, from: from, to: to, full: full)
        case .inputsource:
            barItem = InputSourceBarItem(identifier: identifier)
        case let .music(interval: interval, disableMarquee: disableMarquee):
            barItem = MusicBarItem(identifier: identifier, interval: interval, disableMarquee: disableMarquee)
        case let .group(items: items):
            barItem = GroupBarItem(identifier: identifier, items: items)
        case let .popover(items: items, pressAndHold: pressAndHold, autoClose: autoClose, liveIcon: liveIcon):
            barItem = PopoverBarItem(identifier: identifier, items: items, pressAndHold: pressAndHold, autoClose: autoClose,
                                     align: item.align, liveIcon: liveIcon)
        case let .cluster(items: items, options: options):
            barItem = ClusterBarItem(identifier: identifier, items: items, options: options, definition: item, bar: self)
        case .nightShift:
            barItem = NightShiftBarItem(identifier: identifier)
        case .dnd:
            barItem = DnDBarItem(identifier: identifier)
        case let .pomodoro(workTime: workTime, restTime: restTime):
            barItem = PomodoroBarItem(identifier: identifier, workTime: workTime, restTime: restTime)
        case let .network(flip: flip, units: units):
            barItem = NetworkBarItem(identifier: identifier, flip: flip, units: units)
        case .darkMode:
            barItem = DarkModeBarItem(identifier: identifier)
        case let .swipe(direction: direction, fingers: fingers, minOffset: minOffset, sourceApple: sourceApple, sourceBash: sourceBash):
            barItem = SwipeItem(identifier: identifier, direction: direction, fingers: fingers, minOffset: minOffset, sourceApple: sourceApple, sourceBash: sourceBash)
        case let .upnext(from: from, to: to, maxToShow: maxToShow, autoResize: autoResize):
            barItem = UpNextScrubberTouchBarItem(identifier: identifier, interval: 60, from: from, to: to, maxToShow: maxToShow, autoResize: autoResize)
        }

        // The preset's actions replace the item's own for the same trigger (e.g. a
        // single-tap action on the battery replaces switching to time remaining).
        if let button = barItem as? CustomButtonTouchBarItem {
            var triggers = Set(item.actions.map { $0.trigger })
            if case .none = item.legacyAction {} else { triggers.insert(.singleTap) }
            if case .none = item.legacyLongAction {} else { triggers.insert(.longTap) }
            button.actions.removeAll { triggers.contains($0.trigger) }
        }
        if let action = self.action(forItem: item), let item = barItem as? CustomButtonTouchBarItem {
            item.actions.append(ItemAction(trigger: .singleTap, action))
        }
        if let longAction = self.longAction(forItem: item), let item = barItem as? CustomButtonTouchBarItem {
            item.actions.append(ItemAction(trigger: .longTap, longAction))
        }
        
        if let touchBarItem = barItem as? CustomButtonTouchBarItem {
            for action in item.actions {
                touchBarItem.actions.append(ItemAction(trigger: action.trigger, self.closure(for: action)))
            }
            // Brightness and volume keys keep stepping while held.
            for action in item.actions where action.trigger == .singleTap {
                if case let .hidKey(keycode) = action.value { touchBarItem.holdRepeat = HoldRepeat(hidKey: keycode) }
            }
        }
        if case let .bordered(bordered)? = item.additionalParameters[.bordered], let item = barItem as? CustomButtonTouchBarItem {
            item.isBordered = bordered
        }
        if case let .background(color)? = item.additionalParameters[.background], let item = barItem as? CustomButtonTouchBarItem {
            item.backgroundColor = color
        }
        if case let .glass(glass)? = item.additionalParameters[.glass], let item = barItem as? CustomButtonTouchBarItem {
            item.glass = glass
        }
        if case let .glassTint(tint)? = item.additionalParameters[.glassTint], let item = barItem as? CustomButtonTouchBarItem {
            item.glassTint = tint
        }
        if case var .width(value)? = item.additionalParameters[.width], let widthBarItem = barItem as? CanSetWidth {
            if barItem is MusicBarItem { value = max(value, MusicBarItem.minimumWidth) }
            widthBarItem.setWidth(value: value)
        }
        if case let .image(source)? = item.additionalParameters[.image], let item = barItem as? CustomButtonTouchBarItem {
            item.image = source.image
        }
        if case let .style(style)? = item.additionalParameters[.style] {
            (barItem as? HasSliderDetents)?.detents.style = style.haptic
            if let item = barItem as? CustomButtonTouchBarItem {
                item.style = style
            } else if let item = barItem as? NSPopoverTouchBarItem, let symbolImage = style.symbolImage {
                item.collapsedRepresentationImage = symbolImage
            }
        }
        if Theme.current.restyledKeys, let button = barItem as? CustomButtonTouchBarItem {
            StripeKeys.apply(to: button, definition: item)
        }
        if case let .image(source)? = item.additionalParameters[.image], let item = barItem as? NSPopoverTouchBarItem {
            item.collapsedRepresentationImage = source.image
        }
        if case let .title(value)? = item.additionalParameters[.title] {
            if let item = barItem as? NSPopoverTouchBarItem {
                item.collapsedRepresentationLabel = value
            } else if let item = barItem as? CustomButtonTouchBarItem {
                item.title = value
            }
        }
        return barItem
    }
    
    func closure(for action: Action) -> (() -> Void)? {
        if case let .shellScript(_, parameters) = action.value,
           parameters.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            return nil // e.g. an action just added in Settings, before a command is typed
        }
        switch action.value {
        case let .hidKey(keycode: keycode):
            return { AccessibilityPermission.requestIfNeeded(); HIDPostAuxKey(keycode) }
        case let .keyPress(keycode: keycode):
            return { AccessibilityPermission.requestIfNeeded(); GenericKeyPress(keyCode: CGKeyCode(keycode)).send() }
        case let .appleScript(source: source):
            guard let appleScript = source.appleScript else {
                print("cannot create apple script for item \(action)")
                return {}
            }
            return {
                DispatchQueue.appleScriptQueue.async {
                    var error: NSDictionary?
                    appleScript.executeAndReturnError(&error)
                    if let error = error {
                        print("error \(error) when handling \(action) ")
                    }
                }
            }
        case let .shellScript(executable: executable, parameters: parameters):
            return {
                let task = Process()
                task.launchPath = executable
                task.arguments = parameters
                task.launch()
            }
        case let .openUrl(url: url):
            return {
                if let url = URL(string: url), NSWorkspace.shared.open(url) {
                    #if DEBUG
                        print("URL was successfully opened")
                    #endif
                } else {
                    print("error", url)
                }
            }
        case let .custom(closure: closure):
            return closure
        case .none:
            return nil
        }
    }

    func action(forItem item: BarItemDefinition) -> (() -> Void)? {
        switch item.legacyAction {
        case let .hidKey(keycode: keycode):
            return { AccessibilityPermission.requestIfNeeded(); HIDPostAuxKey(keycode) }
        case let .keyPress(keycode: keycode):
            return { AccessibilityPermission.requestIfNeeded(); GenericKeyPress(keyCode: CGKeyCode(keycode)).send() }
        case let .appleScript(source: source):
            guard let appleScript = source.appleScript else {
                print("cannot create apple script for item \(item)")
                return {}
            }
            return {
                DispatchQueue.appleScriptQueue.async {
                    var error: NSDictionary?
                    appleScript.executeAndReturnError(&error)
                    if let error = error {
                        print("error \(error) when handling \(item) ")
                    }
                }
            }
        case let .shellScript(executable: executable, parameters: parameters):
            return {
                let task = Process()
                task.launchPath = executable
                task.arguments = parameters
                task.launch()
            }
        case let .openUrl(url: url):
            return {
                if let url = URL(string: url), NSWorkspace.shared.open(url) {
                    #if DEBUG
                        print("URL was successfully opened")
                    #endif
                } else {
                    print("error", url)
                }
            }
        case let .custom(closure: closure):
            return closure
        case .none:
            return nil
        }
    }

    func longAction(forItem item: BarItemDefinition) -> (() -> Void)? {
        switch item.legacyLongAction {
        case let .hidKey(keycode: keycode):
            return { AccessibilityPermission.requestIfNeeded(); HIDPostAuxKey(keycode) }
        case let .keyPress(keycode: keycode):
            return { AccessibilityPermission.requestIfNeeded(); GenericKeyPress(keyCode: CGKeyCode(keycode)).send() }
        case let .appleScript(source: source):
            guard let appleScript = source.appleScript else {
                print("cannot create apple script for item \(item)")
                return {}
            }
            return {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    print("error \(error) when handling \(item) ")
                }
            }
        case let .shellScript(executable: executable, parameters: parameters):
            return {
                let task = Process()
                task.launchPath = executable
                task.arguments = parameters
                task.launch()
            }
        case let .openUrl(url: url):
            return {
                if let url = URL(string: url), NSWorkspace.shared.open(url) {
                    #if DEBUG
                        print("URL was successfully opened")
                    #endif
                } else {
                    print("error", url)
                }
            }
        case let .custom(closure: closure):
            return closure
        case .none:
            return nil
        }
    }
}

protocol CanSetWidth {
    func setWidth(value: CGFloat)
}

extension NSCustomTouchBarItem: CanSetWidth {
    func setWidth(value: CGFloat) {
        view.widthAnchor.constraint(equalToConstant: value).isActive = true
    }
}

extension NSPopoverTouchBarItem: CanSetWidth {
    func setWidth(value: CGFloat) {
        view?.widthAnchor.constraint(equalToConstant: value).isActive = true
    }
}

extension BarItemDefinition {
    var align: Align {
        if case let .align(result)? = additionalParameters[.align] {
            return result
        }
        return .center
    }
}
