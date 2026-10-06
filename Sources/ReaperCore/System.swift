import Darwin
import Foundation

public enum Pressure: Int, Sendable, Codable {
    case normal = 1, warning = 2, critical = 4
}

/// System-wide memory counters at one instant. Diagnosis compares two of
/// them: a full swap file costs nothing while nobody pages it back in.
public struct SystemSample: Sendable {
    public let time: TimeInterval
    public let pressure: Pressure
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let compressed: UInt64
    public let memTotal: UInt64
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    /// File cache is left out on purpose; macOS fills free RAM with it.
    public let memUsed: UInt64
    public let appMemory: UInt64
    public let wired: UInt64
    public let swapins: UInt64
    public let swapouts: UInt64
    public let decompressions: UInt64
    public let pageSize: UInt64
    public let thermal: ProcessInfo.ThermalState

    public static func now() -> SystemSample {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        var mem: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)

        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let appPages = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
        return SystemSample(
            time: Date().timeIntervalSince1970,
            pressure: Pressure(rawValue: Int(level)) ?? .normal,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            compressed: UInt64(vm.compressor_page_count) * UInt64(page),
            memTotal: mem,
            memUsed: appPages * UInt64(page) + UInt64(vm.wire_count + vm.compressor_page_count) * UInt64(page),
            appMemory: appPages * UInt64(page),
            wired: UInt64(vm.wire_count) * UInt64(page),
            swapins: vm.swapins,
            swapouts: vm.swapouts,
            decompressions: vm.decompressions,
            pageSize: UInt64(page),
            thermal: ProcessInfo.processInfo.thermalState
        )
    }
}

/// What two samples say about how the Mac feels right now.
public struct Activity: Sendable {
    /// Bytes per second paged back in from swap: the thing you actually feel.
    public let swapInRate: Double
    public let swapOutRate: Double
    public let decompressRate: Double

    public init(from a: SystemSample, to b: SystemSample) {
        let dt = max(b.time - a.time, 0.001)
        func rate(_ x: UInt64, _ y: UInt64) -> Double {
            y >= x ? Double(y - x) * Double(b.pageSize) / dt : 0
        }
        swapInRate = rate(a.swapins, b.swapins)
        swapOutRate = rate(a.swapouts, b.swapouts)
        decompressRate = rate(a.decompressions, b.decompressions)
    }

    public init(swapInRate: Double, swapOutRate: Double, decompressRate: Double) {
        self.swapInRate = swapInRate; self.swapOutRate = swapOutRate; self.decompressRate = decompressRate
    }
}
