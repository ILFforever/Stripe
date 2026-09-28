//
//  BatteryStats.swift
//  Stripe
//
//  What the battery panel (BatteryPanel.swift) shows, from public sources only:
//
//  - BatteryPower: the system's power draw right now, and the charger, from the
//    battery's IOKit telemetry.
//  - BatteryHistory: charge over the last two days. macOS keeps its own history
//    where only root can read it, so Stripe records a sample a minute while it
//    runs (battery-history.json), and fills in older points from `pmset -g log`.
//  - AppEnergy: which apps use the most power, from each process's energy
//    counter. Processes running as root (WindowServer, kernel_task) can't be
//    read, and the display and other hardware aren't any app's, so app figures
//    are much smaller than the total.
//

import Foundation
import IOKit
import IOKit.ps
import AppKit

// MARK: - Power

struct BatteryPower {
    /// Watts the whole Mac is using, from battery or charger.
    let systemWatts: Double?
    /// The charger's rating in watts, when one is connected.
    let chargerWatts: Int?
    /// Watts going into the battery (positive) or coming out of it (negative).
    let batteryWatts: Double?

    static func read() -> BatteryPower {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return BatteryPower(systemWatts: nil, chargerWatts: nil, batteryWatts: nil) }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let telemetry = property("PowerTelemetryData") as? [String: Any]
        let adapter = property("AdapterDetails") as? [String: Any]
        let external = property("ExternalConnected") as? Bool ?? false

        var batteryWatts: Double?
        if let millivolts = (property("Voltage") as? NSNumber)?.doubleValue,
           let amperage = property("InstantAmperage") as? NSNumber ?? property("Amperage") as? NSNumber {
            // Reported unsigned; discharge is a negative current.
            let milliamps = Double(Int64(bitPattern: amperage.uint64Value))
            batteryWatts = millivolts * milliamps / 1_000_000
        }

        var systemWatts = (telemetry?["SystemLoad"] as? NSNumber).map { $0.doubleValue / 1000 }
        if systemWatts == nil || systemWatts == 0, !external, let battery = batteryWatts {
            systemWatts = -battery
        }
        let charger = external ? (adapter?["Watts"] as? NSNumber)?.intValue : nil
        return BatteryPower(systemWatts: systemWatts, chargerWatts: charger, batteryWatts: batteryWatts)
    }
}

// MARK: - History

final class BatteryHistory {
    static let shared = BatteryHistory()

    struct Sample: Codable {
        /// Seconds since 1970.
        let time: TimeInterval
        let charge: Int
        let onAC: Bool
    }

    private(set) var samples: [Sample] = []
    private var timer: Timer?
    private var unsaved = 0
    private static let keep: TimeInterval = 48 * 3600
    private static let interval: TimeInterval = 60
    private let path = appSupportDirectory + "/battery-history.json"

    /// Starts recording (once); called by battery items.
    func start() {
        guard timer == nil else { return }
        load()
        backfillFromPowerLog()
        record()
        timer = Timer.scheduledTimer(withTimeInterval: BatteryHistory.interval, repeats: true) { [weak self] _ in
            self?.record()
        }
    }

    /// Adds the current charge now, e.g. when the panel opens, so the graph ends at the present.
    func record() {
        let info = BatteryInfo()
        info.getPSInfo()
        guard !info.ACPower.isEmpty else { return } // no battery
        let now = Date().timeIntervalSince1970
        if let last = samples.last, now - last.time < 30, last.charge == info.current, last.onAC == info.onACPower {
            return
        }
        samples.append(Sample(time: now, charge: info.current, onAC: info.onACPower))
        trim()
        unsaved += 1
        if unsaved >= 10 { save() } // a write every ten minutes is plenty
    }

    func save() {
        unsaved = 0
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? FileManager.default.createDirectory(atPath: appSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func load() {
        guard let data = path.fileData, let saved = try? JSONDecoder().decode([Sample].self, from: data) else { return }
        samples = saved
        trim()
    }

    private func trim() {
        let cutoff = Date().timeIntervalSince1970 - BatteryHistory.keep
        if let first = samples.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            samples.removeFirst(first)
        } else if samples.last.map({ $0.time < cutoff }) ?? false {
            samples = []
        }
    }

    /// Older points from the power log ("… Using Batt(Charge: 74)"), for the time
    /// before Stripe started recording. Coarse: the log notes power events, not
    /// every minute.
    private func backfillFromPowerLog() {
        let before = samples.first?.time ?? Date().timeIntervalSince1970
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g", "log"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            let cutoff = Date().timeIntervalSince1970 - BatteryHistory.keep
            var found: [Sample] = []
            for line in text.split(separator: "\n") where line.contains("Charge:") {
                guard line.count > 25, let date = formatter.date(from: String(line.prefix(25))) else { continue }
                let time = date.timeIntervalSince1970
                guard time >= cutoff, time < before - 30,
                      let range = line.range(of: #"Using (Batt|AC)\s*\(Charge:\s*(\d+)"#, options: .regularExpression)
                else { continue }
                let match = line[range]
                let charge = Int(match.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
                guard (0 ... 100).contains(charge) else { continue }
                let sample = Sample(time: time, charge: charge, onAC: match.contains("AC"))
                if let last = found.last, last.charge == sample.charge, last.onAC == sample.onAC { continue }
                found.append(sample)
            }
            DispatchQueue.main.async {
                guard !found.isEmpty else { return }
                self.samples = (found + self.samples).sorted { $0.time < $1.time }
                self.save()
            }
        }
    }
}

// MARK: - Apps

final class AppEnergy {
    struct Usage {
        let name: String
        let icon: NSImage?
        let watts: Double
    }

    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: Date?
    /// Which app each process belongs to (nil: none); processes don't move between apps.
    private var owners: [pid_t: (String, String)?] = [:]
    /// Shared by every sampler, so reopening the panel doesn't look the icons up again.
    private static var icons: [String: NSImage] = [:]
    private static let iconLock = NSLock()

    /// Power per app since the last call, heaviest first, with icons for the
    /// first `limit`. The first call only takes a baseline and returns nothing.
    /// Safe to call off the main thread, one call at a time per sampler.
    func sample(limit: Int = .max) -> [Usage] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0

        var current: [pid_t: UInt64] = [:]
        var byApp: [String: (watts: Double, path: String)] = [:]
        // Stripe itself is left out: its share is mostly the cost of drawing this panel.
        let own = getpid()
        for pid in pids.prefix(max(count, 0)) where pid > 0 && pid != own {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard ok == 0 else { continue }
            current[pid] = info.ri_energy_nj
            guard elapsed > 0, let before = previous[pid], info.ri_energy_nj >= before else { continue }
            let watts = Double(info.ri_energy_nj - before) / 1e9 / elapsed
            guard watts > 0 else { continue }
            if owners[pid] == nil { owners[pid] = .some(AppEnergy.app(of: pid)) }
            guard let (name, path) = owners[pid] ?? nil else { continue }
            byApp[name, default: (0, path)].watts += watts
        }
        previous = current
        previousTime = now
        owners = owners.filter { current[$0.key] != nil } // forget processes that have exited

        let sorted = byApp.sorted { $0.value.watts > $1.value.watts }
        return sorted.enumerated().map { index, entry in
            Usage(name: entry.key, icon: index < limit ? AppEnergy.icon(for: entry.value.path) : nil, watts: entry.value.watts)
        }
    }

    /// The app a process belongs to: helpers inside Google Chrome.app count as
    /// Google Chrome. Background processes outside any app are left out; their
    /// names (siriactionsd…) mean little on the bar.
    static func app(of pid: pid_t) -> (String, String)? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<range.lowerBound]) + ".app"
        return ((appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), appPath)
    }

    static func icon(for path: String) -> NSImage? {
        iconLock.lock()
        defer { iconLock.unlock() }
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 18, height: 18)
        icons[path] = icon
        return icon
    }
}

// MARK: - Since plugged in / unplugged

extension BatteryHistory {
    /// The first sample after the Mac last switched to `onAC` (plugged in, or
    /// unplugged when false), if the history reaches back that far.
    func lastSwitch(to onAC: Bool) -> Sample? {
        guard let other = samples.lastIndex(where: { $0.onAC != onAC }), other + 1 < samples.count else { return nil }
        return samples[other + 1]
    }

    /// Percent per hour over about the last half hour, not reaching back past
    /// `since` (a plug or unplug). Nil until there's ten minutes to go on.
    func rate(now charge: Int, since: Sample?, window: TimeInterval = 1800) -> Double? {
        let now = Date().timeIntervalSince1970
        let earliest = max(now - window, since?.time ?? 0)
        guard let past = samples.first(where: { $0.time >= earliest }), now - past.time >= 600 else { return nil }
        return Double(charge - past.charge) / ((now - past.time) / 3600)
    }
}
