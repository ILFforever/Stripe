//
//  TouchBarItems.swift
//  MTMR
//
//  Created by Anton Palgunov on 18/03/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa

struct ItemAction {
    typealias TriggerClosure = (() -> Void)?
    
    let trigger: Action.Trigger
    let closure: TriggerClosure
    
    init(trigger: Action.Trigger, _ closure: TriggerClosure) {
        self.trigger = trigger
        self.closure = closure
    }
}

class CustomButtonTouchBarItem: NSCustomTouchBarItem, NSGestureRecognizerDelegate {
    
    var actions: [ItemAction] = [] {
        didSet {
            multiClick.isDoubleClickEnabled = actions.filter({ $0.trigger == .doubleTap }).count > 0
            multiClick.isTripleClickEnabled = actions.filter({ $0.trigger == .tripleTap }).count > 0
            longClick.isEnabled = actions.filter({ $0.trigger == .longTap }).count > 0
        }
    }
    var finishViewConfiguration: ()->() = {}
    
    private var button: NSButton!
    /// The look it was built with ("theme" on the item); kept for later refreshes.
    let theme = Theme.current
    private var longClick: LongPressGestureRecognizer!
    private var multiClick: MultiClickGestureRecognizer!

    init(identifier: NSTouchBarItem.Identifier, title: String) {
        attributedTitle = title.defaultTouchbarAttributedString

        super.init(identifier: identifier)
        button = CustomHeightButton(title: title, target: nil, action: nil)

        longClick = LongPressGestureRecognizer(target: self, action: #selector(handleGestureLong))
        longClick.isEnabled = false
        longClick.allowedTouchTypes = .direct
        longClick.delegate = self
        
        multiClick = MultiClickGestureRecognizer(
            target: self,
            action: #selector(handleGestureSingleTap),
            doubleAction: #selector(handleGestureDoubleTap),
            tripleAction: #selector(handleGestureTripleTap)
        )
        multiClick.allowedTouchTypes = .direct
        multiClick.delegate = self
        multiClick.isDoubleClickEnabled = false
        multiClick.isTripleClickEnabled = false
        multiClick.onTouch = { [weak self] down in self?.isPressed = down }
        multiClick.handlesReleaseHaptic = { [weak self] in self?.armToggleFeel() ?? false }

        reinstallButton()
        button.attributedTitle = displayedTitle
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isBordered: Bool = true {
        didSet {
            reinstallButton()
        }
    }

    /// Room kept for a multi-line title, so the key doesn't resize as its text changes.
    var minimumTitleWidth: CGFloat = 0 {
        didSet { (button as? CustomHeightButton)?.minimumTitleWidth = minimumTitleWidth }
    }

    var backgroundColor: NSColor? {
        didSet {
            reinstallButton()
        }
    }

    /// Whether the item is on (a toggle that's enabled, or its "activeWhen" rule
    /// holds); shows `style.activeBackground`.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyStateBackground()
            applyActiveLook()
            playToggleFeelIfArmed()
        }
    }

    /// For items that know their own state: sets `isActive` unless the preset
    /// decides it with an "activeWhen" rule.
    func setBuiltInActive(_ active: Bool) {
        hasOnOffState = true
        if style.activeWhen == nil { isActive = active }
    }

    // MARK: Toggle feel

    /// Whether the item has an on/off state: a toggle that reports it, or an "activeWhen" rule.
    private var hasOnOffState = false
    /// Until when a tap's release is waiting for the toggle to report its new state.
    private var toggleFeelArmedUntil = Date.distantPast

    /// A toggle's release buzzes by what the tap did (its on or off feel)
    /// once its state changes, instead of the usual release tick. Returns
    /// whether it will, so the plain tick is skipped.
    private func armToggleFeel() -> Bool {
        let haptic = style.haptic
        guard hasOnOffState || style.activeWhen != nil, haptic.toggleFeel,
              haptic.when == .both || haptic.when == .release else { return false }
        // Scripted "activeWhen" checks can take a few seconds to report back.
        toggleFeelArmedUntil = Date().addingTimeInterval(style.activeWhen == nil ? 1.5 : 4)
        return true
    }

    private func playToggleFeelIfArmed() {
        guard Date() < toggleFeelArmedUntil else { return }
        toggleFeelArmedUntil = .distantPast
        HapticFeedback.instance.play(style.haptic.toggleFeel(turnedOn: isActive))
    }

    /// True while a finger is on the item; shows `style.pressedBackground`.
    /// Settable so debug hooks can hold an item down for a screenshot.
    var isPressed = false {
        didSet { if isPressed != oldValue { applyStateBackground() } }
    }

    /// Extra space on each side of the content, for items whose content would
    /// otherwise sit tight against the key's edges (e.g. the battery).
    var contentPadding: CGFloat = 0 {
        didSet { reinstallButton() }
    }

    var style = ItemStyle() {
        didSet {
            multiClick.haptic = style.haptic
            longClick.haptic = style.haptic
            if let symbolImage = style.symbolImage {
                image = symbolImage
            }
            reinstallButton()
            button.attributedTitle = displayedTitle
            if isActive { applyActiveLook() }
        }
    }

    /// The title as drawn: `attributedTitle` with the item's style applied.
    var displayedTitle: NSAttributedString {
        if isActive {
            let title = style.activeTitle.map { $0.defaultTouchbarAttributedString } ?? attributedTitle
            return style.whileActive.apply(to: title)
        }
        return style.apply(to: attributedTitle)
    }

    /// The icon as drawn: while on, the "activeSymbol" (if set) in place of the
    /// item's own, or the item's own icon in "activeIconColor".
    private var displayedImage: NSImage? {
        guard isActive else { return image }
        if style.activeSymbol != nil, let symbol = style.whileActive.symbolImage { return symbol }
        if let color = style.activeIconColor, let image = image, image.isTemplate { return image.tinted(color) }
        return image
    }

    /// Shows the on or off look: title, icon, and the icon tint for icons the item draws itself.
    private func applyActiveLook() {
        guard let button = button else { return }
        button.image = displayedImage
        button.attributedTitle = displayedTitle
        button.imagePosition = displayedTitle.length > 0 ? .imageLeading : .imageOnly
    }

    var title: String {
        get {
            return attributedTitle.string
        }
        set {
            attributedTitle = newValue.defaultTouchbarAttributedString
        }
    }

    var attributedTitle: NSAttributedString {
        didSet {
            // Widgets often set the same title again (a clock every second); skip the redraw.
            guard !attributedTitle.isEqual(to: oldValue) else { return }
            button?.imagePosition = displayedTitle.length > 0 ? .imageLeading : .imageOnly
            button?.attributedTitle = displayedTitle
            if isAwaitingFirstTitle, attributedTitle.length > 0 { reveal() }
        }
    }

    /// True while hidden by `hideUntilFirstTitle`.
    private(set) var isAwaitingFirstTitle = false

    /// For items whose title comes from a script or a reading: stay invisible
    /// until the first title arrives, then fade in, instead of showing a
    /// placeholder. Fades in after two seconds regardless.
    func hideUntilFirstTitle() {
        // The MTMR theme shows "⏳" until then, as MTMR did.
        guard theme.fadeInFirstTitle else {
            attributedTitle = "⏳".defaultTouchbarAttributedString
            return
        }
        isAwaitingFirstTitle = true
        button.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reveal() }
    }

    private func reveal() {
        guard isAwaitingFirstTitle else { return }
        isAwaitingFirstTitle = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            button.animator().alphaValue = 1
        }
    }

    var image: NSImage? {
        didSet {
            button.image = displayedImage
        }
    }

    private func reinstallButton() {
        let title = button.attributedTitle
        let image = button.image
        let cell = CustomButtonCell(parentItem: self)
        button.cell = cell
        (button as? CustomHeightButton)?.horizontalPadding = max(drawnRadius != nil ? 10 : 0, contentPadding)
        button.wantsLayer = drawnRadius != nil
        button.layer?.cornerRadius = drawnRadius ?? 0
        button.layer?.backgroundColor = nil
        if let color = fillColor, let radius = drawnRadius {
            // Custom-radius background: draw it on the layer, not with a bezel.
            button.isBordered = false
            button.bezelStyle = .inline
            // Glass is drawn by the cell (CustomButtonCell), under the icon and title.
            button.layer?.backgroundColor = drawsGlass ? nil : color.cgColor
            button.layer?.cornerRadius = radius
        } else if let color = backgroundColor {
            cell.isBordered = true
            button.bezelColor = color
            button.bezelStyle = .rounded
            cell.backgroundColor = color
        } else {
            button.isBordered = isBordered
            button.bezelStyle = isBordered ? .rounded : .inline
        }
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = true
        button.attributedTitle = title
        button?.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.image = image
        view = button

        view.addGestureRecognizer(longClick)
        // view.addGestureRecognizer(singleClick)
        view.addGestureRecognizer(multiClick)
        applyStateBackground()
        finishViewConfiguration()
    }

    /// An SF Symbol sized for a key, as Stripe's designs use them.
    func stripeSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// The system's gray key, as it looks on the bar.
    static let standardKeyColor = NSColor(srgbRed: 0x44 / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)

    /// The background drawn behind the key. The system draws its gray key only
    /// at its own rounding, so with a shape set we draw that gray ourselves.
    private var fillColor: NSColor? {
        backgroundColor ?? (isBordered && drawnRadius != nil
            ? (usesGlass ? CustomButtonTouchBarItem.glassFill : CustomButtonTouchBarItem.standardKeyColor) : nil)
    }

    /// Translucent "glass" keys, so the bar's background shows through: the
    /// preset's "glassKeys" (the Theme's Keys), set before its items are built.
    static var glass = false

    /// This key's own choice ("glass" on the item), else the bar's.
    var glass: Bool? {
        didSet { if glass != oldValue { reinstallButton() } }
    }

    var usesGlass: Bool { glass ?? CustomButtonTouchBarItem.glass }

    /// The bar's glass strength and tint, set with `glass`.
    static var glassStyle = GlassStyle.balanced
    static var glassTint: NSColor?

    /// This key's own glass tint ("glassTint"), else the bar's.
    var glassTint: NSColor? {
        didSet { button?.needsDisplay = true }
    }

    var effectiveGlassTint: NSColor? { glassTint ?? CustomButtonTouchBarItem.glassTint }

    /// Whether the key is drawn as glass right now: a glass key with no color of
    /// its own, and no pressed or on color showing over it.
    var drawsGlass: Bool {
        guard usesGlass, isBordered, backgroundColor == nil else { return false }
        if isPressed, style.pressedBackground != nil { return false }
        if isActive, !isPressed, style.activeBackground != nil { return false }
        return true
    }

    var glassRadius: CGFloat { drawnRadius ?? 6 }
    static let glassFill = NSColor(white: 1, alpha: 0.16)

    /// The rounding when we draw the key ourselves (the system's key has its own).
    private var drawnRadius: CGFloat? {
        style.cornerRadius ?? (usesGlass && isBordered && backgroundColor == nil ? 6 : nil)
    }

    /// Our stand-in for the gray key lightens while touched, as the system's does.
    private var drawnStandardPressed: NSColor? {
        guard backgroundColor == nil, fillColor != nil else { return nil }
        // Glass brightens rather than turning solid gray.
        return usesGlass ? NSColor(white: 1, alpha: 0.32)
            : NSColor(srgbRed: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
    }

    /// The pressed or active color when one applies, else the normal background.
    /// Only colors change here, so a press doesn't rebuild the button mid-touch.
    private func applyStateBackground() {
        guard let button = button else { return }
        var color = fillColor
        if isPressed, let pressed = style.pressedBackground ?? drawnStandardPressed {
            color = pressed
        } else if isActive, let active = style.activeBackground {
            color = active
        }
        if button.isBordered {
            button.bezelColor = color
        } else if color != nil || button.wantsLayer {
            button.wantsLayer = true
            // Glass is drawn by the cell; a pressed or on color shows solid over it.
            button.layer?.backgroundColor = drawsGlass ? nil : color?.cgColor
            button.layer?.cornerRadius = drawnRadius ?? 6
            if usesGlass { button.needsDisplay = true }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        if gestureRecognizer == multiClick && otherGestureRecognizer == longClick
            || gestureRecognizer == longClick && otherGestureRecognizer == multiClick // need it
        {
            return false
        }
        return true
    }
    
    func callActions(for trigger: Action.Trigger) {
        let itemActions = self.actions.filter { $0.trigger == trigger }
        for itemAction in itemActions {
            itemAction.closure?()
        }
    }
    
    @objc func handleGestureSingleTap() {
        callActions(for: .singleTap)
    }
    
    @objc func handleGestureDoubleTap() {
        callActions(for: .doubleTap)
    }
    
    @objc func handleGestureTripleTap() {
        callActions(for: .tripleTap)
    }

    @objc func handleGestureLong(gr: NSPressGestureRecognizer) {
        switch gr.state {
        case .possible: // tiny hack because we're calling action manually
            callActions(for: .longTap)
            break
        default:
            break
        }
    }
}

class CustomHeightButton: NSButton {
    /// Extra width on each side, so text isn't flush against a pill's edges.
    var horizontalPadding: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// Side margin for multi-line titles; small text needs less room than a label.
    static let multilineInset: CGFloat = 4

    /// See CustomButtonTouchBarItem.minimumTitleWidth.
    var minimumTitleWidth: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// A key we draw ourselves fills exactly the bar's height. Left to NSButton,
    /// an icon's alignment insets (SF Symbols like sun.max have them) stretch the
    /// frame past the bar, cutting off the key's rounded corners.
    override var alignmentRectInsets: NSEdgeInsets {
        isBordered ? super.alignmentRectInsets : NSEdgeInsetsZero
    }

    /// Called after each layout, e.g. to keep an overlay aligned with the image.
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    private static var measured: (title: NSAttributedString, size: NSSize)?

    /// A multi-line title's size, remembered for the last title measured: laying
    /// the text out is the costly part, and it's asked for on every layout and draw.
    static func measure(_ title: NSAttributedString) -> NSSize {
        if let last = measured, last.title.isEqual(to: title) { return last.size }
        let size = title.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin]).size
        measured = (title.copy() as! NSAttributedString, size)
        return size
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = 30
        let imageWidth = image.map { $0.size.width + 4 } ?? 0
        // NSButton measures a multi-line title as one long line; use the widest line.
        if attributedTitle.string.contains("\n") {
            let textWidth = ceil(CustomHeightButton.measure(attributedTitle).width)
            size.width = max(textWidth, minimumTitleWidth) + imageWidth + 2 * CustomHeightButton.multilineInset
        } else if minimumTitleWidth > 0 {
            // Holds the space before the first title arrives, too.
            size.width = max(size.width, minimumTitleWidth + imageWidth + 2 * CustomHeightButton.multilineInset)
        }
        size.width += horizontalPadding * 2
        return size
    }
}

class CustomButtonCell: NSButtonCell {
    weak var parentItem: CustomButtonTouchBarItem?

    init(parentItem: CustomButtonTouchBarItem) {
        super.init(textCell: "")
        self.parentItem = parentItem
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        if !isBordered {
            if flag {
                setAttributedTitle(attributedTitle, withColor: .lightGray)
            } else if let parentItem = self.parentItem {
                attributedTitle = parentItem.displayedTitle
            }
        }
    }
    
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        return rect // need that so content may better fit in button with very limited width
    }

    /// Glass keys: the pane first, then the icon and title over it.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let item = parentItem, item.drawsGlass {
            GlassPainter.draw(in: controlView, rect: controlView.bounds, radius: item.glassRadius,
                              pressed: item.isPressed, style: CustomButtonTouchBarItem.glassStyle,
                              tint: item.effectiveGlassTint)
            NSGraphicsContext.saveGraphicsState()
            GlassPainter.contentShadow.set()
            super.draw(withFrame: cellFrame, in: controlView)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        super.draw(withFrame: cellFrame, in: controlView)
    }

    /// NSButtonCell lays a title out as one line, so a second line would hang off
    /// the bottom of the key. Draw multi-line titles as a block centered in the key.
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard title.string.contains("\n") else {
            return super.drawTitle(title, withFrame: frame, in: controlView)
        }
        let size = CustomHeightButton.measure(title)
        let bounds = controlView.bounds
        // With an icon, stay in the space beside it; otherwise use the whole key.
        let midX = image == nil ? bounds.midX : frame.midX
        let rect = NSRect(x: midX - ceil(size.width) / 2,
                          y: bounds.midY - ceil(size.height) / 2,
                          width: ceil(size.width), height: ceil(size.height))
        title.draw(with: rect, options: [.usesLineFragmentOrigin])
        return rect
    }

    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAttributedTitle(_ title: NSAttributedString, withColor color: NSColor) {
        let attrTitle = NSMutableAttributedString(attributedString: title)
        attrTitle.addAttributes([.foregroundColor: color], range: NSRange(location: 0, length: attrTitle.length))
        attributedTitle = attrTitle
    }
}

// Thanks to https://stackoverflow.com/a/49843893
final class MultiClickGestureRecognizer: NSClickGestureRecognizer {

    private let _action: Selector
    private let _doubleAction: Selector
    private let _tripleAction: Selector
    private var _clickCount: Int = 0
    
    public var isDoubleClickEnabled = true
    public var isTripleClickEnabled = true
    /// Called with true when a touch starts and false when it ends.
    var onTouch: ((Bool) -> Void)?
    /// How touches buzz; the item sets it from its style.
    var haptic = HapticStyle()
    /// Lets the item play its own release buzz (a toggle's on/off feel); returns true if it will.
    var handlesReleaseHaptic: (() -> Bool)?

    override var action: Selector? {
        get {
            return nil /// prevent base class from performing any actions
        } set {
            if newValue != nil { // if they are trying to assign an actual action
                fatalError("Only use init(target:action:doubleAction) for assigning actions")
            }
        }
    }

    required init(target: AnyObject, action: Selector, doubleAction: Selector, tripleAction: Selector) {
        _action = action
        _doubleAction = doubleAction
        _tripleAction = tripleAction
        super.init(target: target, action: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(target:action:doubleAction:tripleAction) is only support atm")
    }
    
    /// Whether the key shows as pressed; released once, however the touch ends.
    private var touching = false {
        didSet { if touching != oldValue { onTouch?(touching) } }
    }

    override func touchesBegan(with event: NSEvent) {
        HapticFeedback.instance.play(haptic, .press)
        touching = true
        super.touchesBegan(with: event)
    }

    /// Sliding off the key lets it go straight away, like a button.
    override func touchesMoved(with event: NSEvent) {
        if touching, let view = view,
           let touch = event.touches(matching: .moved, in: view).first,
           !view.bounds.contains(touch.location(in: view)) {
            touching = false
        }
        super.touchesMoved(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        touching = false
        super.touchesCancelled(with: event)
    }

    /// A touch that moved too far fails the click, and a failed recognizer hears
    /// no more touches (no touchesEnded), so it's released here, where every
    /// outcome ends up.
    override func reset() {
        touching = false
        super.reset()
    }

    override func touchesEnded(with event: NSEvent) {
        if handlesReleaseHaptic?() != true {
            HapticFeedback.instance.play(haptic, .release)
        }
        touching = false
        super.touchesEnded(with: event)
        _clickCount += 1
        
        var delayThreshold: TimeInterval // fine tune this as needed
        
        guard isDoubleClickEnabled || isTripleClickEnabled else {
            _ = target?.perform(_action)
            return
        }
        
        if (isTripleClickEnabled) {
            delayThreshold = 0.4
            perform(#selector(_resetAndPerformActionIfNecessary), with: nil, afterDelay: delayThreshold)
            if _clickCount == 3 {
                _ = target?.perform(_tripleAction)
            }
        } else {
            delayThreshold = 0.3
            perform(#selector(_resetAndPerformActionIfNecessary), with: nil, afterDelay: delayThreshold)
            if _clickCount == 2 {
                _ = target?.perform(_doubleAction)
            }
        }
    }

    @objc private func _resetAndPerformActionIfNecessary() {
        if _clickCount == 1 {
            _ = target?.perform(_action)
        }
        if isTripleClickEnabled && _clickCount == 2 {
            _ = target?.perform(_doubleAction)
        }
        _clickCount = 0
    }
}

class LongPressGestureRecognizer: NSPressGestureRecognizer {
    var recognizeTimeout = 0.4
    /// How touches buzz; the item sets it from its style.
    var haptic = HapticStyle()
    private var timer: Timer?
    
    override func touchesBegan(with event: NSEvent) {
        timerInvalidate()
        
        let touches = event.touches(for: self.view!)
        if touches.count == 1 { // to prevent it for built-in two/three-finger gestures
            timer = Timer.scheduledTimer(timeInterval: recognizeTimeout, target: self, selector: #selector(self.onTimer), userInfo: nil, repeats: false)
        }
        
        super.touchesBegan(with: event)
    }
    
    override func touchesMoved(with event: NSEvent) {
        timerInvalidate() // to prevent it for built-in two/three-finger gestures
        super.touchesMoved(with: event)
    }
    
    override func touchesCancelled(with event: NSEvent) {
        timerInvalidate()
        super.touchesCancelled(with: event)
    }
    
    override func touchesEnded(with event: NSEvent) {
        timerInvalidate()
        super.touchesEnded(with: event)
    }
    
    private func timerInvalidate() {
        if let timer = timer {
            timer.invalidate()
            self.timer = nil
        }
    }
    
    @objc private func onTimer() {
        if let target = self.target, let action = self.action {
            target.performSelector(onMainThread: action, with: self, waitUntilDone: false)
            HapticFeedback.instance.play(haptic, .hold)
        }
    }
    
    deinit {
        timerInvalidate()
    }
}

extension String {
    var defaultTouchbarAttributedString: NSAttributedString {
        let attrTitle = NSMutableAttributedString(string: self, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .regular), .baselineOffset: 1])
        attrTitle.setAlignment(.center, range: NSRange(location: 0, length: count))
        return attrTitle
    }
}

extension NSImage {
    /// A template image drawn in `color`. (The Touch Bar ignores a button's tint color.)
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
