//
//  NowPlayingViews.swift
//  Stripe
//
//  What Now Playing shows beyond its key: the Mini player design (the track
//  with previous, play/pause and next on one key), the controls a tap slides out
//  beside the key ("tapOpens": "side"), and the panel it opens across the bar
//  ("tapOpens": "full").
//

import AppKit

extension NowPlaying {
    /// Presses a media key (NX_KEYTYPE_PLAY, _NEXT, _PREVIOUS), which reaches
    /// whichever app is playing.
    static func press(_ key: Int32) {
        AccessibilityPermission.requestIfNeeded()
        HIDPostAuxKey(key)
    }

    /// "1:42".
    static func clock(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(seconds, 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The gray tile with a note that stands in for artwork when nothing plays.
    static func emptyArtwork(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let config = NSImage.SymbolConfiguration(pointSize: size.height * 0.45, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.45)]))
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = note.size
                note.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `image` at `size` with rounded corners, like album art on the Mac.
    static func roundedArtwork(_ image: NSImage, size: NSSize, dimmed: Bool = false) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.5 : 1)
            return true
        }
        result.isTemplate = false
        return result
    }

    /// The track's artwork, else the playing app's icon.
    var artworkOrAppIcon: NSImage? {
        artwork ?? NSRunningApplication(processIdentifier: appPID)?.icon
    }

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }
}

/// A media key inside the mini player or the panel: a symbol that lights a
/// rounded highlight while pressed, and presses its key when the finger lifts
/// inside it (sliding off cancels), with a haptic click.
final class MediaKeyView: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    /// Called after the tap's own action.
    var onPress: (() -> Void)?
    private let onTap: () -> Void
    private var pressed = false {
        didSet {
            guard pressed != oldValue else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = pressed ? 0.08 : 0.2
                context.allowsImplicitAnimation = true
                layer?.backgroundColor = NSColor(white: 1, alpha: pressed ? 0.22 : 0).cgColor
            }
        }
    }

    init(symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        onTap = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.allowedTouchTypes = .direct
        addGestureRecognizer(press)
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: ItemStyle.barHeight) }

    override func draw(_: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: dimmed ? 0.3 : 1)]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        let inside = bounds.contains(recognizer.location(in: self))
        switch recognizer.state {
        case .began:
            pressed = true
            HapticFeedback.instance.tap(type: .click)
        case .changed:
            pressed = inside
        case .ended:
            pressed = false
            if inside {
                onTap()
                onPress?()
            }
        default:
            pressed = false
        }
    }
}

/// A key's background drawn by Stripe: the key's own color, else glass or the
/// standard gray as the key (or, failing that, the bar's Theme › Keys) says, as
/// the bar's other keys draw it.
final class KeyBackgroundView: NSView {
    /// The key's own choices ("background", "glass", "glassTint"); unset ones follow the bar.
    var fill: NSColor? { didSet { configure() } }
    var glass: Bool? { didSet { configure() } }
    var glassTint: NSColor? { didSet { needsDisplay = true } }
    private let barGlass = CustomButtonTouchBarItem.glass

    private var drawsGlass: Bool { fill == nil && (glass ?? barGlass) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = StripeKeys.standardRadius
        layer?.masksToBounds = true
        configure()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Glass is a drawn picture, redrawn at each size as it grows with the side
    /// controls; a color is just the layer's, which resizes cleanly as it animates.
    private func configure() {
        if drawsGlass {
            layer?.backgroundColor = nil
            layerContentsRedrawPolicy = .duringViewResize
        } else {
            layer?.contents = nil
            layer?.backgroundColor = (fill ?? CustomButtonTouchBarItem.standardKeyColor).cgColor
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { !drawsGlass }

    override func updateLayer() {
        layer?.backgroundColor = (fill ?? CustomButtonTouchBarItem.standardKeyColor).cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if drawsGlass { needsDisplay = true }
    }

    override func draw(_: NSRect) {
        guard drawsGlass else { return }
        GlassPainter.draw(in: self, rect: bounds, radius: StripeKeys.standardRadius, pressed: false,
                          style: CustomButtonTouchBarItem.glassStyle, tint: glassTint ?? CustomButtonTouchBarItem.glassTint)
        // Stretch only a sliver in the middle, so the rounded ends keep their shape.
        if bounds.width > 20 {
            layer?.contentsCenter = CGRect(x: 0.5 - 1 / bounds.width, y: 0, width: 2 / bounds.width, height: 1)
        }
    }
}

/// Previous, play/pause and next, as the side controls and the mini player show them.
final class MediaKeysRow: NSStackView {
    private let playPause = MediaKeyView(symbol: "play.fill") { NowPlaying.press(NX_KEYTYPE_PLAY) }
    private let previous: MediaKeyView
    private let next: MediaKeyView

    /// `pressed`: called on any press, e.g. to keep the side controls open a while longer.
    init(pressed: (() -> Void)? = nil) {
        previous = MediaKeyView(symbol: "backward.fill") { NowPlaying.press(NX_KEYTYPE_PREVIOUS); pressed?() }
        next = MediaKeyView(symbol: "forward.fill") { NowPlaying.press(NX_KEYTYPE_NEXT); pressed?() }
        super.init(frame: .zero)
        let play = playPause
        play.onPress = pressed
        setViews([previous, play, next], in: .leading)
        orientation = .horizontal
        spacing = 2
        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let nowPlaying = NowPlaying.shared
        playPause.symbol = nowPlaying.isPlaying == true ? "pause.fill" : "play.fill"
        previous.dimmed = !nowPlaying.hasTrack
        next.dimmed = !nowPlaying.hasTrack
    }
}

/// A thin track that fills with the song, for the controls panel.
final class TrackProgressView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 3) }

    override func draw(_: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 3) / 2, width: bounds.width, height: 3)
        NSColor(white: 1, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        var filled = track
        filled.size.width = track.width * CGFloat(min(max(fraction, 0), 1))
        NSColor(white: 1, alpha: dimmed ? 0.5 : 1).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// The track (artwork, title over artist) and previous, play/pause and next.
/// In the panel it also shows how far in the track is.
final class NowPlayingControls: NSView {
    enum Kind { case key, panel }

    private let kind: Kind
    private let artwork = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let progress = TrackProgressView()
    private let elapsedField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")
    private let keys = MediaKeysRow()
    /// The key behind the mini player (see MiniPlayerBarItem's key look).
    let keyBackground = KeyBackgroundView()
    private var shownArtwork: NSImage?
    private static let artworkSize = NSSize(width: 22, height: 22)

    /// `onTrackTap`: what a tap on the artwork or title does (the mini player
    /// opens the panel from there when asked to).
    init(kind: Kind, onTrackTap: (() -> Void)? = nil) {
        self.kind = kind
        super.init(frame: .zero)

        titleField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .white
        subtitleField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleField.textColor = StripeReadout.dim
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        }
        let labels = NSStackView(views: [titleField, subtitleField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.widthAnchor.constraint(equalToConstant: NowPlayingControls.artworkSize.width).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: NowPlayingControls.artworkSize.height).isActive = true

        let track = NSStackView(views: [artwork, labels])
        track.orientation = .horizontal
        track.spacing = 8
        if let onTrackTap = onTrackTap {
            let tap = NSClickGestureRecognizer(target: self, action: #selector(trackTapped))
            tap.allowedTouchTypes = .direct
            track.addGestureRecognizer(tap)
            self.onTrackTap = onTrackTap
        }

        var views: [NSView] = [track]
        switch kind {
        case .key:
            labels.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let divider = PanelDivider()
            views += [divider, keys]
        case .panel:
            labels.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
            for field in [elapsedField, durationField] {
                field.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                field.textColor = StripeReadout.dim
            }
            progress.setContentHuggingPriority(.init(1), for: .horizontal)
            let timeline = NSStackView(views: [elapsedField, progress, durationField])
            timeline.orientation = .horizontal
            timeline.spacing = 8
            timeline.setHuggingPriority(.init(1), for: .horizontal)
            views += [timeline, keys]
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = kind == .key ? 8 : 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: kind == .key ? 8 : 4, bottom: 0, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        if kind == .key {
            // The key behind it: gray, or glass like the bar's other keys.
            let background = keyBackground
            background.translatesAutoresizingMaskIntoConstraints = false
            addSubview(background)
            NSLayoutConstraint.activate([
                background.leadingAnchor.constraint(equalTo: leadingAnchor),
                background.trailingAnchor.constraint(equalTo: trailingAnchor),
                background.topAnchor.constraint(equalTo: topAnchor),
                background.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: ItemStyle.barHeight),
        ])
        if kind == .panel { setContentHuggingPriority(.init(1), for: .horizontal) }
        refresh()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var onTrackTap: (() -> Void)?

    @objc private func trackTapped() {
        onTrackTap?()
    }

    /// Shows what's playing now.
    func refresh() {
        let nowPlaying = NowPlaying.shared
        let playing = nowPlaying.isPlaying == true
        keys.refresh()
        guard nowPlaying.hasTrack else {
            if shownArtwork != nil || artwork.image == nil {
                artwork.image = NowPlaying.emptyArtwork(size: NowPlayingControls.artworkSize)
                shownArtwork = nil
            }
            titleField.stringValue = "Not playing"
            titleField.textColor = NSColor(white: 1, alpha: 0.7)
            subtitleField.stringValue = ""
            subtitleField.isHidden = true
            progress.fraction = 0
            elapsedField.stringValue = ""
            durationField.stringValue = ""
            return
        }
        let art = nowPlaying.artworkOrAppIcon
        if art !== shownArtwork || art == nil {
            shownArtwork = art
            artwork.image = art.map { NowPlaying.roundedArtwork($0, size: NowPlayingControls.artworkSize) }
                ?? NowPlaying.emptyArtwork(size: NowPlayingControls.artworkSize)
        }
        artwork.alphaValue = playing ? 1 : 0.5
        titleField.stringValue = nowPlaying.title.isEmpty ? nowPlaying.artist : nowPlaying.title
        titleField.textColor = NSColor(white: 1, alpha: playing ? 1 : 0.7)
        subtitleField.stringValue = nowPlaying.title.isEmpty ? "" : nowPlaying.artist
        subtitleField.isHidden = subtitleField.stringValue.isEmpty
        if kind == .panel {
            let elapsed = nowPlaying.elapsed ?? 0
            progress.fraction = nowPlaying.duration > 0 ? elapsed / nowPlaying.duration : 0
            progress.dimmed = !playing
            elapsedField.stringValue = NowPlaying.clock(elapsed)
            durationField.stringValue = nowPlaying.duration > 0 ? NowPlaying.clock(nowPlaying.duration) : ""
        }
    }
}

/// The Mini player design: its own item, since its keys are tapped separately.
final class MiniPlayerBarItem: NSCustomTouchBarItem, TearDownable {
    private var controls: NowPlayingControls!
    private var observer: NSObjectProtocol?

    /// The key look the preset asks for ("bordered": false is Background: None,
    /// "background" a color, "glass" and "glassTint" the glass), as any key takes it.
    func setKeyLook(bordered: Bool? = nil, background: NSColor? = nil, glass: Bool? = nil, glassTint: NSColor? = nil) {
        let key = controls.keyBackground
        if let bordered = bordered { key.isHidden = !bordered }
        if let background = background { key.fill = background }
        if let glass = glass { key.glass = glass }
        if let glassTint = glassTint { key.glassTint = glassTint }
    }

    /// Its track area plays and pauses, or opens the full panel with "tapOpens": "full"
    /// (its own keys already are the side controls).
    init(identifier: NSTouchBarItem.Identifier, tapOpens: MusicBarItem.TapOpens, closeSide: Align) {
        super.init(identifier: identifier)
        controls = NowPlayingControls(kind: .key) {
            if tapOpens == .full {
                NowPlayingPanel.shared.open(closeSide: closeSide)
            } else {
                NowPlaying.press(NX_KEYTYPE_PLAY)
            }
        }
        view = controls
        observer = NotificationCenter.default.addObserver(forName: NowPlaying.didChange, object: nil, queue: .main) {
            [weak self] _ in self?.controls.refresh()
        }
        NowPlaying.shared.start()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
    }
}

/// The controls a tap on Now Playing opens ("tapOpensControls"): the track,
/// how far in it is, and previous, play/pause and next, over the main bar
/// like the Battery Overview, with a back chevron at one end.
final class NowPlayingPanel: NSObject, NSTouchBarDelegate {
    static let shared = NowPlayingPanel()

    private let identifier = NSTouchBarItem.Identifier("com.ilfforever.stripe.nowPlayingPanel")
    private var view: NSView?
    private var controls: NowPlayingControls?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    var isOpen: Bool { timer != nil }

    func open(closeSide: Align) {
        guard !isOpen else { return }
        let controls = NowPlayingControls(kind: .panel)
        self.controls = controls
        let back = PanelBackButton(pointing: closeSide) { [weak self] in self?.close() }
        let divider = PanelDivider()
        let stack = NSStackView(views: closeSide == .left ? [back, divider, controls] : [controls, divider, back])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.setHuggingPriority(.init(1), for: .horizontal)
        let slab = PanelSlab(content: stack)
        view = slab
        slab.alphaValue = 0
        TouchBarController.shared.showSubBar(identifiers: [identifier], delegate: self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            slab.animator().alphaValue = 1
        }
        // The position moves every second while playing.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        observer = NotificationCenter.default.addObserver(forName: NowPlaying.didChange, object: nil, queue: .main) {
            [weak self] _ in self?.refresh()
        }
    }

    /// Fades the panel out, then brings back the main bar.
    func close() {
        guard isOpen, let view = view else { return }
        stop()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Unless it was reopened while fading out.
            guard let self = self, !self.isOpen else { return }
            self.view = nil
            TouchBarController.shared.restoreMainBar()
        })
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        controls = nil
    }

    private func refresh() {
        // Something else (a preset reload) took the bar back.
        if isOpen, TouchBarController.shared.subBarOwner !== self {
            stop()
            view = nil
            return
        }
        controls?.refresh()
    }

    func touchBar(_: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == self.identifier, let view = view else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        return item
    }
}

/// The side controls ("tapOpens": "side"): a divider, then previous, play/pause
/// and next, sliding out of Now Playing's key (which grows to hold them) when
/// it's tapped, and back in when it's tapped again or left alone for a few seconds.
final class SideControlsView: NSView {
    private let keys: MediaKeysRow
    private var width: NSLayoutConstraint!
    private var collapseTimer: Timer?
    private(set) var isOpen = false
    static let openWidth: CGFloat = 122

    override init(frame: NSRect) {
        var bump: (() -> Void)?
        keys = MediaKeysRow { bump?() }
        super.init(frame: frame)
        bump = { [weak self] in self?.keepOpen() }
        wantsLayer = true
        layer?.masksToBounds = true
        let divider = PanelDivider()
        for view in [divider, keys] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        width = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: ItemStyle.barHeight),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            keys.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 6),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        keys.refresh()
    }

    func toggle() {
        setOpen(!isOpen)
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        collapseTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = open ? 0.22 : 0.18
            context.allowsImplicitAnimation = true
            width.animator().constant = open ? SideControlsView.openWidth : 0
            animator().alphaValue = open ? 1 : 0
            // Lay out the whole bar, not just the key's row: the key's background
            // and the items after it move with the controls.
            var top: NSView = self
            while let parent = top.superview { top = parent }
            top.layoutSubtreeIfNeeded()
        }
        if open { keepOpen() }
    }

    /// Closes again after a few seconds without a press.
    private func keepOpen() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.setOpen(false) }
    }

    func stop() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }
}
