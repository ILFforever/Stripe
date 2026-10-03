//
//  CardsBarItem.swift
//  Stripe
//
//  A slot that holds several cards, each a row of items, and swaps between them
//  with a swipe, like a widget stack: the whole card slides out and the next
//  slides in, on one background the cards share. Swiping past the last card
//  wraps to the first. Dots along the bottom show which card is up.
//
//    { "type": "cards",
//      "cards": [[{ "type": "previous" }, { "type": "play" }, { "type": "next" }],
//                [{ "type": "cpu" }, { "type": "battery" }]],
//      "dots": true, "width": 200,
//      "background": "#444444", "glass": true, "bordered": false }   // as on a group
//
//  With no "width" the slot is as wide as its widest card that's showing.
//

import Cocoa

class CardsBarItem: NSCustomTouchBarItem, TearDownable {
    private var cards: [[(item: NSTouchBarItem, definition: BarItemDefinition)]] = []
    /// Passed in rather than read from `TouchBarController.shared`, which isn't
    /// available yet while the bar loads its first preset during its own init.
    private unowned let bar: TouchBarController
    private let cardsView: CardsView

    init(identifier: NSTouchBarItem.Identifier, cards definitions: [[BarItemDefinition]], dots: Bool,
         definition: BarItemDefinition, bar: TouchBarController) {
        self.bar = bar
        let (fill, glass, tint, radius) = ClusterBarItem.sharedBackground(for: definition)
        for definitions in definitions {
            var card: [(item: NSTouchBarItem, definition: BarItemDefinition)] = []
            for child in definitions {
                let childIdentifier = NSTouchBarItem.Identifier(child.type.identifierBase + UUID().uuidString)
                guard let item = bar.createItem(forIdentifier: childIdentifier, definition: child),
                      !(item is SwipeItem), item.view != nil else { continue }
                ClusterBarItem.placeOnSharedBackground(item, definition: child)
                card.append((item, child))
            }
            cards.append(card)
        }
        cardsView = CardsView(cards: cards.map { $0.compactMap { $0.item.view } }, dots: dots, fill: fill, glass: glass,
                              glassTint: tint, cornerRadius: radius)
        super.init(identifier: identifier)
        view = cardsView
        updateVisibility()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            shown.append(card.contains { !($0.item.view?.isHidden ?? true) })
        }
        cardsView.setShown(shown)
        let empty = !shown.contains(true)
        if view.isHidden != empty { view.isHidden = empty }
    }

    /// Slides to the next (1) or previous (-1) card, as a swipe would.
    func advance(_ step: Int) { cardsView.advance(step) }

    func tearDown() {
        tearDownItems(cards.flatMap { $0.map { $0.item } })
        cards = []
    }
}

/// The cards' background, the card that's up, and the slide between cards.
///
/// At rest only the current card is on screen. While a finger drags, the card
/// on the side being uncovered sits next to it. Releasing (or `advance`) animates
/// exactly two cards: the current one out and the incoming one in, or the
/// uncovered one back out if the swipe falls short.
final class CardsView: NSView {
    private let holders: [NSView]
    private var shown: [Bool]
    private(set) var current = 0
    /// How far the finger has dragged the current card; 0 at rest.
    private var offset: CGFloat = 0
    /// Bumped on every slide, so a slide's completion that's been overtaken
    /// (by a new touch) leaves the state alone.
    private var generation = 0
    private var animating = false
    /// The card a slide in flight is heading for.
    private var heading = 0
    /// The widest showing card, as of the last measure.
    private var measuredWidth: CGFloat = 0

    private let glass: Bool
    private let glassTint: NSColor?
    private let cornerRadius: CGFloat
    private let dotsView: DotsView?

    /// Space between the background's edges and the widest card, when the slot sizes itself.
    private static let padding: CGFloat = 8
    private static let duration: TimeInterval = 0.22

    init(cards: [[NSView]], dots: Bool, fill: NSColor?, glass: Bool, glassTint: NSColor?, cornerRadius: CGFloat) {
        self.glass = glass
        self.glassTint = glassTint
        self.cornerRadius = cornerRadius
        dotsView = dots ? DotsView() : nil
        shown = cards.map { _ in true }
        holders = cards.map { views in
            let holder = NSView()
            holder.wantsLayer = true
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(stack)
            // Centered when it fits; when the slot is narrower (a set "width"),
            // it starts at the left edge and the right is cut off.
            let center = stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor)
            center.priority = .defaultHigh
            NSLayoutConstraint.activate([
                center,
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
                stack.topAnchor.constraint(equalTo: holder.topAnchor),
                stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
            return holder
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = fill?.cgColor
        layer?.cornerRadius = cornerRadius
        holders.forEach(addSubview)
        if let dotsView = dotsView {
            dotsView.autoresizingMask = [.width, .height]
            addSubview(dotsView)
        }
        measuredWidth = widestShowingCard()
        updateDots()

        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = .direct
        addGestureRecognizer(pan)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Size

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth + 2 * CardsView.padding, height: ItemStyle.barHeight)
    }

    private func widestShowingCard() -> CGFloat {
        holders.indices.filter { shown[$0] }.compactMap { holders[$0].subviews.first?.fittingSize.width }.max() ?? 0
    }

    /// Resizes the slot when the widest showing card changed (an item hidden or
    /// shown, or a readout's text grew).
    private func remeasure() {
        let width = widestShowingCard()
        guard width != measuredWidth else { return }
        measuredWidth = width
        invalidateIntrinsicContentSize()
    }

    // MARK: Which cards

    /// Cards that have something to show, in order.
    private var visibleCards: [Int] { shown.indices.filter { shown[$0] } }

    func setShown(_ values: [Bool]) {
        guard values.count == shown.count, values != shown else { return }
        shown = values
        if !shown[current] {
            finishSlide()
            current = visibleCards.first ?? 0
        }
        remeasure()
        needsLayout = true
        updateDots()
    }

    /// The card next to `current` in the given direction, wrapping around.
    private func neighbor(_ step: Int) -> Int {
        let cards = visibleCards
        guard let position = cards.firstIndex(of: current), cards.count > 1 else { return current }
        return cards[(position + step + cards.count) % cards.count]
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // A slide in flight owns the holders' frames until it ends.
        if !animating { place() }
        if glass { needsDisplay = true }
        remeasure()
    }

    /// Puts the current card at the drag offset and, while dragging, the card
    /// being uncovered beside it; hides the rest.
    private func place() {
        let width = bounds.width
        let uncovered = offset < 0 ? neighbor(1) : offset > 0 ? neighbor(-1) : nil
        for (index, holder) in holders.enumerated() {
            var x: CGFloat?
            if index == current {
                x = offset
            } else if index == uncovered {
                x = offset < 0 ? offset + width : offset - width
            }
            holder.isHidden = x == nil
            holder.frame = NSRect(x: x ?? 0, y: 0, width: width, height: bounds.height)
        }
    }

    // MARK: Sliding

    @objc private func panned(_ recognizer: NSPanGestureRecognizer) {
        guard visibleCards.count > 1 else { return }
        let width = max(bounds.width, 1)
        switch recognizer.state {
        case .began:
            // A new touch takes over from a slide still in flight.
            finishSlide()
            fallthrough
        case .changed:
            offset = max(-width, min(width, recognizer.translation(in: self).x))
            place()
        case .ended:
            // Where the card would come to rest if it kept going a moment: a quick
            // flick counts as much as a long drag, and the two can't disagree.
            let projected = offset + recognizer.velocity(in: self).x * 0.15
            slide(step: projected < -width / 3 ? 1 : projected > width / 3 ? -1 : 0)
        case .cancelled, .failed:
            slide(step: 0)
        default: break
        }
    }

    func advance(_ step: Int) {
        guard visibleCards.count > 1 else { return }
        finishSlide()
        slide(step: step)
    }

    /// Animates to the next card (step 1), the previous (-1), or back to rest (0).
    ///
    /// The holders' frames jump to where they end up, and a Core Animation
    /// animation carries each from where it was: the Touch Bar shows layer
    /// animations, but not an `animator()` frame change.
    private func slide(step: Int) {
        let width = bounds.width
        let incoming = step == 0 ? current : neighbor(step)
        var moves: [(holder: NSView, from: CGFloat, to: CGFloat)] = []
        for (index, holder) in holders.enumerated() {
            if index == incoming, step != 0 {
                // It comes in from beside the current card, on the side it enters from,
                // wherever the drag left things.
                moves.append((holder, offset + CGFloat(step) * width, 0))
            } else if index == current {
                moves.append((holder, offset, CGFloat(-step) * width))
            } else if !holder.isHidden {
                // Falling short: the uncovered card goes back the way it came.
                moves.append((holder, holder.frame.origin.x, holder.frame.origin.x < 0 ? -width : width))
            } else {
                continue
            }
        }
        generation += 1
        let slide = generation
        animating = true
        heading = incoming
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, self.generation == slide else { return }
            self.current = incoming
            self.endSlide()
        }
        for move in moves {
            move.holder.isHidden = false
            move.holder.frame = NSRect(x: move.to, y: 0, width: width, height: bounds.height)
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.isAdditive = true
            animation.fromValue = move.from - move.to
            animation.toValue = 0
            animation.duration = CardsView.duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            move.holder.layer?.add(animation, forKey: "slide")
        }
        CATransaction.commit()
        // The dot moves as the card starts to move.
        if let position = visibleCards.firstIndex(of: incoming) { dotsView?.active = position }
    }

    /// Ends a slide still in flight at once, landing on the card it was heading
    /// for, so a new touch or a change in which cards show starts from rest.
    private func finishSlide() {
        guard animating else { return }
        generation += 1
        current = heading
        for holder in holders { holder.layer?.removeAnimation(forKey: "slide") }
        endSlide()
    }

    private func endSlide() {
        animating = false
        offset = 0
        place()
        updateDots()
    }

    private func updateDots() {
        guard let dotsView = dotsView else { return }
        let cards = visibleCards
        dotsView.count = cards.count
        dotsView.active = cards.firstIndex(of: current) ?? 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if glass {
            GlassPainter.draw(in: self, rect: bounds, radius: cornerRadius, pressed: false, style: CustomButtonTouchBarItem.glassStyle,
                              tint: glassTint)
        }
    }
}

/// Small dots along the bottom edge, in the order of the swipe: swiping left to the
/// next card moves the bright dot right. Touches pass through to the keys beneath.
final class DotsView: NSView {
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    var active = 0 { didSet { if active != oldValue { needsDisplay = true } } }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        guard count > 1 else { return }
        let size: CGFloat = 4, gap: CGFloat = 5
        let total = CGFloat(count) * size + CGFloat(count - 1) * gap
        var x = (bounds.width - total) / 2
        for index in 0 ..< count {
            NSColor.white.withAlphaComponent(index == active ? 0.9 : 0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: size, height: size)).fill()
            x += size + gap
        }
    }
}
