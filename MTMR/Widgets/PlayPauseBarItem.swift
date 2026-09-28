//
//  PlayPauseBarItem.swift
//  Stripe
//
//  The play / pause key. It sends the play key like before, and lights one half
//  of its ▶❙❙ icon: by default the action a tap will take (❙❙ while playing, ▶
//  while paused), or with "litWhilePlaying": "play" what's happening. It counts
//  as active (for "activeBackground") while playing.
//

import Cocoa

class PlayPauseBarItem: CustomButtonTouchBarItem, TearDownable {
    private var observer: NSObjectProtocol?
    private let litWhilePlaying: PlayPauseIcon.Half

    init(identifier: NSTouchBarItem.Identifier, litWhilePlaying: PlayPauseIcon.Half) {
        self.litWhilePlaying = litWhilePlaying
        super.init(identifier: identifier, title: "")
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
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
    }

    override var style: ItemStyle {
        didSet { refresh() } // keep the live icon when the preset's style is applied
    }

    private func refresh() {
        let playing = NowPlaying.shared.isPlaying
        // A custom icon from the preset stays as it is.
        if style.symbol == nil, !theme.litPlayPause {
            image = PlayPauseIcon.image(lit: nil, color: .white) // MTMR's static icon
        } else if style.symbol == nil {
            let other: PlayPauseIcon.Half = litWhilePlaying == .play ? .pause : .play
            image = PlayPauseIcon.image(lit: playing.map { $0 ? litWhilePlaying : other },
                                        color: style.iconColor ?? .white)
        }
        setBuiltInActive(playing == true)
    }
}

/// The system's ▶❙❙ icon with one half dimmed.
enum PlayPauseIcon {
    private static let base = NSImage(named: NSImage.touchBarPlayPauseTemplateName)!
    private static let dimmed: CGFloat = 0.35

    enum Half { case play, pause }

    /// Both halves lit when `lit` is nil (the state isn't known).
    static func image(lit: Half?, color: NSColor) -> NSImage {
        guard let lit = lit else { return base }
        let size = base.size
        let split = splitX
        let image = NSImage(size: size, flipped: false) { rect in
            let halves = [(NSRect(x: 0, y: 0, width: split, height: size.height), lit == .play),
                          (NSRect(x: split, y: 0, width: size.width - split, height: size.height), lit == .pause)]
            for (area, lit) in halves {
                NSGraphicsContext.saveGraphicsState()
                area.clip()
                base.draw(in: rect)
                color.withAlphaComponent(lit ? 1 : dimmed).set()
                rect.fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Where ▶ ends and ❙❙ begins: the empty column nearest the middle of the icon.
    private static let splitX: CGFloat = {
        let size = base.size
        let scale: CGFloat = 4
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return size.width / 2
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let empty = (width / 4 ..< width * 3 / 4).filter { x in
            (0 ..< height).allSatisfy { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.05 }
        }
        guard let column = empty.min(by: { abs($0 - width / 2) < abs($1 - width / 2) }) else { return size.width / 2 }
        // The middle of that gap, so both shapes keep a margin.
        var start = column, end = column
        while empty.contains(start - 1) { start -= 1 }
        while empty.contains(end + 1) { end += 1 }
        return CGFloat(start + end + 1) / 2 / scale
    }()
}
