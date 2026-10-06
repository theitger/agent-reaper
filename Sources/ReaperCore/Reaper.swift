import Darwin
import Foundation

public enum ReapResult: Sendable, Equatable {
    case terminated, killed
    /// The pid now belongs to a different process, or it is already gone.
    case skipped(String)
    case failed(Int32)
}

public enum Reaper {
    /// SIGTERM, wait, SIGKILL. Before every signal the pid is re-read and
    /// must still be the same process: same start time, same executable.
    public static func reap(_ target: Proc, grace: TimeInterval = 3) -> ReapResult {
        guard target.pid > 1, target.pid != getpid(), target.uid == getuid() else {
            return .skipped("not ours")
        }
        guard isSame(target) else { return .skipped("gone or pid reused") }
        if kill(target.pid, SIGTERM) != 0 { return errno == ESRCH ? .skipped("gone") : .failed(errno) }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !isSame(target) { return .terminated }
            usleep(100_000)
        }
        guard isSame(target) else { return .terminated }
        if kill(target.pid, SIGKILL) != 0 { return errno == ESRCH ? .terminated : .failed(errno) }
        return .killed
    }

    public static func isSame(_ p: Proc) -> Bool {
        guard let now = ProcReader.read(pid: p.pid, args: false) else { return false }
        return now.start == p.start && now.path == p.path && now.uid == p.uid
    }

    /// Kill order: daemons first, then browser roots, helpers last, so
    /// parents take their children with them and fewer signals are needed.
    public static func order(_ leftovers: [Leftover]) -> [Leftover] {
        let pids = Set(leftovers.map(\.proc.pid))
        func rank(_ l: Leftover) -> Int {
            if l.kind == .agentBrowser { return 0 }
            return pids.contains(l.proc.ppid) ? 2 : 1
        }
        return leftovers.sorted { (rank($0), $0.proc.pid) < (rank($1), $1.proc.pid) }
    }
}
