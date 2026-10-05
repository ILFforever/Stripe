//
//  CardsBarItem.swift
//  Stripe
//
//  A slot that holds several cards, each a row of items, drawn as a deck: the
//  cards still to come sit behind the top one, each showing a thin edge on the
//  right, so you can see there's more. Swiping left deals the top card off the
//  left side (it goes soft as it leaves) while the next one comes forward;
//  swiping right brings it back on top. With "loop" the deck never runs out:
//  the top card tucks behind to the back instead.
//
//    { "type": "cards",
//      "cards": [[{ "type": "previous" }, { "type": "play" }, { "type": "next" }],
//                { "title": "System", "when": { "app": "Xcode" }, "background": "#333333",
//                  "items": [{ "type": "cpu" }, { "type": "battery" }] }],
//      "direction": "across", "loop": false, "remember": true, "rotate": 30, "tick": true,
//      "dividers": false, "spacing": 8, "itemWidth": 40, "padding": 8,
//      "background": "#444444", "glass": true, "width": 200 }
//
//  A card is a list of items, or an object with its own title (for Settings),
//  "when" and look. With no "width" the slot is as wide as its widest card that's showing.
//

import Cocoa

class CardsBarItem: NSCustomTouchBarItem, TearDownable {
    private var cards: [[(item: NSTouchBarItem, definition: BarItemDefinition)]] = []
    /// For each card, where each item it shows sits in the card's list in the
    /// preset (swipes and decks inside a card are left out, so they can differ).
    private var places: [[Int]] = []
    private let conditions: [ItemCondition?]
    /// Passed in rather than read from `TouchBarController.shared`, which isn't
    /// available yet while the bar loads its first preset during its own init.
    private unowned let bar: TouchBarController
    private let cardsView: CardsView
    private let options: CardsOptions
    /// Which card each deck was last on, by what the deck holds, so a rebuilt bar
    /// (an app switch, a preset reload, a relaunch) comes back to it.
    private static var remembered: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "cards.remembered") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "cards.remembered") }
    }
    private let memoryKey: String
    private var rotation: Timer?

    init(identifier: NSTouchBarItem.Identifier, cards definitions: [CardDefinition], options: CardsOptions,
         definition: BarItemDefinition, bar: TouchBarController) {
        self.bar = bar
        self.options = options
        conditions = definitions.map { $0.when }
        var looks: [CardsView.Look] = []
        for card in definitions {
            var items: [(item: NSTouchBarItem, definition: BarItemDefinition)] = []
            var place: [Int] = []
            for (index, child) in card.items.enumerated() {
                let childIdentifier = NSTouchBarItem.Identifier(child.type.identifierBase + UUID().uuidString)
                // Not drawn (swipes), or a deck inside a deck: both would fight the swipe.
                guard let item = bar.createItem(forIdentifier: childIdentifier, definition: child),
                      !(item is SwipeItem), !(item is CardsBarItem), let view = item.view else {
                    continue
                }
                ClusterBarItem.placeOnSharedBackground(item, definition: child)
                CardsBarItem.placeOnCard(item, definition: child)
                if let itemWidth = options.itemWidth {
                    view.widthAnchor.constraint(greaterThanOrEqualToConstant: itemWidth).isActive = true
                }
                items.append((item, child))
                place.append(index)
            }
            cards.append(items)
            places.append(place)
            // The card's own look over the deck's.
            let parameters = definition.additionalParameters.merging(card.look) { _, own in own }
            let (fill, glass, tint, radius) = ClusterBarItem.sharedBackground(parameters: parameters)
            looks.append(CardsView.Look(fill: fill, glass: glass, glassTint: tint, cornerRadius: radius))
        }
        memoryKey = ([definition.additionalParameters[.align].map { "\($0)" } ?? ""]
            + definitions.map { $0.items.map { $0.typeName }.joined(separator: ",") }).joined(separator: "|")
        cardsView = CardsView(cards: Array(zip(cards.map { $0.compactMap { $0.item.view } }, looks)), options: options)
        super.init(identifier: identifier)
        view = cardsView
        updateVisibility()
        if options.remember, let card = CardsBarItem.remembered[memoryKey] { cardsView.start(at: card) }
        cardsView.landed = { [weak self] card in
            guard let self = self, self.options.remember, CardsBarItem.remembered[self.memoryKey] != card else { return }
            CardsBarItem.remembered[self.memoryKey] = card
        }
        if let seconds = options.rotate, seconds > 0 {
            rotation = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
                self?.cardsView.rotate(pausedFor: seconds)
            }
        }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The card is the surface, so items that bring a panel of their own (a
    /// slider's gray row, a group's key, a strip's black scroll view) drop it,
    /// unless the preset gave them a look of their own.
    static func placeOnCard(_ item: NSTouchBarItem, definition: BarItemDefinition) {
        guard let view = item.view else { return }
        let ownLook = definition.additionalParameters[.background] != nil || definition.additionalParameters[.bordered] != nil
            || definition.additionalParameters[.glass] != nil
        if item is SlidableItem, !ownLook {
            view.layer?.backgroundColor = nil
        }
        if let group = view as? ClusterView, !ownLook {
            group.glass = false
            group.layer?.backgroundColor = nil
        }
        clearScrollBackgrounds(in: view)
        // Sliders and scrolling strips have no width of their own: on the bar they
        // stretch, but on a card they'd shrink to nothing.
        if definition.additionalParameters[.width] == nil {
            let deck = Theme.current.deck
            let strip = item is AppScrubberTouchBarItem || item is UpNextScrubberTouchBarItem || item is ScrollViewItem
            if let least = item is SlidableItem ? deck.sliderWidth : strip ? deck.stripWidth : nil {
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: least).isActive = true
            }
        }
    }

    private static func clearScrollBackgrounds(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
        }
        if let scrubber = view as? NSScrubber {
            scrubber.backgroundColor = .clear
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    /// Hides items whose "when" condition fails and skips cards left with none;
    /// the slot hides when no card has anything to show.
    func updateVisibility() {
        var shown: [Bool] = []
        for card in cards {
            for child in card {
                let hidden = !bar.isVisible(child.definition)
                if child.item.view?.isHidden != hidden { child.item.view?.isHidden = hidden }
            }
            bar.updateActiveStates(card.map { $0.item })
            // A card with a "when" of its own shows only while it holds.
            let allowed = conditions[shown.count]?.isSatisfied(frontmost: NSWorkspace.shared.frontmostApplication) ?? true
            shown.append(allowed && card.contains { !($0.item.view?.isHidden ?? true) })
        }
        cardsView.setShown(shown)
        let empty = !shown.contains(true)
        if view.isHidden != empty { view.isHidden = empty }
    }

    /// Goes to the next (1) or previous (-1) card, as a swipe would.
    func advance(_ step: Int) { cardsView.advance(step) }
    /// Turns the deck to card `index` (in preset order), e.g. the one being edited in Settings.
    func show(card index: Int) { cardsView.show(card: index) }

    /// Holds a drag at `offset` points (negative pulls toward the next card), for
    /// checking the in-between look with `screencapture -b`; `release` lets go.
    func drag(to offset: CGFloat) { cardsView.drag(to: offset) }
    func release() { cardsView.release() }
    /// Plays a swipe through the deck's touch handling; see CardsView.simulateSwipe.
    func swipe(by delta: CGVector, duration: TimeInterval, from x: CGFloat?) {
        cardsView.simulateSwipe(by: delta, duration: duration, from: x)
    }
    /// Logs where each card is, for debugging.
    func logState() { cardsView.logState() }
    /// The item on the card that's up at a point across the deck (0 at its left
    /// edge, 1 at its right): which card and which item in it, in preset order.
    func item(atFraction fraction: CGFloat) -> (card: Int, item: Int, view: NSView)? {
        let card = cardsView.current
        guard let index = cardsView.itemIndex(atX: fraction * cardsView.bounds.width),
              cards.indices.contains(card), cards[card].indices.contains(index), let view = cards[card][index].item.view else { return nil }
        return (card, places[card][index], view)
    }

    /// The items on its cards, for debug commands that find an item by name.
    var cardItems: [NSTouchBarItem] { cards.flatMap { $0.map { $0.item } } }

    func tearDown() {
        rotation?.invalidate()
        rotation = nil
        tearDownItems(cards.flatMap { $0.map { $0.item } })
        cards = []
    }
}

/// One card: its own background, its row of items, and a shade that darkens it
/// the deeper it sits in the deck.
final class CardPlate: NSView {
    let stack: NSStackView
    private let shade = Shade()
    private let glass: Bool
    private let glassTint: NSColor?
    private let cornerRadius: CGFloat

    private let outline: NSColor

    /// Thin lines between the items, as in a group.
    private let dividers: Bool

    init(views: [NSView], look: CardsView.Look, spacing: CGFloat, dividers: Bool, outline: NSColor) {
        let fill = look.fill, glass = look.glass, glassTint = look.glassTint, cornerRadius = look.cornerRadius
        self.dividers = dividers
        self.outline = outline
        self.glass = glass
        self.glassTint = glassTint
        self.cornerRadius = cornerRadius
        stack = NSStackView(views: views)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill?.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        addSubview(stack)
        // Centered when it fits; when the slot is narrower (a set "width"),
        // it starts at the left edge and the right is cut off.
        let center = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        center.priority = .defaultHigh
        let fullHeight = stack.heightAnchor.constraint(equalTo: heightAnchor)
        fullHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            center,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            // Full height; on a shorter card (a deck that moves up or down) the
            // items keep their own height, centered, and the card trims them.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            fullHeight,
        ])

        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.cgColor
        shade.layer?.opacity = 0
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var shadeLayer: CALayer? { shade.layer }
    /// The card's items: hidden on the cards behind the top one, which only show
    /// their edges (on glass they'd show through).
    var contentLayer: CALayer? { stack.layer }

    /// A card behind the top one on a solid (not glass) deck: without glass's
    /// bright rim, only a hairline shows where its edge is.
    func setBehind(_ behind: Bool) {
        guard !glass, let layer = layer else { return }
        let width: CGFloat = behind ? 1 : 0
        guard layer.borderWidth != width else { return }
        layer.borderWidth = width
        layer.borderColor = outline.cgColor
    }

    override func layout() {
        super.layout()
        shade.frame = bounds
        if glass || dividers { needsDisplay = true }
        // A row that grew (a readout's text, the player opening its controls) may
        // need a wider slot: measured now, within the same layout (and animation).
        (superview as? CardsView)?.rowLaidOut()
    }

    // Resized and moved at once, never by an implicit animation: see CardsView.followsLayout.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? {
        CardsView.followsLayout(key) ? nil : super.animation(forKey: key)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if glass {
            GlassPainter.draw(in: self, rect: bounds, radius: cornerRadius, pressed: false, style: CustomButtonTouchBarItem.glassStyle,
                              tint: glassTint)
        }
        guard dividers else { return }
        // As a group draws them: halfway between neighbors, short of the top and bottom.
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        NSColor.white.withAlphaComponent(0.25).setFill()
        for (left, right) in zip(visible, visible.dropFirst()) {
            let x = (convert(left.frame, from: stack).maxX + convert(right.frame, from: stack).minX) / 2
            NSRect(x: x.rounded() - 0.5, y: 8, width: 1, height: bounds.height - 16).fill()
        }
    }

    /// Darkens the card; sits over the items but never takes their touches.
    private final class Shade: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }
}

/// The deck: where each card sits, and the moves between them.
///
/// Every card is a `CardPlate`, laid out at full size and placed by a layer
/// transform: the top card at rest, the ones still to come scaled down and
/// nudged right so their edges show, and (when not looping) the last one dealt
/// to the left of it, its edge showing there, the rest hidden under it. Moves animate those transforms with Core Animation
/// (the Touch Bar shows layer animations, not `animator()` frame changes).
final class CardsView: NSView {
    /// A card's background and shape.
    struct Look {
        var fill: NSColor?
        var glass: Bool
        var glassTint: NSColor?
        var cornerRadius: CGFloat
    }

    private let plates: [CardPlate]
    private var shown: [Bool]
    private let loop: Bool
    private let options: CardsOptions
    /// The deck moves up or down rather than across.
    private let vertical: Bool
    /// The way the cards behind sit from the top card (a dealt card goes the other
    /// way), in the deck's coordinates: right, down or up.
    private let axis: CGPoint
    private var edgeStep: CGFloat { vertical ? style.verticalEdgeStep : style.edgeStep }
    /// How many cards behind show an edge.
    private var levels: Int { vertical ? 1 : 2 }
    /// Told the card the deck lands on after each move.
    var landed: ((Int) -> Void)?
    /// When a finger last touched the deck, so rotating waits.
    private var lastTouch = Date.distantPast
    private(set) var current = 0
    /// How far a finger has dragged; 0 at rest.
    private var offset: CGFloat = 0
    /// Bumped on every move, so a move's completion that's been overtaken (by a
    /// new touch) leaves the state alone.
    private var generation = 0
    private var animating = false
    /// The card a move in flight is heading for.
    private var heading = 0
    /// The widest showing card, as of the last measure.
    private var measuredWidth: CGFloat = 0
    /// Blurs whatever passes under the slot's left edge while cards move. Only on
    /// glass, where cards are frosted already; solid cards keep a clean edge.
    private let softEdge = NSView()
    private let blursEdge: Bool
    private let edgeMask = CAGradientLayer()

    /// Sizes, depths and timings, from the theme the deck was built with (and the deck's own padding).
    private let style: Theme.Deck

    init(cards: [(views: [NSView], look: Look)], options: CardsOptions) {
        loop = options.loop
        self.options = options
        vertical = options.direction != .across
        axis = options.direction == .across ? CGPoint(x: 1, y: 0) : options.direction == .up ? CGPoint(x: 0, y: -1) : CGPoint(x: 0, y: 1)
        var style = Theme.current.deck
        if let padding = options.padding { style.padding = padding }
        self.style = style
        blursEdge = cards.contains { $0.look.glass }
        shown = cards.map { _ in true }
        plates = cards.map {
            CardPlate(views: $0.views, look: $0.look, spacing: options.spacing ?? style.padding, dividers: options.dividers,
                      outline: style.outline)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        plates.forEach(addSubview)

        softEdge.wantsLayer = true
        softEdge.layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(style.softEdgeBlur, forKey: kCIInputRadiusKey)
            softEdge.backgroundFilters = [blur]
        }
        // Both run from the left side, where cards are swiped off, inward.
        let (from, to) = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        let ramp = CAGradientLayer()
        ramp.startPoint = from
        ramp.endPoint = to
        ramp.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        ramp.locations = [0, 0.35, 1]
        softEdge.layer?.mask = ramp
        softEdge.layer?.opacity = 0
        softEdge.layer?.zPosition = 100
        addSubview(softEdge)

        edgeMask.startPoint = from
        edgeMask.endPoint = to
        edgeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        layer?.mask = edgeMask

        measuredWidth = widestShowingCard()

        // In debug runs, every raw touch is logged too, to see what the Touch Bar reports.
        if DebugHooks.isEnabled { allowedTouchTypes = [.direct] }
        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = .direct
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Size

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth + 2 * style.padding + (vertical ? 0 : leadInset + trailInset), height: ItemStyle.barHeight)
    }

    /// Room beside the top card, only where something can show: on the dealt side
    /// (left, or above / below) the edge of the last card dealt (a deck that doesn't
    /// loop), on the other side the edges of the cards still to come. A deck of
    /// one card has none.
    private var leadInset: CGFloat { !vertical && !loop && visibleCards.count > 1 ? edgeStep + 1 : 0 }
    private var trailInset: CGFloat {
        visibleCards.count > 1 ? edgeStep * CGFloat(min(visibleCards.count - 1, levels)) + (vertical ? 0 : 1) : 0
    }

    /// The widest showing card's row. Its laid-out width once it has one (safe to
    /// read during layout); before the first layout, its fitting size.
    private func widestShowingCard() -> CGFloat {
        plates.indices.filter { shown[$0] }.map { index -> CGFloat in
            let stack = plates[index].stack
            return stack.frame.width > 0 ? stack.frame.width : stack.fittingSize.width
        }.max() ?? 0
    }

    /// Which of the top card's items is at `x` (in the deck's coordinates), by its place in the card's row.
    func itemIndex(atX x: CGFloat) -> Int? {
        guard plates.indices.contains(current) else { return nil }
        let plate = plates[current]
        for (index, view) in plate.stack.arrangedSubviews.enumerated() where !view.isHidden {
            let frame = convert(view.frame, from: plate.stack)
            if x >= frame.minX, x <= frame.maxX { return index }
        }
        return nil
    }

    /// A card's row was laid out: resize the slot now if the widest row changed,
    /// so it grows with an animated row instead of jumping after it.
    func rowLaidOut() {
        remeasure()
    }

    /// Resizes the slot when the widest showing card changed (an item hidden or
    /// shown, or a readout's text grew).
    private func remeasure() {
        let width = widestShowingCard()
        guard width != measuredWidth else { return }
        measuredWidth = width
        invalidateIntrinsicContentSize()
    }

    /// The top card's size along the way the deck moves.
    private var cardLength: CGFloat { max((vertical ? bounds.height : bounds.width) - leadInset - trailInset, 1) }

    // MARK: Which cards

    /// Cards that have something to show, in order.
    private var visibleCards: [Int] { shown.indices.filter { shown[$0] } }

    func setShown(_ values: [Bool]) {
        guard values.count == shown.count, values != shown else { return }
        shown = values
        if !shown[current] {
            finishMove()
            current = visibleCards.first ?? 0
        }
        for (index, plate) in plates.enumerated() where plate.isHidden == shown[index] {
            plate.isHidden = !shown[index]
        }
        remeasure()
        // How many cards show decides the room beside the top card.
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Where a card sits relative to the top one: 0 is the top, 1 and 2 the edges
    /// behind it (deeper ones hide under the last), negative is already dealt.
    private func depth(of index: Int, from top: Int) -> Int? {
        let cards = visibleCards
        guard let position = cards.firstIndex(of: index), let topPosition = cards.firstIndex(of: top) else { return nil }
        let depth = position - topPosition
        return loop && depth < 0 ? depth + cards.count : depth
    }

    /// The card next to `current` in the given direction, or nil at an end.
    private func neighbor(_ step: Int) -> Int? {
        let cards = visibleCards
        guard cards.count > 1, let position = cards.firstIndex(of: current) else { return nil }
        let next = position + step
        if loop { return cards[(next + cards.count) % cards.count] }
        return cards.indices.contains(next) ? cards[next] : nil
    }

    // MARK: Poses

    /// How a card is placed: moved across, scaled about its center, shaded.
    private struct Pose {
        /// Along the deck (across, or up or down): where the cards behind sit.
        var x: CGFloat = 0
        /// Sideways, on a deck drawn up or down: where the finger takes the top card.
        var side: CGFloat = 0
        var scale: CGFloat = 1
        var shade: Float = 0
        /// How visible the card's items are: only the top card's show.
        var content: Float = 1
        var z: CGFloat = 10

        func mixed(with other: Pose, _ amount: CGFloat) -> Pose {
            Pose(x: x + (other.x - x) * amount, side: side + (other.side - side) * amount, scale: scale + (other.scale - scale) * amount,
                 shade: shade + (other.shade - shade) * Float(amount),
                 content: content + (other.content - content) * Float(amount), z: z)
        }
    }

    /// Just past the deck's left side, where a looping deck's bottom card comes in from.
    /// Just past the deck's left side, where a card comes back from (along the
    /// deck when it's drawn across, sideways when it's drawn up or down).
    private var offLeft: CGFloat { vertical ? -(bounds.width + 6) : -(cardLength + leadInset + 6) }

    /// A pose moved sideways by the finger: along the deck, or sideways on one drawn up or down.
    private func shifted(_ pose: Pose, by amount: CGFloat) -> Pose {
        var pose = pose
        if vertical { pose.side += amount } else { pose.x += amount }
        return pose
    }

    private func rest(_ depth: Int) -> Pose {
        if depth < 0, vertical {
            // Swiped off sideways: just past the left side, ready to come back the same way.
            return Pose(side: -(bounds.width + 6), z: depth == -1 ? 11 : 1)
        }
        if depth < 0 {
            // Dealt: beside the top card on the left, scaled like the first card
            // behind, with only its edge in the room left of the top card. The
            // last one dealt lies on the others.
            let scale = style.scales[1]
            return Pose(x: -cardLength * (1 + scale) / 2, scale: scale, shade: style.shades[1], content: 0,
                        z: depth == -1 ? 11 : 1)
        }
        let level = min(depth, levels)
        let scale = style.scales[level]
        let x = level == 0 ? 0 : edgeStep * CGFloat(level) + (1 - scale) * cardLength / 2
        return Pose(x: x, scale: scale, shade: style.shades[level], content: level == 0 ? 1 : 0,
                    z: depth > levels ? 2 : 10 - 2 * CGFloat(level))
    }

    /// The layer transform for a pose: the plate's layer is anchored where AppKit
    /// put it, so scale about the plate's center by moving there first.
    private func transform(_ pose: Pose, for plate: CardPlate) -> CATransform3D {
        // The view's bounds, not the layer's: right after layout the layer may not have caught up.
        let anchor = plate.layer?.anchorPoint ?? .zero
        let center = CGPoint(x: (0.5 - anchor.x) * plate.bounds.width, y: (0.5 - anchor.y) * plate.bounds.height)
        // A pose's x runs along the deck: across, or up or down.
        var t = CATransform3DMakeTranslation(axis.x * pose.x + pose.side + center.x, axis.y * pose.x + center.y, 0)
        t = CATransform3DScale(t, pose.scale, pose.scale, 1)
        return CATransform3DTranslate(t, -center.x, -center.y, 0)
    }

    /// Each showing card's pose for the current card and a drag offset.
    private func poses(dragging drag: CGFloat) -> [Int: Pose] {
        var result: [Int: Pose] = [:]
        for index in visibleCards {
            if let depth = depth(of: index, from: current) { result[index] = rest(depth) }
        }
        guard drag != 0 else { return result }
        let step = drag < 0 ? 1 : -1
        guard neighbor(step) != nil else {
            // Nothing that way: the top card gives a little and springs back.
            if let top = result[current] { result[current] = shifted(top, by: drag * 0.3) }
            return result
        }
        let progress = min(1, abs(drag) / (swipeLength * 0.6)) * 0.6
        let count = visibleCards.count
        for index in visibleCards {
            guard let depth = depth(of: index, from: current) else { continue }
            if step == 1 {
                // The top card follows the finger; the ones behind start to come forward.
                if depth == 0, let top = result[index] { result[index] = shifted(top, by: drag) }
                else if depth > 0 { result[index] = rest(depth).mixed(with: rest(depth - 1), progress) }
            } else if loop && depth == count - 1 {
                // A looping deck's bottom card comes in from the left over the top,
                // following the finger, as a dealt card would.
                result[index] = shifted(Pose(z: 12), by: offLeft + drag)
            } else if !loop && depth == -1 {
                // The last card dealt comes back over the top, following the finger.
                var back = rest(-1).mixed(with: rest(0), min(1, drag / swipeLength))
                if vertical { back.side = rest(-1).side + drag } else { back.x = rest(-1).x + drag }
                back.z = 12
                result[index] = back
            } else if depth >= 0 && !(loop && depth == count - 1) {
                result[index] = rest(depth).mixed(with: rest(depth + 1), progress)
            }
        }
        return result
    }

    private func apply(_ poses: [Int: Pose]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, pose) in poses {
            let plate = plates[index]
            plate.layer?.transform = transform(pose, for: plate)
            plate.layer?.zPosition = pose.z
            plate.shadeLayer?.opacity = pose.shade
            plate.contentLayer?.opacity = pose.content
            plate.setBehind(pose.shade > 0)
        }
        CATransaction.commit()
        if !animating && offset == 0 {
            stackByDepth(poses)
            clipToEdges(poses)
        } else {
            unclip()
        }
    }

    /// At rest, each card other than the top one shows only the part outside the
    /// top card: its edge. A see-through top card (glass, or no background) would
    /// otherwise show the cards behind it. Moving cards are drawn whole.
    private func clipToEdges(_ poses: [Int: Pose]) {
        guard let top = poses[current] else { return }
        let topPlate = plates[current]
        // Along the deck's way of moving: the coordinate, and whether the cards behind sit toward its larger end.
        let along: (NSRect) -> (min: CGFloat, max: CGFloat) = { [vertical] rect in
            vertical ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
        }
        let sign = vertical ? axis.y : axis.x
        let topSpan = along(topPlate.frame)
        let topMin = topSpan.min + sign * top.x, topMax = topSpan.max + sign * top.x
        let deck = along(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, pose) in poses {
            let plate = plates[index]
            guard index != current, pose.scale > 0 else { plate.layer?.mask = nil; continue }
            // The part of the deck this card may show: beyond the top card, on its own side.
            let towardLarger = (pose.x > top.x) == (sign > 0)
            let visible = towardLarger ? (topMax, deck.max) : (deck.min, topMin)
            // Back into the card's own coordinates, through its move and scale about its center.
            let span = along(plate.frame)
            let center = (span.max - span.min) / 2
            func local(_ v: CGFloat) -> CGFloat { (v - span.min - center - sign * pose.x) / pose.scale + center }
            let low = local(visible.0), high = local(visible.1)
            let mask = (plate.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
            let size = plate.bounds.size
            let rect = vertical ? CGRect(x: -size.width, y: low, width: size.width * 3, height: max(0, high - low))
                                : CGRect(x: low, y: -size.height, width: max(0, high - low), height: size.height * 3)
            mask.path = CGPath(rect: rect, transform: nil)
            mask.frame = plate.bounds
            plate.layer?.mask = mask
        }
        topPlate.layer?.mask = nil
        CATransaction.commit()
    }

    private func unclip() {
        for plate in plates where plate.layer?.mask != nil { plate.layer?.mask = nil }
    }

    /// Orders the cards' views back to front as well. The bar sorts by zPosition,
    /// but pictures of the bar (Settings' previews use `render(in:)`) go by view order.
    private func stackByDepth(_ poses: [Int: Pose]) {
        let order = plates.indices.sorted { (poses[$0]?.z ?? 0) < (poses[$1]?.z ?? 0) }
        let current = subviews.compactMap { view in plates.firstIndex { $0 === view } }
        guard current != order else { return }
        for index in order {
            addSubview(plates[index], positioned: .below, relativeTo: softEdge)
        }
    }

    // MARK: Layout

    // The bar sizes the slot without always asking for a layout, and the poses
    // depend on the size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // Going on screen resets the plates' layer transforms, so place them again
    // once the move into the bar's window has settled.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.animating else { return }
            self.apply(self.poses(dragging: self.offset))
        }
    }

    override func layout() {
        super.layout()
        for plate in plates {
            switch options.direction {
            case .across: plate.frame = NSRect(x: leadInset, y: 0, width: cardLength, height: bounds.height)
            case .up: plate.frame = NSRect(x: 0, y: trailInset, width: bounds.width, height: cardLength)
            case .down: plate.frame = NSRect(x: 0, y: leadInset, width: bounds.width, height: cardLength)
            }
        }
        // The soft edge lies along the left side, where cards are swiped off.
        softEdge.frame = NSRect(x: 0, y: 0, width: style.softEdgeWidth, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        softEdge.layer?.mask?.frame = softEdge.bounds
        edgeMask.frame = bounds
        CATransaction.commit()
        updateFade()
        // A move in flight owns the poses until it ends.
        if !animating { apply(poses(dragging: offset)) }
        remeasureSoon()
    }

    private var remeasureQueued = false
    private var fading = false

    private func updateFade() {
        let width = fading ? style.fadeWidth : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let extent = bounds.width
        edgeMask.locations = [0, NSNumber(value: Double(min(1, width / max(extent, 1)))), 1]
        CATransaction.commit()
    }

    /// Measuring the rows lays them out, which mustn't happen while the deck is
    /// itself being laid out, so it waits until just after.
    private func remeasureSoon() {
        guard !remeasureQueued else { return }
        remeasureQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.remeasureQueued = false
            self?.remeasure()
        }
    }

    /// The deck and its cards take their size and place at once. An item that
    /// animates its width (the player opening its controls) re-lays out the bar
    /// every frame, inside its animation; an implicit animation on each of those
    /// steps would keep the deck drawn several steps behind its real size. The
    /// deck's own moves animate the cards' transforms explicitly, so they're unaffected.
    static func followsLayout(_ event: String) -> Bool {
        ["bounds", "position", "frame", "frameSize", "frameOrigin", "anchorPoint"].contains(event)
    }

    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? {
        CardsView.followsLayout(key) ? nil : super.animation(forKey: key)
    }

    // The top card's items take touches; the cards behind it don't.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Also mid-move: the card being moved to is the one a tap is for.
        if offset == 0, shown.indices.contains(current), plates[current].frame.contains(local),
           let hit = plates[current].hitTest(local) {
            return hit
        }
        return self
    }

    func logState() {
        DebugHooks.log("Stripe cards: current \(current), shown \(shown), window \(window != nil), bounds \(bounds)")
        for (index, plate) in plates.enumerated() {
            let t = plate.layer?.transform ?? CATransform3DIdentity
            DebugHooks.log("Stripe cards:  plate \(index) hidden \(plate.isHidden) frame \(plate.frame) layer \(plate.layer.map { ObjectIdentifier($0).hashValue } ?? 0) scale \(t.m11) x \(t.m41) z \(plate.layer?.zPosition ?? -1) subview \(subviews.firstIndex(of: plate) ?? -1)")
        }
    }

    // MARK: Moving

    /// Whether the touch has moved far enough sideways to be a swipe. The Touch
    /// Bar only senses where a finger is along its length (every touch reports the
    /// same height), so a deck is always swiped sideways, whichever way it's drawn.
    private var swiping = false

    @objc private func panned(_ recognizer: NSPanGestureRecognizer) {
        guard visibleCards.count > 1 else { return }
        let moved = recognizer.translation(in: self), velocity = recognizer.velocity(in: self)
        if DebugHooks.isEnabled {
            DebugHooks.log(String(format: "Stripe cards: touch %ld moved %.1f speed %.0f", recognizer.state.rawValue, moved.x, velocity.x))
        }
        switch recognizer.state {
        case .began:
            touchBegan()
            touchMoved(moved)
        case .changed:
            touchMoved(moved)
        case .ended, .cancelled:
            // A finger that slides off the bar's edge is cancelled: it still counts.
            touchMoved(moved)
            touchEnded(velocity: velocity, moved: moved)
        case .failed:
            move(step: 0)
        default: break
        }
    }

    // A finger on the deck, from a real touch or a simulated swipe (`simulateSwipe`).

    private func touchBegan() {
        lastTouch = Date()
        // A new touch takes over from a move still in flight.
        finishMove()
        swiping = false
    }

    /// `moved` is how far the finger has gone since it touched down.
    private func touchMoved(_ moved: CGPoint) {
        if !swiping, abs(moved.x) >= 4 { swiping = true }
        if swiping { drag(to: moved.x) }
    }

    private func touchEnded(velocity: CGPoint, moved: CGPoint = .zero) {
        // A quick swipe can end within a few points; its speed decides.
        if !swiping, abs(moved.x) >= 2, abs(velocity.x) >= 60 {
            swiping = true
            drag(to: moved.x)
        }
        if swiping { release(velocity: velocity.x) } else { move(step: 0) }
    }

    /// A touch that starts on something that tracks sideways itself (a slider,
    /// a scrolling strip) belongs to it, not to the deck. `point` is in the deck's coordinates.
    func deckTakesTouch(at point: CGPoint) -> Bool {
        var view = hitTest(convert(point, to: superview))
        while let current = view, current !== self {
            if current is NSSlider || current is NSScrollView || current is NSScrubber { return false }
            view = current.superview
        }
        return true
    }

    private var simulation: Timer?

    /// Plays a finger moving `delta` points (up is positive) over `duration`
    /// seconds, from `x` points into the deck (its middle by default), through
    /// the same steps as a real touch, then lifting with the speed it had.
    /// For trying gestures from the command line; see DebugHooks.
    func simulateSwipe(by delta: CGVector, duration: TimeInterval, from x: CGFloat?) {
        simulation?.invalidate()
        guard visibleCards.count > 1 else { DebugHooks.log("Stripe cards: swipe ignored, the deck has one card"); return }
        let start = CGPoint(x: x ?? bounds.midX, y: bounds.midY)
        guard deckTakesTouch(at: start) else {
            DebugHooks.log("Stripe cards: swipe from x \(start.x) went to the item there (a slider or strip), not the deck")
            return
        }
        let duration = max(duration, 1.0 / 60)
        let frames = max(1, Int((duration * 60).rounded()))
        var frame = 0
        touchBegan()
        simulation = Timer.scheduledTimer(withTimeInterval: duration / Double(frames), repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            frame += 1
            let done = CGFloat(frame) / CGFloat(frames)
            self.touchMoved(CGPoint(x: delta.dx * done, y: delta.dy * done))
            guard frame >= frames else { return }
            timer.invalidate()
            self.touchEnded(velocity: CGPoint(x: delta.dx / CGFloat(duration), y: delta.dy / CGFloat(duration)))
        }
        RunLoop.main.add(simulation!, forMode: .common)
    }

    /// How far a swipe can go: the top card's width (on a deck drawn up or down
    /// the card is as wide as the deck).
    private var swipeLength: CGFloat { vertical ? max(bounds.width, 1) : cardLength }

    func drag(to value: CGFloat) {
        guard visibleCards.count > 1 else { return }
        finishMove()
        offset = max(-swipeLength, min(swipeLength, value))
        showSoftEdge(offset != 0)
        apply(poses(dragging: offset))
    }

    func release(velocity: CGFloat = 0) {
        // Where the card would come to rest if it kept going a moment: a quick
        // flick counts as much as a long drag, and the two can't disagree.
        let projected = offset + velocity * 0.15
        // A third of the card, but never so little on a narrow deck that a slip changes cards.
        let threshold = max(swipeLength / 3, style.minimumSwipe)
        move(step: projected < -threshold ? 1 : projected > threshold ? -1 : 0, quick: abs(velocity) > 600)
    }

    func advance(_ step: Int) {
        guard visibleCards.count > 1 else { return }
        finishMove()
        move(step: step)
    }

    /// Turns to a card several away the same way: the cards in between go at
    /// once, the last one moves as usual, without a haptic (no finger is on the bar).
    func show(card index: Int) {
        let cards = visibleCards
        guard let target = cards.firstIndex(of: index), let from = cards.firstIndex(of: current), target != from else { return }
        let step = target > from ? 1 : -1
        for _ in 0 ..< abs(target - from) {
            finishMove()
            move(step: step, quiet: true)
        }
    }

    /// Goes to the next card (1), the previous (-1), or back to rest (0), animating
    /// every card from wherever it is now.
    ///
    /// Each layer's model value jumps to where it ends up, and an animation
    /// carries it from where it was.
    private func move(step: Int, quick: Bool = false, quiet: Bool = false) {
        let old = current
        let incoming = step == 0 ? nil : neighbor(step)
        let from = poses(dragging: offset)
        offset = 0
        if let incoming = incoming { current = incoming }
        let to = poses(dragging: 0)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, incoming != nil {
            apply(to)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 1
            fade.duration = 0.15
            plates[current].layer?.add(fade, forKey: "fade")
            showSoftEdge(false)
            if !quiet, options.tick { HapticFeedback.instance.tap(type: .weak) }
            landed?(current)
            return
        }

        generation += 1
        let move = generation
        animating = true
        unclip()
        heading = current
        if incoming != nil { showSoftEdge(true) }
        let duration = incoming == nil ? 0.32 : quick ? 0.32 : style.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, self.generation == move else { return }
            self.endMove()
            if incoming != nil, !quiet, self.options.tick { HapticFeedback.instance.tap(type: .weak) }
        }
        for (index, end) in to {
            guard var start = from[index], let layer = plates[index].layer else { continue }
            let plate = plates[index]
            layer.transform = transform(end, for: plate)
            layer.zPosition = end.z
            plate.shadeLayer?.opacity = end.shade
            plate.contentLayer?.opacity = end.content

            if loop, incoming != nil, step == 1, index == old {
                // To the back of the deck: out to the left a little, under the
                // rising card exactly halfway, then behind the rest.
                let reach = -max(0.3 * swipeLength, abs(vertical ? start.side : start.x))
                let out = shifted(Pose(scale: 0.95, shade: 0.15, content: start.content, z: start.z), by: reach)
                add(keyframes: [start, out, end].map { NSValue(caTransform3D: transform($0, for: plate)) }, keyTimes: [0, 0.45, 1],
                    keyPath: "transform", to: layer, duration: duration * 1.1)
                add(keyframes: [10, 10, 1, 1], keyTimes: [0, 0.49, 0.5, 1], keyPath: "zPosition", to: layer, duration: duration * 1.1)
                add(keyframes: [start.shade, out.shade, end.shade], keyTimes: [0, 0.45, 1], keyPath: "opacity",
                    to: plate.shadeLayer, duration: duration * 1.1)
                add(keyframes: [start.content, start.content, end.content], keyTimes: [0, 0.5, 1], keyPath: "opacity",
                    to: plate.contentLayer, duration: duration * 1.1)
                continue
            }
            if step == -1, index == current {
                // Coming back over the top: from the left (a looping deck's bottom card
                // starts just past the edge), above the cards dealt before it.
                if loop, start.x > 0 { start = shifted(Pose(z: 12), by: offLeft) } // still at the back: not dragged in

                layer.zPosition = 12
            }

            let rising = index == current && incoming != nil
            let settle = rising || incoming == nil
            animate(layer, keyPath: "transform", from: NSValue(caTransform3D: transform(start, for: plate)),
                    to: NSValue(caTransform3D: transform(end, for: plate)),
                    duration: duration, spring: settle)
            animate(plate.shadeLayer, keyPath: "opacity", from: start.shade, to: end.shade, duration: duration, spring: false)
            animate(plate.contentLayer, keyPath: "opacity", from: start.content, to: end.content, duration: duration, spring: false)
        }
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer?, keyPath: String, from: Any, to: Any, duration: CFTimeInterval, spring: Bool) {
        let animation: CABasicAnimation
        if spring {
            // A light settle, the way a card lands on a table.
            let springy = CASpringAnimation(keyPath: keyPath)
            springy.mass = 1
            springy.stiffness = 260
            springy.damping = 24
            springy.duration = max(duration, springy.settlingDuration)
            animation = springy
        } else {
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        }
        animation.fromValue = from
        animation.toValue = to
        layer?.add(animation, forKey: "move." + keyPath)
    }

    private func add(keyframes values: [Any], keyTimes: [NSNumber], keyPath: String, to layer: CALayer?, duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.35, 1)
        layer?.add(animation, forKey: "move." + keyPath)
    }

    /// Ends a move still in flight at once, landing on the card it was heading
    /// for, so a new touch or a change in which cards show starts from rest.
    private func finishMove() {
        guard animating else { return }
        generation += 1
        current = heading
        for plate in plates {
            plate.layer?.removeAnimation(forKey: "move.transform")
            plate.layer?.removeAnimation(forKey: "move.zPosition")
            plate.shadeLayer?.removeAnimation(forKey: "move.opacity")
            plate.contentLayer?.removeAnimation(forKey: "move.opacity")
        }
        endMove()
    }

    private func endMove() {
        animating = false
        offset = 0
        apply(poses(dragging: 0))
        showSoftEdge(false)
        landed?(current)
    }

    /// Starts on card `index` (in preset order), if it shows: the card a rebuilt bar comes back to.
    func start(at index: Int) {
        guard shown.indices.contains(index), shown[index], index != current, !animating else { return }
        current = index
        needsLayout = true
    }

    /// One step of "rotate": the next card, or back to the first after the last
    /// (a looping deck just carries on). Waits while a finger has been on the deck lately.
    func rotate(pausedFor seconds: TimeInterval) {
        guard visibleCards.count > 1, !animating, offset == 0, Date().timeIntervalSince(lastTouch) >= seconds else { return }
        if neighbor(1) != nil {
            move(step: 1, quiet: true)
        } else if let first = visibleCards.first {
            show(card: first)
        }
    }

    /// The soft edge (the blur, and the fade over the last points) is only on while
    /// cards move, so nothing at rest is blurred or faded, the dealt card's edge included.
    private func showSoftEdge(_ on: Bool) {
        guard blursEdge, let layer = softEdge.layer else { return }
        let target: Float = on || animating ? 1 : 0
        fading = target == 1
        updateFade()
        guard layer.opacity != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = target
        fade.duration = 0.15
        layer.opacity = target
        layer.add(fade, forKey: "fade")
    }
}

extension CardsView {
    override func touchesBegan(with event: NSEvent) { logTouches(event, "began") ; super.touchesBegan(with: event) }
    override func touchesMoved(with event: NSEvent) { logTouches(event, "moved") ; super.touchesMoved(with: event) }
    override func touchesEnded(with event: NSEvent) { logTouches(event, "ended") ; super.touchesEnded(with: event) }
    override func touchesCancelled(with event: NSEvent) { logTouches(event, "cancelled") ; super.touchesCancelled(with: event) }

    /// The raw position of each finger on the deck (debug runs only).
    private func logTouches(_ event: NSEvent, _ phase: String) {
        guard DebugHooks.isEnabled else { return }
        for touch in event.touches(matching: .any, in: self) {
            let point = touch.location(in: self)
            DebugHooks.log(String(format: "Stripe cards: raw %@ x %.1f y %.1f", phase, point.x, point.y))
        }
    }
}

extension CardsView: NSGestureRecognizerDelegate {
    func gestureRecognizer(_: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        deckTakesTouch(at: touch.location(in: self))
    }
}
