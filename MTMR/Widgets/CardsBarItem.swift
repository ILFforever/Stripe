//
//  CardsBarItem.swift
//  Stripe
//
//  A slot that holds several cards, each a row of items, and swaps between them
//  with a swipe, like a widget stack: the whole card slides out and the next
//  slides in. Swiping past the last card wraps to the first.
//
//    { "type": "cards",
//      "cards": [[{ "type": "previous" }, { "type": "play" }, { "type": "next" }],
//                [{ "type": "cpu" }, { "type": "battery" }]],
//      "dots": true, "width": 200 }
//
//  With no "width" the slot is as wide as its widest card.
//

import Cocoa

class CardsBarItem: NSCustomTouchBarItem, TearDownable {
    private var cards: [[(item: NSTouchBarItem, definition: BarItemDefinition)]] = []
    private unowned let bar: TouchBarController
    private let cardsView: CardsView

    init(identifier: NSTouchBarItem.Identifier, cards definitions: [[BarItemDefinition]], dots: Bool,
         definition: BarItemDefinition, bar: TouchBarController) {
        self.bar = bar
        // The slot has one background that every card sits on, set up like a cluster's.
        var fill: NSColor? = CustomButtonTouchBarItem.standardKeyColor
        var glass = CustomButtonTouchBarItem.glass
        if case let .glass(own)? = definition.additionalParameters[.glass] { glass = own }
        if case let .background(color)? = definition.additionalParameters[.background] {
            fill = color
            glass = false
        } else if case .bordered(false)? = definition.additionalParameters[.bordered] {
            fill = nil
            glass = false
        }
        if glass { fill = nil }
        var tint = CustomButtonTouchBarItem.glassTint
        if case let .glassTint(own)? = definition.additionalParameters[.glassTint] { tint = own }
        var radius = ClusterBarItem.standardCornerRadius
        if case let .style(style)? = definition.additionalParameters[.style], let custom = style.cornerRadius { radius = custom }
        var built: [[(item: NSTouchBarItem, definition: BarItemDefinition)]] = []
        for definitions in definitions {
            var card: [(item: NSTouchBarItem, definition: BarItemDefinition)] = []
            for child in definitions {
                let childIdentifier = NSTouchBarItem.Identifier(child.type.identifierBase + UUID().uuidString)
                guard let item = bar.createItem(forIdentifier: childIdentifier, definition: child),
                      !(item is SwipeItem), item.view != nil else { continue }
                // Items sit on the slot's background rather than on keys of their own,
                // unless they were given a background or border explicitly.
                if let button = item as? CustomButtonTouchBarItem, button.backgroundColor == nil,
                   child.additionalParameters[.bordered] == nil {
                    button.isBordered = false
                    if button.style.symbol != nil, button.style.iconColor == nil { button.style.iconColor = .white }
                }
                card.append((item, child))
            }
            built.append(card)
        }
        cards = built
        cardsView = CardsView(cards: built.map { $0.compactMap { $0.item.view } }, dots: dots, fill: fill, glass: glass,
                              glassTint: tint, cornerRadius: radius)
        super.init(identifier: identifier)
        view = cardsView
        updateVisibility()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hides items whose "when" condition fails, and skips cards left with none.
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
    }

    /// Slides to the next (1) or previous (-1) card, as a swipe would.
    func advance(_ step: Int) { cardsView.advance(step) }

    func tearDown() {
        tearDownItems(cards.flatMap { $0.map { $0.item } })
        cards = []
    }
}

/// Lays the cards out side by side and slides between them under a pan.
final class CardsView: NSView {
    private let holders: [NSView]
    private var shown: [Bool]
    private(set) var current = 0
    private var offset: CGFloat = 0
    private var dragging = false
    private let glass: Bool
    private let glassTint: NSColor?
    private let cornerRadius: CGFloat
    private let dotsView: DotsView?

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
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                stack.topAnchor.constraint(equalTo: holder.topAnchor),
                stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            ])
            return holder
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = fill?.cgColor
        layer?.cornerRadius = cornerRadius
        holders.forEach(addSubview)
        if let dotsView = dotsView { addSubview(dotsView) }

        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = .direct
        addGestureRecognizer(pan)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let widest = holders.compactMap { $0.subviews.first?.fittingSize.width }.max() ?? 0
        return NSSize(width: widest + 16, height: ItemStyle.barHeight)
    }

    /// Cards that have something to show, in order.
    private var visibleCards: [Int] { shown.indices.filter { shown[$0] } }

    func setShown(_ values: [Bool]) {
        guard values.count == shown.count, values != shown else { return }
        shown = values
        if !shown[current], let first = visibleCards.first { current = first }
        needsLayout = true
        updateDots()
    }

    override func layout() {
        super.layout()
        place()
        dotsView?.frame = bounds
        updateDots()
    }

    private func updateDots() {
        guard let dotsView = dotsView else { return }
        let cards = visibleCards
        dotsView.count = cards.count
        dotsView.active = cards.firstIndex(of: current) ?? 0
    }

    /// The card next to `current` in the given direction, wrapping around.
    private func neighbor(_ step: Int) -> Int {
        let cards = visibleCards
        guard let position = cards.firstIndex(of: current), cards.count > 1 else { return current }
        return cards[(position + step + cards.count) % cards.count]
    }

    private var slotWidth: CGFloat { bounds.width }

    private func place() {
        let width = slotWidth
        let previous = neighbor(-1), next = neighbor(1)
        for (index, holder) in holders.enumerated() {
            var x: CGFloat?
            if index == current { x = offset }
            else if index == next, offset < 0 || !dragging { x = offset + width }
            if index == previous, offset > 0 || !dragging, previous != next || offset > 0 { x = offset - width }
            holder.isHidden = x == nil || !shown[index]
            holder.frame = NSRect(x: x ?? 0, y: 0, width: width, height: bounds.height)
        }
    }

    @objc private func panned(_ recognizer: NSPanGestureRecognizer) {
        guard visibleCards.count > 1 else { return }
        let width = max(slotWidth, 1)
        switch recognizer.state {
        case .began, .changed:
            dragging = true
            offset = max(-width, min(width, recognizer.translation(in: self).x))
            place()
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: self).x
            var step = 0
            if offset < -width / 4 || velocity < -400 { step = 1 }
            if offset > width / 4 || velocity > 400 { step = -1 }
            if recognizer.state == .cancelled { step = 0 }
            settle(step: step)
        default: break
        }
    }

    func advance(_ step: Int) {
        guard visibleCards.count > 1, !dragging else { return }
        dragging = true
        offset = 0
        place()
        settle(step: step)
    }

    /// Animates to the next card (step 1), the previous (-1), or back (0).
    private func settle(step: Int) {
        let width = slotWidth
        let incoming = step == 0 ? current : neighbor(step)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, holder) in holders.enumerated() where !holder.isHidden {
                var frame = holder.frame
                if index == current {
                    frame.origin.x = CGFloat(-step) * width
                } else if index == incoming {
                    frame.origin.x = 0
                } else {
                    frame.origin.x = frame.origin.x > 0 ? width : -width
                }
                holder.animator().frame = frame
            }
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.current = incoming
            self.offset = 0
            self.dragging = false
            self.place()
            self.updateDots()
        })
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
/// next card moves the bright dot right. Taps pass through to the keys beneath.
final class DotsView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    var active = 0 { didSet { needsDisplay = true } }

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
