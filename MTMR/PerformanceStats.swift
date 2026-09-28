//
//  PerformanceStats.swift
//  Stripe
//
//  CPU, GPU and memory readings for the CPU, GPU and CPU + GPU widgets and
//  their pages, sampled every two seconds while any of them is on the bar,
//  with the last two minutes kept for the pages' graph:
//
//  - CPU: each core's load since the last sample (host_processor_info), split
//    into performance and efficiency cores on Apple Silicon.
//  - GPU: the whole GPU's utilization and memory, as the IOAccelerator driver
//    reports them (macOS doesn't break GPU use down by app).
//  - Memory: used as Activity Monitor counts it (app + wired + compressed),
//    and the system's memory pressure.
//  - Top apps by CPU, sampled separately and only while a page is open.
//

import AppKit
import IOKit

final class PerformanceStats {
    static let shared = PerformanceStats()

    struct Sample {
        let time: Date
        let cpu: Double
        let gpu: Double?
    }

    /// Percent, 0–100, per core in the system's order.
    private(set) var cores: [Double] = []
    private(set) var cpu: Double = 0
    /// Nil where the Mac doesn't report it.
    private(set) var gpu: GPUReading?
    private(set) var memory = MemoryReading(used: 0, total: 0, pressure: .normal)
    /// Oldest first, two minutes' worth.
    private(set) var history: [Sample] = []

    static let historySpan: TimeInterval = 120
    static let interval: TimeInterval = 2

    /// Performance cores come after efficiency cores in the system's order on
    /// Apple Silicon; zero on Macs with one kind.
    let efficiencyCores = PerformanceStats.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    let performanceCores = PerformanceStats.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
    let chipName = PerformanceStats.sysctlString("machdep.cpu.brand_string") ?? "GPU"

    private var timer: Timer?
    private var previousTicks: [[UInt32]] = []

    private init() {}

    /// Starts sampling (idempotent); the widgets and pages call it.
    func start() {
        guard timer == nil else { return }
        sample()
        // CPU load is the change between two samples: a quick second one, so
        // the first figures aren't 0% for the whole first interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sample() }
        timer = Timer.scheduledTimer(withTimeInterval: PerformanceStats.interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer?.tolerance = 0.5
    }

    /// Average load of the performance and efficiency cores.
    var clusterLoads: (performance: Double, efficiency: Double)? {
        guard efficiencyCores > 0, performanceCores > 0, cores.count == efficiencyCores + performanceCores else { return nil }
        let efficiency = cores.prefix(efficiencyCores), performance = cores.suffix(performanceCores)
        return (performance.reduce(0, +) / Double(performance.count), efficiency.reduce(0, +) / Double(efficiency.count))
    }

    private func sample() {
        sampleCPU()
        gpu = GPUReading.read()
        memory = MemoryReading.read()
        let now = Date()
        history.append(Sample(time: now, cpu: cpu, gpu: gpu?.utilization))
        history.removeAll { now.timeIntervalSince($0.time) > PerformanceStats.historySpan }
    }

    private func sampleCPU() {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info = info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let ticks: [[UInt32]] = (0 ..< Int(cpuCount)).map { core in
            (0 ..< states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
        if previousTicks.count == ticks.count {
            cores = zip(ticks, previousTicks).map { now, before in
                let delta = zip(now, before).map { Double($0 &- $1) }
                let busy = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_SYSTEM)] + delta[Int(CPU_STATE_NICE)]
                let total = busy + delta[Int(CPU_STATE_IDLE)]
                return total > 0 ? busy / total * 100 : 0
            }
            cpu = cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
        }
        previousTicks = ticks
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// What the GPU driver reports about the whole GPU.
struct GPUReading {
    /// Percent of time the GPU was busy, and its rendering and tiling parts.
    let utilization: Double
    let renderer: Double?
    let tiler: Double?
    /// Memory the GPU is using, and has set aside, in bytes.
    let memoryInUse: Double?
    let memoryAllocated: Double?

    static func read() -> GPUReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var reading: GPUReading?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard reading == nil,
                  let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let stats = property.takeRetainedValue() as? [String: Any],
                  let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            reading = GPUReading(utilization: utilization,
                                 renderer: (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue,
                                 tiler: (stats["Tiler Utilization %"] as? NSNumber)?.doubleValue,
                                 memoryInUse: (stats["In use system memory"] as? NSNumber)?.doubleValue,
                                 memoryAllocated: (stats["Alloc system memory"] as? NSNumber)?.doubleValue)
        }
        return reading
    }
}

struct MemoryReading {
    enum Pressure { case normal, warning, critical }

    /// Bytes.
    let used: Double
    let total: Double
    let pressure: Pressure

    static func read() -> MemoryReading {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used = 0.0
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            // Activity Monitor's "Memory Used": app memory, wired and compressed.
            let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        }
        let level = PerformanceStats.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        let pressure: Pressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        return MemoryReading(used: used, total: total, pressure: pressure)
    }
}

/// CPU use per app, as Activity Monitor shows it (100% is one core), grouped
/// by the app each process belongs to.
final class AppCPU {
    struct Usage {
        let name: String
        let icon: NSImage?
        let percent: Double
    }

    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: Date?
    private var owners: [pid_t: (String, String)?] = [:]
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Busiest first; the first call only takes a baseline. Off the main thread,
    /// one call at a time.
    func sample(limit: Int) -> [Usage] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0
        var current: [pid_t: UInt64] = [:]
        var byApp: [String: (percent: Double, path: String)] = [:]
        let own = getpid()
        for pid in pids.prefix(max(count, 0)) where pid > 0 && pid != own {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            let time = info.ri_user_time + info.ri_system_time
            current[pid] = time
            guard elapsed > 0, let before = previous[pid], time > before else { continue }
            let seconds = Double(time - before) * AppCPU.timebase / 1e9
            if owners[pid] == nil { owners[pid] = .some(AppEnergy.app(of: pid)) }
            guard let (name, path) = owners[pid] ?? nil else { continue }
            byApp[name, default: (0, path)].percent += seconds / elapsed * 100
        }
        previous = current
        previousTime = now
        owners = owners.filter { current[$0.key] != nil }
        return byApp.sorted { $0.value.percent > $1.value.percent }.prefix(limit).map {
            Usage(name: $0.key, icon: AppEnergy.icon(for: $0.value.path), percent: $0.value.percent)
        }
    }
}

/// GPU use per app, as Activity Monitor's "% GPU" shows it: each app's share of
/// the GPU's time since the last call. The GPU driver keeps a running total of
/// GPU time for every process that uses it (AppUsage on each AGXDeviceUserClient
/// under the IOAccelerator); only processes inside an app are counted.
final class AppGPU {
    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: Date?
    private var owners: [pid_t: (String, String)?] = [:]

    /// Busiest first; the first call only takes a baseline. Off the main thread,
    /// one call at a time.
    func sample(limit: Int) -> [AppCPU.Usage] {
        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0
        let current = AppGPU.gpuTimes()
        var byApp: [String: (percent: Double, path: String)] = [:]
        for (pid, time) in current where pid != getpid() {
            guard elapsed > 0, let before = previous[pid], time > before else { continue }
            if owners[pid] == nil { owners[pid] = .some(AppEnergy.app(of: pid)) }
            guard let (name, path) = owners[pid] ?? nil else { continue }
            byApp[name, default: (0, path)].percent += Double(time - before) / 1e9 / elapsed * 100
        }
        previous = current
        previousTime = now
        owners = owners.filter { current[$0.key] != nil }
        return byApp.sorted { $0.value.percent > $1.value.percent }.prefix(limit).map {
            AppCPU.Usage(name: $0.key, icon: AppEnergy.icon(for: $0.value.path), percent: $0.value.percent)
        }
    }

    /// Nanoseconds of GPU time so far, per process.
    private static func gpuTimes() -> [pid_t: UInt64] {
        var times: [pid_t: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return times
        }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                // "pid 173, WindowServer"
                let pidText = creator.dropFirst(4).prefix { $0.isNumber }
                guard creator.hasPrefix("pid "), let pid = pid_t(pidText) else { continue }
                let total = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                times[pid, default: 0] += total
            }
        }
        return times
    }
}
