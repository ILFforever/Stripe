import Foundation

class ScrollViewItem: NSCustomTouchBarItem/*, NSGestureRecognizerDelegate*/ {

    init(identifier: NSTouchBarItem.Identifier, items: [NSTouchBarItem]) {
        super.init(identifier: identifier)
        let views = items.compactMap { $0.view }
        let stackView = NSStackView(views: views)
        stackView.spacing = 1
        stackView.orientation = .horizontal
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
