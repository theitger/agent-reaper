import Darwin
import Foundation

/// What a leftover is. Matched on the real executable path only, never on
/// the command line: a shell whose arguments mention "agent-browser" must
/// never match.
public enum LeftoverKind: String, Sendable, Codable {
    case agentBrowser = "agent-browser"
    case agentBrowserChrome = "agent-browser chrome"

    public static func of(path: String, home: String = NSHomeDirectory()) -> LeftoverKind? {
        let name = (path as NSString).lastPathComponent
        if name == "agent-browser" || name.hasPrefix("agent-browser-darwin-") {
            return .agentBrowser
        }
        if path.hasPrefix(home + "/.agent-browser/browsers/") {
            return .agentBrowserChrome
        }
        return nil
    }
}

public enum Status: String, Sendable, Codable {
    /// Hard evidence it is abandoned. Gets reaped.
    case orphan
    /// Its session is still running. Hands off.
    case alive
    /// No evidence either way yet. Shown, not touched.
    case unknown
}

public struct Leftover: Sendable {
    public let proc: Proc
    public let kind: LeftoverKind
    public let status: Status
    public let reason: String
    /// CLAUDE_CODE_SESSION_ID of the session that started it, if known.
    public let session: String?
}

public struct LeftoverFinder {
    public var home: String
    public var now: UInt64
    /// Fallback when there is no session to ask: same limit as the old
    /// launchd script, so arming the app never reaps more than it did.
    public var maxAge: UInt64 = 3 * 3600 * 1_000_000
    /// Whether `pid` is still the process that existed when `childStart`
    /// began. A reused pid started later and does not count.
    public var isAlive: (pid_t, UInt64) -> Bool

    public init(home: String = NSHomeDirectory(),
                now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000_000),
                isAlive: @escaping (pid_t, UInt64) -> Bool = LeftoverFinder.liveCheck) {
        self.home = home
        self.now = now
        self.isAlive = isAlive
    }

    public static func liveCheck(pid: pid_t, childStart: UInt64) -> Bool {
        guard let p = ProcReader.read(pid: pid, args: false), p.uid == getuid() else { return false }
        return p.start <= childStart
    }

    public func find(in procs: [Proc]) -> [Leftover] {
        let agentRunning = procs.contains { $0.name == "claude" }
        return procs.compactMap { p in
            guard let kind = LeftoverKind.of(path: p.path, home: home) else { return nil }
            let (status, reason) = judge(p, agentRunning: agentRunning)
            return Leftover(proc: p, kind: kind, status: status, reason: reason,
                            session: p.env?["CLAUDE_CODE_SESSION_ID"])
        }
    }

    func judge(_ p: Proc, agentRunning: Bool) -> (Status, String) {
        let old = now > p.start && now - p.start >= maxAge
        let ageNote = "older than \(maxAge / 3_600_000_000)h"

        guard let owner = p.env?["CLAUDE_PID"].flatMap({ pid_t($0) }) else {
            return old ? (.orphan, "no session info, \(ageNote)") : (.unknown, "no session info")
        }
        if isAlive(owner, p.start) {
            return (.alive, "session alive (claude \(owner))")
        }
        // agent-browser's "default" session is one daemon for everyone:
        // whoever started it is in its environment, but a second session may
        // be using it now.
        let browserSession = p.env?["AGENT_BROWSER_SESSION"] ?? "default"
        if browserSession != "default" || !agentRunning {
            return (.orphan, "session ended")
        }
        return old
            ? (.orphan, "session ended, shared 'default' daemon \(ageNote)")
            : (.unknown, "session ended, but the shared 'default' daemon may serve another session")
    }
}
