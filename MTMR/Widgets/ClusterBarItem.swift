//
//  ClusterBarItem.swift
//  Stripe
//
//  Several items drawn as one key: side by side on a shared background, with
//  optional dividers, e.g. previous / play / next. Unlike a group (a folder that
//  opens a sub-bar), a cluster's items are always on the bar.
//
//    { "type": "cluster",
//      "items": [{ "type": "previous" }, { "type": "play" }, { "type": "next" }],
//      "background": "#444444", "style": "pill",   // or "bordered": false for none
//      "dividers": true, "spacing": 0, "itemWidth": 40, "padding": 6 }
//

import Cocoa

struct ClusterOptions {
    /// Thin lines between the items.
    var dividers = false
    /// Space between the items.
    var spacing: CGFloat = 0
    /// Minimum width of each item, so icon-only keys get room to tap.
    var itemWidth: CGFloat?
    /// Space between the background's edges and the first and last items.
    var padding: CGFloat?
}

class ClusterBarItem: NSCustomTouchBarItem, TearDownable {
    private var children: [(item: NSTouchBarItem, definition: BarItemDefinition)] = []
    /// Passed in rather than read from `TouchBarController.shared`, which isn't
    /// available yet while the bar loads its first preset during its own init.
    private unowned let bar: TouchBarController

    /// The background of a key with no color of its own: the same gray as a key.
    static let standardBackground = CustomButtonTouchBarItem.standardKeyColor
    static let standardCornerRadius: CGFloat = 6

    init(identifier: NSTouchBarItem.Identifier, items definitions: [BarItemDefinition], options: ClusterOptions,
         definition: BarItemDefinition, bar: TouchBarController) {
        self.bar = bar
        super.init(identifier: identifier)

        var fill: NSColor? = ClusterBarItem.standardBackground
        if case let .background(color)? = definition.additionalParameters[.background] {
            fill = color
        } else if case .bordered(false)? = definition.additionalParameters[.bordered] {
            fill = nil
        }
        var radius = ClusterBarItem.standardCornerRadius
        if case let .style(style)? = definition.additionalParameters[.style], let custom = style.cornerRadius {
            radius = custom
        }

        for child in definitions {
            let childIdentifier = NSTouchBarItem.Identifier(child.type.identifierBase + UUID().uuidString)
            guard let item = bar.createItem(forIdentifier: childIdentifier, definition: child),
                  !(item is SwipeItem), let view = item.view else { continue }
            // Items sit on the cluster's background rather than on keys of their own,
            // unless they were given a background or border explicitly.
            if let button = item as? CustomButtonTouchBarItem, button.backgroundColor == nil,
               child.additionalParameters[.bordered] == nil {
                button.isBordered = false
                // Full white, as on a key: without a key of its own, the system
                // dims icons (and ignores a tint), so the icon is colored itself.
                if button.style.symbol != nil, button.style.iconColor == nil {
                    button.style.iconColor = .white
                }
            }
            if let itemWidth = options.itemWidth {
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: itemWidth).isActive = true
            }
            children.append((item, child))
        }

        let clusterView = ClusterView(views: children.compactMap { $0.item.view }, fill: fill, cornerRadius: radius,
                                      spacing: options.spacing,
                                      padding: options.padding ?? (fill == nil ? 0 : min(radius / 2, 8)))
        clusterView.dividers = options.dividers
        view = clusterView
        updateVisibility()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows only the items whose "when" condition holds; the cluster hides when
    /// none do, or when it has none yet (Settings shows it as a place to drop items).
    func updateVisibility() {
        for child in children {
            let hidden = !bar.isVisible(child.definition)
            if child.item.view?.isHidden != hidden { child.item.view?.isHidden = hidden }
        }
        bar.updateActiveStates(children.map { $0.item })
        let empty = children.allSatisfy { $0.item.view?.isHidden ?? true }
        if view.isHidden != empty { view.isHidden = empty }
        view.needsDisplay = true
    }

    func tearDown() {
        tearDownItems(children.map { $0.item })
        children = []
    }
}

/// The shared background, the items in a row, and the dividers between them.
final class ClusterView: NSView {
    private let stack: NSStackView

    var dividers = false {
        didSet { needsDisplay = true }
    }

    init(views: [NSView], fill: NSColor?, cornerRadius: CGFloat, spacing: CGFloat, padding: CGFloat) {
        stack = NSStackView(views: views)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill?.cgColor
        layer?.cornerRadius = cornerRadius

        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: ItemStyle.barHeight),
        ])
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if dividers { needsDisplay = true }
    }

    override func draw(_: NSRect) {
        guard dividers else { return }
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        NSColor.white.withAlphaComponent(0.25).setFill()
        for (left, right) in zip(visible, visible.dropFirst()) {
            let x = (convert(left.frame, from: stack).maxX + convert(right.frame, from: stack).minX) / 2
            NSRect(x: x.rounded() - 0.5, y: 8, width: 1, height: bounds.height - 16).fill()
        }
    }
}
