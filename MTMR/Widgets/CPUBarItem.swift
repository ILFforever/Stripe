//
//  CPUBarItem.swift
//  MTMR
//
//  Created by bobrosoft on 17/08/2021.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Foundation

class CPUBarItem: CustomButtonTouchBarItem {
    private let refreshInterval: TimeInterval
    private var refreshQueue: DispatchQueue? = DispatchQueue(label: "mtmr.cpu")
    private let defaultSingleTapScript: NSAppleScript! = "activate application \"Activity Monitor\"\rtell application \"System Events\"\r\ttell process \"Activity Monitor\"\r\t\ttell radio button \"CPU\" of radio group 1 of group 2 of toolbar 1 of window 1 to perform action \"AXPress\"\r\tend tell\rend tell".appleScript

    init(identifier: NSTouchBarItem.Identifier, refreshInterval: TimeInterval, panel: PerformancePanelOptions) {
        self.refreshInterval = refreshInterval
        super.init(identifier: identifier, title: "")
        hideUntilFirstTitle()
                
        // Set default image
        if self.image == nil, !theme.stripeWidgets {
            self.image = #imageLiteral(resourceName: "cpu").resize(maxSize: NSSize(width: 24, height: 24));
        }
        // Stripe: no key; the figure and a meter sit on the bar.
        if theme.stripeWidgets { isBordered = false }
        
        // Set default action
        // Holding opens Activity Monitor's CPU tab.
        actions.append(ItemAction(trigger: .longTap, defaultTapAction))
        
        // A tap opens the CPU page.
        opensPerformancePanel(panel)
        PerformanceStats.shared.start()

        refreshAndSchedule()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func refreshAndSchedule() {
        DispatchQueue.main.async {
            // Get CPU load
            let usage = 100 - CPU.systemUsage().idle
            guard usage.isFinite else {
                return
            }
            
            if self.theme.stripeWidgets {
                self.showStripe(usage)
                return
            }
            // Choose color based on CPU load
            var color: NSColor? = nil
            var bgColor: NSColor? = nil
            if usage > 70 {
                color = .black
                bgColor = .yellow
            } else if usage > 30 {
                color = .yellow
            }
            
            // Update layout
            let attrTitle = NSMutableAttributedString.init(attributedString: String(format: "%.1f%%", usage).defaultTouchbarAttributedString)
            if let color = color {
                attrTitle.addAttributes([.foregroundColor: color], range: NSRange(location: 0, length: attrTitle.length))
            }
            self.attributedTitle = attrTitle
            // Changing the background rebuilds the key; only do it when it changes.
            if self.backgroundColor != bgColor { self.backgroundColor = bgColor }
        }
        
        refreshQueue?.asyncAfter(deadline: .now() + refreshInterval) { [weak self] in
            self?.refreshAndSchedule()
        }
    }

    /// Stripe's CPU: a dim chip icon, the figure, and a four-bar meter, all
    /// turning yellow when busy and orange when heavy.
    private func showStripe(_ usage: Double) {
        let color = StripeReadout.loadColor(usage)
        if style.symbol == nil {
            let tint = usage > 30 ? color : StripeReadout.dim
            image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tint])))
        }
        let text = NSMutableAttributedString(attributedString: StripeReadout.figure(String(format: "%.0f%%", usage), color: color))
        text.append(StripeReadout.gap(6))
        text.append(StripeReadout.meter(usage, color: color))
        attributedTitle = text
        // Room for "100%", so the key doesn't jump as the figure changes.
        minimumTitleWidth = ceil(StripeReadout.figure("100%").size().width) + 6 + 17
    }

    func defaultTapAction() {
        refreshQueue?.async { [weak self] in
            self?.defaultSingleTapScript.executeAndReturnError(nil)
        }
    }
    
    deinit {
        refreshQueue?.suspend()
        refreshQueue = nil
    }
}
