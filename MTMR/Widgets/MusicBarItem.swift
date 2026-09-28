//
//  MusicBarItem.swift
//  MTMR
//
//  Created by Daniel Apatin on 05.05.2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//
//  Stripe: the track comes from macOS's now-playing information (NowPlaying),
//  so it works for any app macOS knows is playing (Music, Spotify, browsers…)
//  and nothing is asked of the apps themselves. The old version asked each
//  player and every browser tab over Apple Events on the main thread, which
//  froze the bar for over a second at a time with many tabs open.
//
//  Tap plays or pauses, double tap goes back, press and hold skips ahead, all
//  via the media keys, which reach whichever app is playing.
//

import Cocoa

class MusicBarItem: CustomButtonTouchBarItem, TearDownable {
    /// Narrower than this, the key shows barely a word of the track.
    static let minimumWidth: CGFloat = 180

    private let disableMarquee: Bool
    private var marqueeTimer: Timer?
    private var observer: NSObjectProtocol?
    /// What's shown, so a refresh with the same track leaves the marquee where it is.
    private var shownTitle = ""
    private var shownPID: pid_t = 0
    private var shownPlaying: Bool?
    private let iconSize = NSSize(width: 21, height: 21)

    init(identifier: NSTouchBarItem.Identifier, interval _: TimeInterval, disableMarquee: Bool) {
        self.disableMarquee = disableMarquee

        super.init(identifier: identifier, title: "")
        hideUntilFirstTitle()
        isBordered = false
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: MusicBarItem.minimumWidth).isActive = true

        actions = [
            ItemAction(trigger: .singleTap) { MusicBarItem.press(NX_KEYTYPE_PLAY) },
            ItemAction(trigger: .doubleTap) { MusicBarItem.press(NX_KEYTYPE_PREVIOUS) },
            ItemAction(trigger: .longTap) { MusicBarItem.press(NX_KEYTYPE_NEXT) },
        ]

        observer = NotificationCenter.default.addObserver(forName: NowPlaying.didChange, object: nil, queue: .main) {
            [weak self] _ in self?.refresh()
        }
        NowPlaying.shared.start()
        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
    }

    private static func press(_ key: Int32) {
        AccessibilityPermission.requestIfNeeded()
        HIDPostAuxKey(key)
    }

    private func refresh() {
        let nowPlaying = NowPlaying.shared
        let track = [nowPlaying.title, nowPlaying.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        // The title only scrolls while playing; each step redraws the key.
        let playing = nowPlaying.isPlaying == true
        guard track != shownTitle || nowPlaying.appPID != shownPID || playing != shownPlaying else { return }
        shownTitle = track
        shownPID = nowPlaying.appPID
        shownPlaying = playing

        marqueeTimer?.invalidate()
        marqueeTimer = nil
        guard !track.isEmpty else {
            image = nil
            title = ""
            return
        }
        if let app = NSRunningApplication(processIdentifier: nowPlaying.appPID), let icon = app.icon?.copy() as? NSImage {
            icon.size = iconSize
            image = icon
        } else {
            image = nil
        }
        if theme.stripeWidgets {
            // Stripe: the track in bold over the artist, shortened rather than scrolling.
            let line: (String, Int) -> String = { text, limit in
                text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 13
            paragraph.maximumLineHeight = 13
            let text = NSMutableAttributedString(string: line(nowPlaying.title.isEmpty ? track : nowPlaying.title, 26), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
            ])
            if !nowPlaying.artist.isEmpty, !nowPlaying.title.isEmpty {
                text.append(NSAttributedString(string: "\n" + line(nowPlaying.artist, 30), attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: StripeReadout.dim, .paragraphStyle: paragraph,
                ]))
            }
            attributedTitle = text
        } else if disableMarquee || !playing {
            title = " " + track
        } else {
            title = " " + track + "     "
            marqueeTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(marquee),
                                                userInfo: nil, repeats: true)
        }
    }

    @objc private func marquee() {
        let str = title
        if str.count > 10 {
            title = String(str.dropFirst()) + String(str.prefix(1))
        }
    }
}
