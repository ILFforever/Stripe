import Cocoa

class TimeTouchBarItem: CustomButtonTouchBarItem, TearDownable {
    private let dateFormatter = DateFormatter()
    private var timer: Timer!

    init(identifier: NSTouchBarItem.Identifier, formatTemplate: String, timeZone: String? = nil, locale: String? = nil) {
        dateFormatter.dateFormat = formatTemplate
        if let locale = locale {
            dateFormatter.locale = Locale(identifier: locale)
        }
        if let abbr = timeZone {
            dateFormatter.timeZone = TimeZone(abbreviation: abbr)
        }
        super.init(identifier: identifier, title: " ")
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateTime), userInfo: nil, repeats: true)
        isBordered = false
        updateTime()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Stripe's clock: the time in bold with the day and date stacked small
    /// beside it, when the format doesn't already show the date.
    private lazy var showsDate: Bool = {
        let format = dateFormatter.dateFormat ?? ""
        return theme.stripeWidgets && !format.contains { "dEMyL".contains($0) }
    }()
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
    private let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    @objc func updateTime() {
        let now = Date()
        guard showsDate else {
            title = dateFormatter.string(from: now)
            return
        }
        let text = NSMutableAttributedString(attributedString: StripeReadout.figure(dateFormatter.string(from: now)))
        text.append(StripeReadout.gap(6))
        text.append(StripeReadout.stacked(StripeReadout.small(dayFormatter.string(from: now)),
                                          StripeReadout.small(dateOnlyFormatter.string(from: now))))
        attributedTitle = text
    }

    func tearDown() {
        timer?.invalidate()
    }
}
