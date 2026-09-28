//
//  NetworkBarItem.swift
//  MTMR
//
//  Created by Anton Palgunov on 23/02/2019.
//  Copyright © 2019 Anton Palgunov. All rights reserved.
//

import Foundation

class NetworkBarItem: CustomButtonTouchBarItem, Widget, TearDownable {
    private var bandwidthProcess: Process?
    private var dataObserver: NSObjectProtocol?

    func tearDown() {
        if let observer = dataObserver { NotificationCenter.default.removeObserver(observer) }
        dataObserver = nil
        bandwidthProcess?.terminate()
        bandwidthProcess = nil
    }

    static var name: String = "network"
    static var identifier: String = "com.toxblh.mtmr.network"
    
    private let flip: Bool
    private let units: String
    
    init(identifier: NSTouchBarItem.Identifier, flip: Bool = false, units: String) {
        self.flip = flip
        self.units = units
        super.init(identifier: identifier, title: "")
        hideUntilFirstTitle()
        // Wide enough for any reading, so the key keeps its size as speeds change.
        minimumTitleWidth = ceil(NSAttributedString(string: "↑000.0 KB/s", attributes: [.font: NetworkBarItem.titleFont]).size().width
            + NetworkBarItem.arrowGap)
        startMonitoringProcess()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startMonitoringProcess() {
        var pipe: Pipe
        var outputHandle: FileHandle
        var dSpeed: UInt64?
        var uSpeed: UInt64?
        var curr: Array<Substring>?
        var dataAvailable: NSObjectProtocol?

        pipe = Pipe()
        bandwidthProcess = Process()
        bandwidthProcess?.launchPath = "/usr/bin/env"
        bandwidthProcess?.arguments = ["netstat", "-w1", "-l", "en0"]
        bandwidthProcess?.standardOutput = pipe

        outputHandle = pipe.fileHandleForReading
        outputHandle.waitForDataInBackgroundAndNotify(forModes: [RunLoop.Mode.common])

        dataAvailable = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSFileHandleDataAvailable,
            object: outputHandle,
            queue: nil
        ) { [weak self] _ -> Void in
            guard let self = self else { return }
            let data = pipe.fileHandleForReading.availableData
            if data.count > 0 {
                if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                    curr = [""]
                    curr = str
                        .replacingOccurrences(of: "  ", with: " ")
                        .split(separator: " ")
                    if curr == nil || (curr?.count)! < 6 {} else {
                        if Int64(curr![2]) == nil {} else {
                            dSpeed = UInt64(curr![2])
                            uSpeed = UInt64(curr![5])

                            self.setTitle(up: self.getHumanizeSize(speed: uSpeed!), down: self.getHumanizeSize(speed: dSpeed!))
                        }
                    }
                }
                outputHandle.waitForDataInBackgroundAndNotify()
            } else if let dataAvailable = dataAvailable {
                NotificationCenter.default.removeObserver(dataAvailable)
            }
        }

        var dataReady: NSObjectProtocol?
        dataReady = NotificationCenter.default.addObserver(
            forName: Process.didTerminateNotification,
            object: outputHandle,
            queue: nil
        ) { _ -> Void in
            print("Task terminated!")
            if let observer = dataReady {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        dataObserver = dataAvailable
        bandwidthProcess?.launch()
    }

    func getHumanizeSize(speed: UInt64) -> String {
        let humanText: String
        
        func speedB(speed: UInt64)-> String {
            return String(format: "%.0f", Double(speed)) + " B/s"
        }
        
        func speedKB(speed: UInt64)-> String {
            return String(format: "%.1f", Double(speed) / 1024) + " KB/s"
        }
        
        func speedMB(speed: UInt64)-> String {
            return String(format: "%.1f", Double(speed) / (1024 * 1024)) + " MB/s"
        }
        
        func speedGB(speed: UInt64)-> String {
            return String(format: "%.2f", Double(speed) / (1024 * 1024 * 1024)) + " GB/s"
        }
        
        switch self.units {
        case "B/s":
            humanText = speedB(speed: speed)
        case "KB/s":
            humanText = speedKB(speed: speed)
        case "MB/s":
            humanText = speedMB(speed: speed)
        case "GB/s":
            humanText = speedGB(speed: speed)
        default:
            if speed < 1024 {
                humanText = speedB(speed: speed)
            } else if speed < (1024 * 1024) {
                humanText = speedKB(speed: speed)
            } else if speed < (1024 * 1024 * 1024) {
                humanText = speedMB(speed: speed)
            } else {
                humanText = speedGB(speed: speed)
            }
        }

        return humanText
    }
    
    /// Stripe: cyan up, green down, and the units dimmed beside the figures.
    private var arrowColors: (up: NSColor, down: NSColor) {
        theme.stripeWidgets ? (NSColor(srgbRed: 0x64 / 255, green: 0xD2 / 255, blue: 1, alpha: 1),
                               NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1))
            : (.systemBlue, .systemRed)
    }

    /// "1.2 KB/s" as the figure, with the unit dimmed in Stripe's design.
    private func speed(_ text: String, font: NSFont) -> NSAttributedString {
        guard theme.stripeWidgets, let space = text.lastIndex(of: " ") else {
            return NSAttributedString(string: text, attributes: [.font: font])
        }
        let result = NSMutableAttributedString(string: String(text[..<space]), attributes: [.font: font])
        result.append(NSAttributedString(string: String(text[space...]), attributes: [.font: font, .foregroundColor: StripeReadout.dim]))
        return result
    }

    func appendUpSpeed(appendString: NSMutableAttributedString, up: String, titleFont: NSFont, newStr: Bool = false) {
        appendString.append(NSMutableAttributedString(
            string: newStr ? "\n↑" : "↑",
            attributes: [
                NSAttributedString.Key.foregroundColor: arrowColors.up,
                NSAttributedString.Key.font: titleFont,
                NSAttributedString.Key.kern: NetworkBarItem.arrowGap,
                ]))
        
        appendString.append(speed(up, font: titleFont))
    }
    
    func appendDownSpeed(appendString: NSMutableAttributedString, down: String, titleFont: NSFont, newStr: Bool = false) {
        appendString.append(NSMutableAttributedString(
            string: newStr ? "\n↓" : "↓",
            attributes: [
                NSAttributedString.Key.foregroundColor: arrowColors.down,
                NSAttributedString.Key.font: titleFont,
                NSAttributedString.Key.kern: NetworkBarItem.arrowGap,
                ]))
            
            appendString.append(speed(down, font: titleFont))
    }
    
    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// Space between an arrow and its speed.
    private static let arrowGap: CGFloat = 2

    func setTitle(up: String, down: String) {
        let titleFont = NetworkBarItem.titleFont
        
        let newTitle: NSMutableAttributedString = NSMutableAttributedString(string: "")
        
        if (self.flip) {
            appendUpSpeed(appendString: newTitle, up: up, titleFont: titleFont)
            appendDownSpeed(appendString: newTitle, down: down, titleFont: titleFont, newStr: true)
        } else {
            appendDownSpeed(appendString: newTitle, down: down, titleFont: titleFont)
            appendUpSpeed(appendString: newTitle, up: up, titleFont: titleFont, newStr: true)
        }
        
        
        // Two 12pt lines leave 3pt above and below in the 30pt key; the button
        // cell centers the block (see CustomButtonCell.drawTitle).
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 12
        paragraph.maximumLineHeight = 12
        paragraph.alignment = .left
        newTitle.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: newTitle.length))

        self.attributedTitle = newTitle
    }
}
