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

/// The coding agent whose session started a process.
public enum Agent: String, Sendable, Codable {
    case claude = "Claude"
    case codex = "Codex"

    /// The innermost agent wins: Codex started from a Claude shell inherits
    /// CLAUDE_PID, but the browser belongs to the Codex session.
    static func owner(of env: [String: String]?) -> (Agent, String?)? {
        if let id = env?["CODEX_SESSION_ID"] { return (.codex, id) }
        if env?["CLAUDE_PID"] != nil { return (.claude, env?["CLAUDE_CODE_SESSION_ID"]) }
        return nil
    }
}

public struct Leftover: Sendable {
    public let proc: Proc
    public let kind: LeftoverKind
    public let status: Status
    public let reason: String
    public let agent: Agent?
    /// The agent's session id (CLAUDE_CODE_SESSION_ID or CODEX_SESSION_ID).
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
        let codexStarts = procs.filter { $0.name == "codex" || $0.name.hasPrefix("codex-") }.map(\.start)
        return procs.compactMap { p in
            guard let kind = LeftoverKind.of(path: p.path, home: home) else { return nil }
            let owner = Agent.owner(of: p.env)
            let (status, reason) = owner?.0 == .codex
                ? judgeCodex(session: owner?.1, codexStarts: codexStarts)
                : judge(p, agentRunning: agentRunning)
            return Leftover(proc: p, kind: kind, status: status, reason: reason,
                            agent: owner?.0, session: owner?.1)
        }
    }

    /// Codex puts no PID into the environment, only CODEX_SESSION_ID, a
    /// UUIDv7 whose first 48 bits are its creation time in ms. A session can
    /// only live inside a codex process; `codex resume` reopens an old id in
    /// a new process, so a mismatch in time is never proof of death.
    func judgeCodex(session: String?, codexStarts: [UInt64]) -> (Status, String) {
        if codexStarts.isEmpty { return (.orphan, "codex session ended (no codex running)") }
        guard let created = session.flatMap(Self.uuidV7Micros) else {
            return (.unknown, "codex running, session not identifiable")
        }
        // The process that opened the session starts a moment before it.
        if codexStarts.contains(where: { $0 <= created + 2_000_000 && created - min(created, $0) <= 120_000_000 }) {
            return (.alive, "codex session alive")
        }
        return (.unknown, "another codex process is running; it may have resumed this session")
    }

    /// Creation time in µs from a UUIDv7 string, nil if it is not one.
    static func uuidV7Micros(_ id: String) -> UInt64? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let ms = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return ms * 1000
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
