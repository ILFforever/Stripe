//
//  PopoverBarItem.swift
//  Stripe
//
//  A collapsible item, like the volume and brightness buttons in Apple's Control
//  Strip: a compact button that expands into a sub-bar with a close button, and
//  optionally supports press-and-hold, where holding the button and sliding
//  sideways adjusts the first child (e.g. a volume slider) without lifting.
//
//    {
//      "type": "popover", "symbol": "speaker.wave.2.fill",
//      "items": [ { "type": "volume" }, { "type": "mute" } ],
//      "pressAndHold": true,   // hold + slide adjusts the first item
//      "autoClose": 4,         // seconds of inactivity before collapsing (optional)
//      "liveIcon": true        // with a volume slider first: the icon shows the
//    }                         // current level (0–3 waves, or a slash when muted)
//
//  The expanded controls open on the same side as the button (a right-aligned
//  button expands at the right, with ✕ at the far right where the finger already
//  is), and tapping the empty rest of the bar closes them.
//
//  Apple's NSPopoverTouchBarItem can't open from a system-modal bar like ours, and
//  only one system-modal bar shows at a time, so the sub-bar takes over the main bar.
//  The button is "expanded" while the main bar shows this item's children.
//

import Cocoa

/// A child item whose value press-and-hold sliding can adjust.
protocol SlidableItem: AnyObject {
    /// 0...1
    var sliderValue: Double { get set }
}

class PopoverBarItem: CustomButtonTouchBarItem, NSTouchBarDelegate, TearDownable {
    private let autoClose: TimeInterval?
    private let align: Align
    private var audioObserver: AudioOutputObserver?
    private let expandedIdentifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.popover.expanded." + UUID().uuidString)
    private var childIdentifiers: [NSTouchBarItem.Identifier] = []
    private var childDefinitions: [NSTouchBarItem.Identifier: BarItemDefinition] = [:]
    private var childItems: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    private let closeIdentifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.popover.close." + UUID().uuidString)
    private var autoCloseTimer: Timer?

    init(identifier: NSTouchBarItem.Identifier, items: [BarItemDefinition], pressAndHold: Bool, autoClose: TimeInterval?,
         align: Align, liveIcon: Bool) {
        self.autoClose = autoClose
        self.align = align
        super.init(identifier: identifier, title: "")

        for definition in items {
            let id = NSTouchBarItem.Identifier(definition.type.identifierBase + UUID().uuidString)
            childIdentifiers.append(id)
            childDefinitions[id] = definition
        }

        actions.append(ItemAction(trigger: .singleTap) { [weak self] in self?.expand() })

        // A volume popover's icon follows the actual volume, like the Control Strip's.
        if liveIcon, case .volume? = items.first?.type {
            audioObserver = AudioOutputObserver { [weak self] in self?.updateLiveIcon() }
        }

        if pressAndHold {
            let slide = HoldSlideGestureRecognizer(target: self, action: #selector(handleHoldSlide(_:)))
            slide.allowedTouchTypes = .direct
            // The button view is rebuilt whenever styling changes; re-attach each time.
            finishViewConfiguration = { [weak self] in self?.view.addGestureRecognizer(slide) }
            finishViewConfiguration()
        }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var style: ItemStyle {
        didSet { updateLiveIcon() } // keep the live icon when the preset's style is applied
    }

    private func updateLiveIcon() {
        guard let observer = audioObserver else { return }
        var live = style
        live.symbol = observer.speakerSymbol
        if let icon = live.symbolImage {
            image = icon
        }
    }

    func tearDown() {
        audioObserver?.stop()
        audioObserver = nil
        autoCloseTimer?.invalidate()
        tearDownItems(childItems.values)
        childItems = [:]
    }

    // MARK: Expand / collapse

    private(set) var isExpanded = false

    @objc func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        TouchBarController.shared.showSubBar(identifiers: [expandedIdentifier], delegate: self)
        scheduleAutoClose()
    }

    @objc func collapse() {
        autoCloseTimer?.invalidate()
        guard isExpanded else { return }
        isExpanded = false
        TouchBarController.shared.restoreMainBar()
    }

    /// The whole expanded bar as one item (so it can span the full width, like
    /// the main bar): controls anchored on the button's side, and the empty
    /// remainder a tap target that closes it.
    private func makeExpandedItem() -> NSTouchBarItem {
        let close = makeItem(closeIdentifier)?.view.map { [$0] } ?? []
        let children = childIdentifiers.compactMap { makeItem($0)?.view }
        let dismiss = { [weak self] in self?.collapse() ?? () }
        let views: [NSView]
        switch align {
        case .right: // ✕ at the far right, where the button was
            views = [DismissArea(onTap: dismiss)] + children + close
        case .left:
            views = close + children + [DismissArea(onTap: dismiss)]
        case .center:
            views = [DismissArea(onTap: dismiss)] + close + children + [DismissArea(onTap: dismiss)]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        // Set the close button apart from the controls it closes.
        let gap = Theme.current.closeButton.gap
        if align == .right, let lastChild = children.last {
            stack.setCustomSpacing(gap, after: lastChild)
        } else if align != .right, let closeView = close.first {
            stack.setCustomSpacing(gap, after: closeView)
        }
        // Keep the round ✕ whole where it meets the bar's end.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        if align == .center, let first = views.first, let last = views.last {
            first.widthAnchor.constraint(equalTo: last.widthAnchor).isActive = true
        }
        let item = NSCustomTouchBarItem(identifier: expandedIdentifier)
        item.view = stack
        return item
    }

    /// The expanded bar as it would show, for Settings to picture without opening it.
    func makePreviewView() -> NSView? {
        makeExpandedItem().view
    }

    private func scheduleAutoClose() {
        autoCloseTimer?.invalidate()
        guard let autoClose = autoClose else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: autoClose, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    // MARK: Press-and-hold sliding

    private var slideStartValue: Double = 0

    /// Points of horizontal travel that sweep the full 0...1 range.
    private let slideTravel: CGFloat = 250

    @objc private func handleHoldSlide(_ recognizer: HoldSlideGestureRecognizer) {
        guard let slidable = firstSlidableChild() else { return }
        switch recognizer.state {
        case .began:
            slideStartValue = slidable.sliderValue
            expand()
            autoCloseTimer?.invalidate()
            HapticFeedback.instance.tap(type: .strong)
        case .changed:
            slidable.sliderValue = slideStartValue + Double(recognizer.translation / slideTravel)
        case .ended:
            collapse()
        case .cancelled, .failed:
            NSLog("Stripe: press-and-hold slide was cancelled (state \(recognizer.state.rawValue))")
            collapse()
        default:
            break
        }
    }

    private func firstSlidableChild() -> SlidableItem? {
        guard let first = childIdentifiers.first else { return nil }
        return makeChild(first) as? SlidableItem
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        return identifier == expandedIdentifier ? makeExpandedItem() : makeItem(identifier)
    }

    private var closeItem: NSTouchBarItem?

    private func makeItem(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == closeIdentifier {
            if let close = closeItem { return close }
            // A small circle with a bold ✕, like macOS's own Touch Bar controls.
            let close = NSCustomTouchBarItem(identifier: identifier)
            close.view = CloseButtonView(theme: Theme.current.closeButton) { [weak self] in self?.collapse() }
            closeItem = close
            return close
        }
        return makeChild(identifier)
    }

    private func makeChild(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if let item = childItems[identifier] {
            return item
        }
        guard let definition = childDefinitions[identifier],
              let item = TouchBarController.shared.createItem(forIdentifier: identifier, definition: definition) else { return nil }
        // Any interaction inside the expanded bar postpones auto-close.
        if let button = item as? CustomButtonTouchBarItem {
            button.actions.append(ItemAction(trigger: .singleTap) { [weak self] in self?.scheduleAutoClose() })
        }
        childItems[identifier] = item
        return item
    }
}

/// Recognizes a press held briefly without moving, then reports horizontal
/// travel until the finger lifts. Quick taps fail it, so they still reach the
/// button's own tap handling.
class HoldSlideGestureRecognizer: NSGestureRecognizer {
    var holdDuration: TimeInterval = 0.25
    private(set) var translation: CGFloat = 0
    private var startX: CGFloat = 0
    private var holdTimer: Timer?

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        guard let view = view, let touch = event.touches(matching: .began, in: view).first else { return }
        startX = touch.location(in: view).x
        translation = 0
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.state = .began
        }
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        guard let view = view, let touch = event.touches(matching: .moved, in: view).first else { return }
        translation = touch.location(in: view).x - startX
        if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        holdTimer?.invalidate()
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        holdTimer?.invalidate()
        state = .cancelled
    }

    override func reset() {
        super.reset()
        holdTimer?.invalidate()
        translation = 0
    }
}

/// Fills the unused part of an expanded bar; tapping it closes the popover.
/// It has no intrinsic width, so the stack stretches it over the leftover space.
class DismissArea: NSView {
    private let onTap: () -> Void

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap()
    }
}

/// The close button of an expanded popover: a circle with a ✕, drawn at the
/// theme's size and vertically centered in the bar. A plain view rather than a
/// button, since NSButton on the Touch Bar insists on full bar height.
class CloseButtonView: NSView {
    private let theme: Theme.CloseButton
    private let onTap: () -> Void
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(theme: Theme.CloseButton, onTap: @escaping () -> Void) {
        self.theme = theme
        self.onTap = onTap
        super.init(frame: .zero)
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        // A little wider than the circle so it's easy to hit.
        return NSSize(width: theme.diameter + 8, height: 30)
    }

    override func draw(_: NSRect) {
        let d = theme.diameter
        let circle = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        (pressed ? theme.background.blended(withFraction: 0.3, of: .black) ?? theme.background : theme.background).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let config = NSImage.SymbolConfiguration(pointSize: theme.glyphSize, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [theme.glyph]))
        guard let glyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(config) else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    override func touchesBegan(with event: NSEvent) {
        pressed = true
        super.touchesBegan(with: event)
    }

    override func touchesEnded(with event: NSEvent) {
        pressed = false
        super.touchesEnded(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        pressed = false
        super.touchesCancelled(with: event)
    }

    @objc private func tapped() {
        onTap()
    }
}
