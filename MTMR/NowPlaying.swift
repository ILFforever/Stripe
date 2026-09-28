//
//  NowPlaying.swift
//  Stripe
//
//  Whether media is playing anywhere on the Mac (Music, Spotify, a browser…),
//  and what: the track's title and artist, and the app playing it.
//  macOS only tells Apple-signed processes, so the question is asked by
//  NowPlayingHelper.dylib running inside /usr/bin/perl; see NowPlayingHelper.m.
//  Started on first use and kept running; the helper exits when Stripe does.
//

import Foundation

final class NowPlaying {
    static let shared = NowPlaying()
    /// Posted on the main queue when anything here changes.
    static let didChange = Notification.Name("com.ilfforever.stripe.nowPlayingDidChange")

    /// Nil until the helper has answered (or if it can't run).
    private(set) var isPlaying: Bool?
    /// The current track, if any (paused ones too), and the app playing it.
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var appPID: pid_t = 0

    private var process: Process?
    private var restarts = 0
    private var buffer = ""

    private static let script = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $run = DynaLoader::dl_find_symbol($lib, "stripe_now_playing_run") or die "missing symbol";
    DynaLoader::dl_install_xsub("main::run", $run);
    run();
    """

    func start() {
        guard process == nil,
              let helper = Bundle.main.path(forResource: "NowPlayingHelper", ofType: "dylib") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", NowPlaying.script, helper]
        let output = Pipe()
        task.standardOutput = output
        task.standardInput = Pipe() // kept open while Stripe runs
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async { self?.received(text) }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.helperExited() }
        }
        do {
            try task.run()
            process = task
        } catch {
            NSLog("Stripe: couldn't start the now-playing helper: \(error)")
        }
    }

    private func received(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.hasPrefix("playing ") {
                let playing = line.hasSuffix("1")
                if playing != isPlaying {
                    isPlaying = playing
                    NotificationCenter.default.post(name: NowPlaying.didChange, object: self)
                }
            } else if line.hasPrefix("info "),
                      let data = line.dropFirst(5).data(using: .utf8),
                      let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                title = info["title"] as? String ?? ""
                artist = info["artist"] as? String ?? ""
                appPID = pid_t((info["pid"] as? NSNumber)?.int32Value ?? 0)
                NotificationCenter.default.post(name: NowPlaying.didChange, object: self)
            }
        }
    }

    /// Restarts the helper a few times if it dies, then gives up quietly.
    private func helperExited() {
        process = nil
        guard restarts < 5 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }
}
