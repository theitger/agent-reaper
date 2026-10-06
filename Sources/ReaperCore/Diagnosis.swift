import Foundation

/// Memory used by everything that belongs to one app: Chrome with its 40
/// helpers is one line, not 41.
public struct AppGroup: Sendable {
    public let name: String
    public let count: Int
    public let footprint: UInt64
    /// Path of the outermost .app bundle; nil for command-line tools.
    public let bundlePath: String?
    public let pids: [pid_t]

    public static func group(_ procs: [Proc]) -> [AppGroup] {
        var byName: [String: (bundle: String?, pids: [pid_t], footprint: UInt64)] = [:]
        for p in procs where !p.path.isEmpty {
            let key = scriptName(p) ?? appName(p.path)
            var g = byName[key] ?? (bundlePath(p.path), [], 0)
            g.pids.append(p.pid)
            g.footprint += p.footprint
            byName[key] = g
        }
        return byName.map {
            AppGroup(name: $0.key, count: $0.value.pids.count, footprint: $0.value.footprint,
                     bundlePath: $0.value.bundle, pids: $0.value.pids)
        }
        .sorted { $0.footprint > $1.footprint }
    }

    /// Runtimes whose processes say nothing by name: "node" could be a
    /// language server, an MCP server or a dev server.
    public static let interpreters: Set<String> = ["node", "bun", "deno", "python3", "python", "ruby"]

    /// "tsserver" for `node …/typescript/lib/tsserver.js --flags`. Needs argv,
    /// so interpreter processes must be read with args.
    static func scriptName(_ p: Proc) -> String? {
        guard interpreters.contains(p.name),
              let script = p.args.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        var name = (script as NSString).lastPathComponent
        for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"] where name.hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        // Generic entry points: the package directory says more.
        if ["index", "main", "cli", "server", "mcp", "bin"].contains(name) {
            let parts = script.split(separator: "/").map(String.init)
            if let i = parts.lastIndex(where: { !["dist", "lib", "build", "bin", "src", "out"].contains($0) && !$0.hasPrefix(name) }) {
                name = "\(parts[i]) \(name)"
            }
        }
        return "\(name) (\(p.name))"
    }

    static func bundlePath(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// The outermost .app bundle in the path, else the executable name.
    /// Claude Code installs as ~/.local/share/claude/versions/2.1.289, so a
    /// name that starts with a digit falls back to the directory above.
    static func appName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        guard let last = parts.last else { return path }
        if last.first?.isNumber == true, parts.count >= 3, parts[parts.count - 2] == "versions" {
            return String(parts[parts.count - 3])
        }
        return String(last)
    }
}

public enum Level: String, Sendable, Codable {
    case ok, tight, slow
}

/// The one sentence. Based on paging activity and kernel pressure, not on
/// how full swap is.
public struct Diagnosis: Sendable {
    public enum Cause: String, Sendable, Codable {
        case none, swapping, thermal, pressure
    }

    public let level: Level
    public let cause: Cause
    /// English, for the CLI. The app builds its own localized sentence
    /// from level and cause.
    public let headline: String

    // Starting values, to be calibrated against real days in dry-run.
    static let slowSwapIn: Double = 10 * 1_048_576
    static let tightSwapIn: Double = 1 * 1_048_576

    public static func make(sample: SystemSample, activity: Activity, orphans: [Leftover]) -> Diagnosis {
        let reclaim = orphans.reduce(0) { $0 + $1.proc.footprint }
        let browsers = orphans.filter { $0.kind == .agentBrowser }.count
        let tail = orphans.isEmpty ? "" :
            " Reclaimable: \(browsers) orphaned agent-browser, \(Format.bytes(reclaim))."

        let swapping = activity.swapInRate
        // Swap-in without pressure is recovery: memory was freed and macOS
        // fetches parked data back. Only with pressure does it mean stalls.
        let pressured = sample.pressure != .normal
        if sample.pressure == .critical || (pressured && swapping >= slowSwapIn) {
            return Diagnosis(level: .slow, cause: swapping >= slowSwapIn ? .swapping : .pressure,
                             headline: "Slow: memory overcommitted, swapping \(Format.rate(swapping))." + tail)
        }
        if sample.thermal == .serious || sample.thermal == .critical {
            return Diagnosis(level: .slow, cause: .thermal, headline: "Slow: thermal throttling." + tail)
        }
        if sample.pressure == .warning || swapping >= tightSwapIn {
            return Diagnosis(level: .tight, cause: swapping >= tightSwapIn ? .swapping : .pressure,
                             headline: "Memory tight." + tail)
        }
        return Diagnosis(level: .ok, cause: .none, headline: "All good." + tail)
    }
}

public enum Format {
    public static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    public static func rate(_ r: Double) -> String {
        String(format: "%.1f MB/s", r / 1_048_576)
    }

    public static func age(_ micros: UInt64) -> String {
        let s = micros / 1_000_000
        if s >= 86400 { return "\(s / 86400)d" }
        if s >= 3600 { return "\(s / 3600)h" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
