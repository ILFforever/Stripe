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
//  Tap plays or pauses (or, with "tapOpens", slides out controls beside it or
//  opens them across the bar),
//  double tap goes back, press and hold skips ahead, all via the media keys,
//  which reach whichever app is playing.
//
//  Stripe draws it in one of several designs ("design"); the Mini player is an
//  item of its own (MiniPlayerBarItem), since its keys are tapped separately.
//

import Cocoa

class MusicBarItem: CustomButtonTouchBarItem, TearDownable {
    /// Stripe's designs. MTMR's look (a scrolling title) is the theme's.
    enum Design: String {
        /// Artwork, and the title over the artist and how far in it is.
        case lines
        /// Artwork, the title over a thin bar that fills with the track, and the time left.
        case progress
        /// Bars that move while playing, and the title over the artist.
        case equalizer
        /// The track with previous, play/pause and next on one key (MiniPlayerBarItem).
        case player
        /// Round artwork in a ring that fills with the track, and the title.
        case ring
    }

    /// What a tap does besides nothing: "tapOpens".
    enum TapOpens: String {
        /// Plays or pauses (the default).
        case none
        /// Slides previous, play/pause and next out beside the key.
        case side
        /// Opens the controls across the bar, like the Battery Overview.
        case full
    }

    /// What a double tap or a press and hold can do ("doubleTapDoes", "holdDoes").
    enum Gesture: String, CaseIterable {
        case previous, next, playPause
        /// Slides previous, play/pause and next out beside the key.
        case side
        /// Opens the controls across the bar.
        case full
        case nothing

        var title: String {
            switch self {
            case .previous: return "Previous track"
            case .next: return "Next track"
            case .playPause: return "Play/Pause"
            case .side: return "Side controls"
            case .full: return "Full controls"
            case .nothing: return "Nothing"
            }
        }
    }

    /// The item's double tap and press and hold; previous and next unless the preset says otherwise.
    struct Gestures {
        var doubleTap = Gesture.previous
        var hold = Gesture.next
    }

    /// MTMR's scrolling title shows barely a word narrower than this.
    static let minimumWidth: CGFloat = 180

    private let disableMarquee: Bool
    private let design: Design
    private let tapOpens: TapOpens
    private let gestures: Gestures
    private let closeSide: Align
    /// The key itself; `view` is a row holding it and the side controls when it has them.
    private weak var keyButton: NSButton?
    private var sideControls: SideControlsView?
    private let row = NSStackView()
    /// The item's view with side controls: the key and the controls in one row, on
    /// one key background when the design sits on a key, so the key itself grows.
    private let container = NSView()
    /// With side controls, the key never draws its own background; this does, behind
    /// the key and the controls together, so it grows with them. Shown while the
    /// key is bordered, however that was decided: by the design, or by the preset,
    /// which sets "bordered" after the item is built.
    private let keyBackground = KeyBackgroundView()
    private var keyWanted = false
    private var marqueeTimer: Timer?
    private var observer: NSObjectProtocol?
    /// What's shown, so a refresh with the same track leaves the marquee where it is.
    private var shownTitle = ""
    private var shownPID: pid_t = 0
    private var shownPlaying: Bool?
    private let iconSize = NSSize(width: 21, height: 21)
    /// The artwork Stripe's design shows, and dimmed or not, so it's only redrawn when either changes.
    private weak var shownArtwork: NSImage?
    private var shownDimmed: Bool?

    init(identifier: NSTouchBarItem.Identifier, interval _: TimeInterval, disableMarquee: Bool,
         design: Design = .lines, tapOpens: TapOpens = .none, gestures: Gestures = Gestures(), closeSide: Align = .right) {
        self.disableMarquee = disableMarquee
        self.design = design
        let stripe = Theme.current.stripeWidgets
        self.tapOpens = stripe ? tapOpens : .none
        self.gestures = gestures
        self.closeSide = closeSide

        super.init(identifier: identifier, title: "")
        keyButton = view as? NSButton
        // Stripe says "Not playing" instead; MTMR's key stays hidden until there's a track.
        if !stripe { hideUntilFirstTitle() }
        // The two-line and progress designs sit on a key; the others straight on the bar.
        isBordered = stripe && (design == .lines || design == .progress)
        // Stripe's designs fit their content; MTMR's scrolling title needs room.
        if !stripe { view.widthAnchor.constraint(greaterThanOrEqualToConstant: MusicBarItem.minimumWidth).isActive = true }

        // The side controls are built when any gesture slides them out.
        let usesSide = stripe && (tapOpens == .side || gestures.doubleTap == .side || gestures.hold == .side)
        if usesSide {
            let side = SideControlsView()
            let wanted = isBordered
            sideControls = side
            row.orientation = .horizontal
            row.spacing = 0
            row.detachesHiddenViews = false
            row.translatesAutoresizingMaskIntoConstraints = false
            keyBackground.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(keyBackground)
            container.addSubview(row)
            // From here the setter below keeps the key itself bare and shows keyBackground instead.
            isBordered = wanted
            for view in [row, keyBackground] {
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    view.topAnchor.constraint(equalTo: container.topAnchor),
                    view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            // The button is rebuilt when its style changes, and put back as the item's view.
            finishViewConfiguration = { [weak self] in self?.wrapInRow() }
            wrapInRow()
        }
        let tap: Gesture = self.tapOpens == .side ? .side : self.tapOpens == .full ? .full : .playPause
        // A gesture set to nothing has no action, so a single tap doesn't wait to tell it from a double.
        var list = [ItemAction(trigger: .singleTap) { [weak self] in self?.perform(tap) }]
        if gestures.doubleTap != .nothing {
            list.append(ItemAction(trigger: .doubleTap) { [weak self] in self?.perform(gestures.doubleTap) })
        }
        if gestures.hold != .nothing {
            list.append(ItemAction(trigger: .longTap) { [weak self] in self?.perform(gestures.hold) })
        }
        actions = list

        if stripe, design == .equalizer {
            (keyButton as? CustomHeightButton)?.onLayout = { [weak self] in self?.placeEqualizer() }
        }
        observer = NotificationCenter.default.addObserver(forName: NowPlaying.didChange, object: nil, queue: .main) {
            [weak self] _ in
            self?.refresh()
            self?.sideControls?.refresh()
        }
        NowPlaying.shared.start()
        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Does what a gesture is set to.
    private func perform(_ gesture: Gesture) {
        switch gesture {
        case .previous: NowPlaying.press(NX_KEYTYPE_PREVIOUS)
        case .next: NowPlaying.press(NX_KEYTYPE_NEXT)
        case .playPause: NowPlaying.press(NX_KEYTYPE_PLAY)
        case .side: sideControls?.toggle()
        case .full: NowPlayingPanel.shared.open(closeSide: closeSide)
        case .nothing: break
        }
    }

    /// The key's own color, glass choice and tint go to the row's background too, and
    /// the key itself stays clear of them (as with isBordered, its own drawing reads these).
    override var backgroundColor: NSColor? {
        get { super.backgroundColor }
        set {
            if sideControls == nil {
                super.backgroundColor = newValue
            } else {
                super.backgroundColor = nil
                keyBackground.fill = newValue
            }
        }
    }

    override var glass: Bool? {
        didSet { keyBackground.glass = glass }
    }

    override var glassTint: NSColor? {
        didSet { keyBackground.glassTint = glassTint }
    }

    /// The key's own background, unless there are side controls (see keyBackground).
    override var isBordered: Bool {
        // Truthfully bare with side controls: the button's own drawing (its glass
        // pane, its color) reads this, and must not paint an old-width key under
        // the row's. `keyWanted` remembers whether the row shows a background.
        get { super.isBordered }
        set {
            if sideControls == nil {
                super.isBordered = newValue
            } else {
                keyWanted = newValue
                super.isBordered = false
                keyBackground.isHidden = !newValue
            }
            // A key has room around its content; a bare one sits straight on the bar.
            if theme.stripeWidgets { contentPadding = newValue ? 6 : 0 }
        }
    }

    /// The key and its side controls side by side, as the item's view.
    private func wrapInRow() {
        guard let side = sideControls, let key = keyButton else { return }
        if key.superview !== row { row.setViews([key, side], in: .leading) }
        if view !== container { view = container }
    }

    func tearDown() {
        sideControls?.stop()
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        equalizer.removeFromSuperlayer()
    }

    private func refresh() {
        let nowPlaying = NowPlaying.shared
        let track = [nowPlaying.title, nowPlaying.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        // The title only scrolls while playing; each step redraws the key.
        let playing = nowPlaying.isPlaying == true
        guard track != shownTitle || nowPlaying.appPID != shownPID || playing != shownPlaying else {
            // Same track: Stripe's artwork or position may still have changed.
            if theme.stripeWidgets { showStripe() }
            return
        }
        shownTitle = track
        shownPID = nowPlaying.appPID
        shownPlaying = playing

        marqueeTimer?.invalidate()
        marqueeTimer = nil
        if theme.stripeWidgets {
            showStripe()
            // The elapsed time and the progress move while playing.
            if playing, !track.isEmpty {
                marqueeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.showStripe() }
            }
            return
        }
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
        if disableMarquee || !playing {
            title = " " + track
        } else {
            title = " " + track + "     "
            marqueeTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(marquee),
                                                userInfo: nil, repeats: true)
        }
    }

    // MARK: Stripe's designs

    private static let artworkSize = NSSize(width: 22, height: 22)
    private static let dimmedTitle = NSColor(white: 1, alpha: 0.7)

    /// The chosen design, for what's playing now (or nothing).
    private func showStripe() {
        let nowPlaying = NowPlaying.shared
        let playing = nowPlaying.isPlaying == true
        guard nowPlaying.hasTrack else {
            showNothingPlaying()
            return
        }
        let title = nowPlaying.title.isEmpty ? nowPlaying.artist : nowPlaying.title
        let artist = nowPlaying.title.isEmpty ? "" : nowPlaying.artist
        switch design {
        case .lines, .player:
            showArtwork(dimmed: false)
            var details: [String] = []
            if !artist.isEmpty { details.append(MusicBarItem.shortened(artist, 24)) }
            if let elapsed = nowPlaying.elapsed { details.append(NowPlaying.clock(elapsed)) }
            attributedTitle = MusicBarItem.twoLines(MusicBarItem.shortened(title, 26), details.joined(separator: " · "))
        case .progress:
            showArtwork(dimmed: !playing)
            let fraction = nowPlaying.duration > 0 ? (nowPlaying.elapsed ?? 0) / nowPlaying.duration : 0
            let text = NSMutableAttributedString(attributedString:
                MusicBarItem.titleOverBar(title, fraction: fraction, dimmed: !playing))
            if nowPlaying.duration > 0 {
                text.append(StripeReadout.gap(8))
                text.append(NSAttributedString(string: "−" + NowPlaying.clock(nowPlaying.duration - (nowPlaying.elapsed ?? 0)), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: StripeReadout.dim,
                ]))
            }
            attributedTitle = text
        case .equalizer:
            if image == nil || shownArtwork != nil || shownDimmed != nil { showEqualizerSpace() }
            setEqualizer(playing ? .moving : .paused)
            attributedTitle = MusicBarItem.twoLines(MusicBarItem.shortened(title, 26), playing ? MusicBarItem.shortened(artist, 30) : "Paused",
                                                    top: playing ? .white : MusicBarItem.dimmedTitle)
        case .ring:
            let fraction = nowPlaying.duration > 0 ? (nowPlaying.elapsed ?? 0) / nowPlaying.duration : 0
            image = MusicBarItem.ring(artwork: nowPlaying.artworkOrAppIcon, fraction: fraction, playing: playing)
            shownArtwork = nil
            shownDimmed = nil
            attributedTitle = NSAttributedString(string: MusicBarItem.shortened(title, 26), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: playing ? NSColor.white : MusicBarItem.dimmedTitle,
            ])
        }
    }

    /// Each design's "Not playing", instead of a blank key.
    private func showNothingPlaying() {
        let hint = tapOpens == .none ? "Tap to play" : "Tap for controls"
        shownArtwork = nil
        shownDimmed = nil
        switch design {
        case .lines, .player:
            image = NowPlaying.emptyArtwork(size: MusicBarItem.artworkSize)
            attributedTitle = MusicBarItem.twoLines("Not playing", hint, top: MusicBarItem.dimmedTitle)
        case .progress:
            image = NowPlaying.emptyArtwork(size: MusicBarItem.artworkSize)
            attributedTitle = MusicBarItem.titleOverBar("Not playing", fraction: 0, dimmed: true)
        case .equalizer:
            showEqualizerSpace()
            setEqualizer(.idle)
            attributedTitle = MusicBarItem.twoLines("Not playing", hint, top: MusicBarItem.dimmedTitle)
        case .ring:
            image = MusicBarItem.ring(artwork: nil, fraction: 0, playing: false)
            attributedTitle = NSAttributedString(string: "Not playing", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: MusicBarItem.dimmedTitle,
            ])
        }
    }

    /// The track's artwork (else the app's icon), rounded, redrawn only when it changes.
    private func showArtwork(dimmed: Bool) {
        let artwork = NowPlaying.shared.artworkOrAppIcon
        guard artwork !== shownArtwork || dimmed != shownDimmed || artwork == nil else { return }
        shownArtwork = artwork
        shownDimmed = dimmed
        image = artwork.map { NowPlaying.roundedArtwork($0, size: MusicBarItem.artworkSize, dimmed: dimmed) }
            ?? NowPlaying.emptyArtwork(size: MusicBarItem.artworkSize)
    }

    /// `text`, cut to `limit` characters with an ellipsis.
    private static func shortened(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    /// A bold line over a smaller dim one (the second left out when empty),
    /// spaced to sit clear of the key's top and bottom edges.
    private static func twoLines(_ top: String, _ bottom: String, top topColor: NSColor = .white) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 12
        paragraph.maximumLineHeight = 12
        let text = NSMutableAttributedString(string: top, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: topColor, .paragraphStyle: paragraph,
        ])
        if !bottom.isEmpty {
            text.append(NSAttributedString(string: "\n" + bottom, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: StripeReadout.dim,
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    /// The Progress design's middle: the title over a thin bar filled to `fraction`,
    /// as one inline picture.
    private static func titleOverBar(_ title: String, fraction: Double, dimmed: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let text = NSAttributedString(string: shortened(title, 24), attributes: [
            .font: font, .foregroundColor: dimmed ? dimmedTitle : NSColor.white,
        ])
        let width = min(max(ceil(text.size().width), 110), 160)
        let size = NSSize(width: width, height: 22)
        let image = NSImage(size: size, flipped: true) { _ in
            text.draw(with: NSRect(x: 0, y: 0, width: width, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let track = NSRect(x: 0, y: 17, width: width, height: 3)
            NSColor(white: 1, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            var filled = track
            filled.size.width = width * CGFloat(min(max(fraction, 0), 1))
            NSColor(white: 1, alpha: dimmed ? 0.5 : 1).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        return StripeReadout.attachment(image, size: size)
    }

    /// The Ring design's picture: round artwork (dimmed with a play mark when
    /// paused, a note when nothing plays) in a ring filled to `fraction`.
    private static func ring(artwork: NSImage?, fraction: Double, playing: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 26)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 1.2, dy: 1.2))
            track.lineWidth = 2.2
            NSColor(white: 1, alpha: 0.22).setStroke()
            track.stroke()
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: rect.width / 2 - 1.2, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(fraction, 1)), clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor(white: 1, alpha: playing ? 1 : 0.5).setStroke()
                arc.stroke()
            }
            let inner = rect.insetBy(dx: 4.5, dy: 4.5)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: inner).addClip()
            if let artwork = artwork {
                artwork.draw(in: inner, from: .zero, operation: .sourceOver, fraction: playing ? 1 : 0.5)
            } else {
                NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1).setFill()
                inner.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let mark = artwork == nil ? "music.note" : (playing ? nil : "play.fill")
            if let mark = mark,
               let symbol = NSImage(systemSymbolName: mark, accessibilityDescription: nil)?
               .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                   .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: artwork == nil ? 0.45 : 1)]))) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Equalizer

    /// Four bars laid over the key where its image goes (see placeEqualizer),
    /// moved by Core Animation, so playing costs no redraws (see EqualizerLayer).
    private let equalizer = EqualizerLayer()

    /// A clear image the size of the bars and the room after them, so the key leaves space for both.
    private func showEqualizerSpace() {
        let space = NSImage(size: EqualizerLayer.imageSize, flipped: false) { _ in true }
        space.isTemplate = false
        image = space
        shownArtwork = nil
        shownDimmed = nil
    }

    private func setEqualizer(_ state: EqualizerLayer.State) {
        equalizer.apply(state)
        placeEqualizer()
    }

    /// Lays the bars over the key's image; called on every layout, since the image moves with the title.
    private func placeEqualizer() {
        guard equalizer.state != nil, let button = keyButton, let cell = button.cell, button.image != nil else { return }
        button.wantsLayer = true
        guard let host = button.layer else { return }
        if equalizer.superlayer !== host {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.addSublayer(equalizer)
            CATransaction.commit()
        }
        equalizer.place(in: cell.imageRect(forBounds: button.bounds))
    }

    @objc private func marquee() {
        let str = title
        if str.count > 10 {
            title = String(str.dropFirst()) + String(str.prefix(1))
        }
    }
}
