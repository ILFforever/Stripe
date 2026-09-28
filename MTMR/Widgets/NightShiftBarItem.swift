//
//  NightShiftBarItem.swift
//  MTMR
//
//  Created by Anton Palgunov on 28/08/2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Foundation

class NightShiftBarItem: CustomButtonTouchBarItem, TearDownable {
    private let nsclient = CBBlueLightClient()
    private var timer: Timer!

    private var blueLightStatus: Status {
        var status: Status = Status()
        nsclient.getBlueLightStatus(&status)
        return status
    }

    private var isNightShiftEnabled: Bool {
        return blueLightStatus.enabled.boolValue
    }

    private func setNightShift(state: Bool) {
        nsclient.setEnabled(state)
    }

    init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier, title: "")
        isBordered = false
        if !theme.stripeWidgets { setWidth(value: 28) } // MTMR's narrow key; Stripe sizes it like other keys
        
        actions.append(ItemAction(trigger: .singleTap) { [weak self] in self?.nightShiftAction() })

        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)

        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func nightShiftAction() {
        setNightShift(state: !isNightShiftEnabled)
        refresh()
    }

    @objc func refresh() {
        if theme.stripeWidgets {
            if style.symbol == nil { image = stripeSymbol(isNightShiftEnabled ? "sun.haze.fill" : "sun.haze") }
        } else {
            image = isNightShiftEnabled ? #imageLiteral(resourceName: "nightShiftOn") : #imageLiteral(resourceName: "nightShiftOff")
        }
        setBuiltInActive(isNightShiftEnabled)
    }

    func tearDown() {
        timer?.invalidate()
    }
}
