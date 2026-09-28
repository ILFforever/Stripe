import Foundation

class ScrollViewItem: NSCustomTouchBarItem/*, NSGestureRecognizerDelegate*/ {

    init(identifier: NSTouchBarItem.Identifier, items: [NSTouchBarItem]) {
        super.init(identifier: identifier)
        let views = items.compactMap { $0.view }
        let stackView = NSStackView(views: views)
        stackView.spacing = 1
        stackView.orientation = .horizontal
        // Groups keep the edges' 8pt from their neighbors, so two side by side read as two.
        let shown = items.filter { $0.view != nil }
        for (item, next) in zip(shown, shown.dropFirst()) where item is ClusterBarItem || next is ClusterBarItem {
            stackView.setCustomSpacing(8, after: item.view!)
        }
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: stackView.fittingSize))
        scrollView.documentView = stackView
        // Clear, so the bar's background shows behind the center items too.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        view = scrollView
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}
