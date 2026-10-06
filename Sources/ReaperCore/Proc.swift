import Darwin
import Foundation

/// One process of the current user, read through libproc and sysctl.
public struct Proc: Sendable, Equatable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    /// Start time in microseconds since 1970. Together with the pid this
    /// identifies a process; the pid alone gets reused.
    public let start: UInt64
    /// Real executable path (proc_pidpath), not argv[0], which a process
    /// can set to anything.
    public let path: String
    public let args: [String]
    /// Environment at exec time. nil when the kernel refuses it
    /// (Apple platform binaries, other users).
    public let env: [String: String]?
    /// Activity Monitor's "Memory" column.
    public let footprint: UInt64
    /// User + system CPU time in nanoseconds.
    public let cpuNanos: UInt64

    public init(pid: pid_t, ppid: pid_t, uid: uid_t, start: UInt64, path: String,
                args: [String], env: [String: String]?, footprint: UInt64, cpuNanos: UInt64) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.start = start; self.path = path
        self.args = args; self.env = env; self.footprint = footprint; self.cpuNanos = cpuNanos
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public enum ProcReader {
    /// All processes of the current user. Processes that exit while being
    /// read are skipped. argv and environment cost a sysctl each, so they
    /// are only read where `argsFor` says so.
    public static func all(argsFor: (String) -> Bool = { _ in false }) -> [Proc] {
        let uid = getuid()
        return listPids().compactMap { pid in
            guard let p = read(pid: pid, args: false), p.uid == uid else { return nil }
            return argsFor(p.path) ? read(pid: pid, args: true) : p
        }
    }

    public static func listPids() -> [pid_t] {
        var capacity = Int(proc_listallpids(nil, 0)) + 64
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
            if n <= 0 { return [] }
            if n < capacity { return Array(pids.prefix(n)).filter { $0 > 0 } }
            capacity *= 2
        }
    }

    public static func read(pid: pid_t, args withArgs: Bool = true) -> Proc? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = pathLen > 0 ? String(cString: pathBuf) : ""

        var usage = rusage_info_v4()
        let usageOK = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }

        let (args, env) = withArgs ? procArgs(pid: pid) ?? ([], nil) : ([], nil)
        return Proc(
            pid: pid,
            ppid: pid_t(info.pbi_ppid),
            uid: info.pbi_uid,
            start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec),
            path: path,
            args: args,
            env: env,
            footprint: usageOK ? usage.ri_phys_footprint : 0,
            cpuNanos: usageOK ? machToNanos(usage.ri_user_time + usage.ri_system_time) : 0
        )
    }

    /// argv and environment via sysctl(KERN_PROCARGS2).
    static func procArgs(pid: pid_t) -> ([String], [String: String]?)? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: Int(argmax))
        size = buf.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    /// Layout: Int32 argc, exec path, NUL padding, argc strings, then
    /// environment strings up to the first empty one.
    static func parseProcArgs(_ buf: [UInt8]) -> ([String], [String: String]?)? {
        guard buf.count >= 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 } // exec path
        while i < buf.count, buf[i] == 0 { i += 1 } // padding

        func next() -> String? {
            guard i < buf.count else { return nil }
            let begin = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[begin..<i], as: UTF8.self)
            i += 1
            return s
        }

        var args: [String] = []
        for _ in 0..<argc {
            guard let a = next() else { return (args, nil) }
            args.append(a)
        }
        var env: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        // Platform binaries come back with argv but no environment.
        return (args, env.isEmpty ? nil : env)
    }

    /// rusage times are mach ticks; on Apple Silicon a tick is not 1 ns.
    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return ticks * UInt64(tb.numer) / UInt64(tb.denom)
    }
}
