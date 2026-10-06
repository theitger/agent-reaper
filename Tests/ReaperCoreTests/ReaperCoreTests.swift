import XCTest
@testable import ReaperCore

final class ProcArgsTests: XCTestCase {
    func bytes(argc: Int32, exec: String, args: [String], env: [String]) -> [UInt8] {
        var b = withUnsafeBytes(of: argc) { Array($0) }
        b += Array(exec.utf8) + [0, 0, 0]
        for s in args + env { b += Array(s.utf8) + [0] }
        return b + [0]
    }

    func testParsesArgsAndEnv() {
        let buf = bytes(argc: 2, exec: "/bin/x", args: ["/bin/x", "-v"],
                        env: ["CLAUDE_PID=42", "A=b=c"])
        let (args, env) = ProcReader.parseProcArgs(buf)!
        XCTAssertEqual(args, ["/bin/x", "-v"])
        XCTAssertEqual(env?["CLAUDE_PID"], "42")
        XCTAssertEqual(env?["A"], "b=c")
    }

    func testNoEnvIsNil() {
        let (args, env) = ProcReader.parseProcArgs(bytes(argc: 1, exec: "/bin/sleep", args: ["sleep"], env: []))!
        XCTAssertEqual(args, ["sleep"])
        XCTAssertNil(env)
    }

    func testReadsOwnProcess() {
        let me = ProcReader.read(pid: getpid())
        XCTAssertNotNil(me)
        XCTAssertGreaterThan(me!.footprint, 0)
        XCTAssertFalse(me!.path.isEmpty)
    }
}

final class LeftoverTests: XCTestCase {
    let home = "/Users/t"
    let hour: UInt64 = 3600 * 1_000_000
    let now: UInt64 = 1_000_000 * 1_000_000

    func proc(_ path: String, env: [String: String]?, ageHours: UInt64 = 0, pid: pid_t = 100) -> Proc {
        Proc(pid: pid, ppid: 1, uid: getuid(), start: now - ageHours * hour, path: path,
             args: [path], env: env, footprint: 1, cpuNanos: 0)
    }

    func finder(alive: Set<pid_t>) -> LeftoverFinder {
        LeftoverFinder(home: home, now: now) { pid, _ in alive.contains(pid) }
    }

    let daemon = "/Users/t/.npm-global/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64"
    let chrome = "/Users/t/.agent-browser/browsers/chrome-154/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    let claude = Proc(pid: 7, ppid: 1, uid: getuid(), start: 0, path: "/x/claude", args: [], env: nil, footprint: 0, cpuNanos: 0)

    func testShellMentioningAgentBrowserIsIgnored() {
        let shell = Proc(pid: 5, ppid: 1, uid: getuid(), start: 0, path: "/bin/zsh",
                         args: ["zsh", "-c", "agent-browser open"], env: nil, footprint: 0, cpuNanos: 0)
        XCTAssertTrue(finder(alive: []).find(in: [shell]).isEmpty)
    }

    func testLiveSessionIsAlive() {
        let p = proc(daemon, env: ["CLAUDE_PID": "7", "AGENT_BROWSER_SESSION": "x"], ageHours: 100)
        XCTAssertEqual(finder(alive: [7]).find(in: [p]).first?.status, .alive)
    }

    func testDeadNamedSessionIsOrphan() {
        let p = proc(chrome, env: ["CLAUDE_PID": "7", "AGENT_BROWSER_SESSION": "x"])
        let l = finder(alive: []).find(in: [p, claude]).first!
        XCTAssertEqual(l.kind, .agentBrowserChrome)
        XCTAssertEqual(l.status, .orphan)
    }

    func testDeadDefaultSessionWaitsWhileAnotherAgentRuns() {
        let young = proc(daemon, env: ["CLAUDE_PID": "9"], ageHours: 1)
        let old = proc(daemon, env: ["CLAUDE_PID": "9"], ageHours: 4)
        let f = finder(alive: [7])
        XCTAssertEqual(f.find(in: [young, claude]).first?.status, .unknown)
        XCTAssertEqual(f.find(in: [old, claude]).first?.status, .orphan)
        // No agent at all: nobody can be using it.
        XCTAssertEqual(f.find(in: [young]).first?.status, .orphan)
    }

    func testCodexOwnerWinsOverInheritedClaude() {
        let id = "01a11194-ed21-7573-a5f2-42c8b41fbddf"
        let env = ["CLAUDE_PID": "7", "CODEX_SESSION_ID": id, "AGENT_BROWSER_SESSION": "x"]
        let created = LeftoverFinder.uuidV7Micros(id)!
        let codex = Proc(pid: 50, ppid: 1, uid: getuid(), start: created - 1_000_000, path: "/opt/homebrew/bin/codex",
                         args: [], env: nil, footprint: 0, cpuNanos: 0)
        // Claude (7) is alive, but the browser belongs to Codex.
        let f = finder(alive: [7])
        let l = f.find(in: [proc(daemon, env: env), codex]).first!
        XCTAssertEqual(l.agent, .codex)
        XCTAssertEqual(l.status, .alive)
        // Codex gone: orphan, even though Claude still runs.
        XCTAssertEqual(f.find(in: [proc(daemon, env: env)]).first?.status, .orphan)
        // Another, older codex process: could be a resume, so hands off.
        let older = Proc(pid: 51, ppid: 1, uid: getuid(), start: created - 3_600_000_000, path: "/opt/homebrew/bin/codex",
                         args: [], env: nil, footprint: 0, cpuNanos: 0)
        XCTAssertEqual(f.find(in: [proc(daemon, env: env), older]).first?.status, .unknown)
    }

    func testUUIDv7Time() {
        XCTAssertEqual(LeftoverFinder.uuidV7Micros("01a11194-ed21-7573-a5f2-42c8b41fbddf"), 0x01a11194ed21 * 1000)
        XCTAssertNil(LeftoverFinder.uuidV7Micros("9aaac636-2dbe-443f-9c8f-ee15fc29528c"))
    }

    func testNoEnvFallsBackToAge() {
        let f = finder(alive: [])
        XCTAssertEqual(f.find(in: [proc(daemon, env: nil, ageHours: 1)]).first?.status, .unknown)
        XCTAssertEqual(f.find(in: [proc(daemon, env: nil, ageHours: 4)]).first?.status, .orphan)
    }
}

final class DiagnosisTests: XCTestCase {
    func testAppGrouping() {
        XCTAssertEqual(AppGroup.appName("/A/Google Chrome for Testing.app/Contents/Frameworks/H.app/Contents/MacOS/H"),
                       "Google Chrome for Testing")
        XCTAssertEqual(AppGroup.appName("/usr/local/bin/node"), "node")
        XCTAssertEqual(AppGroup.appName("/Users/t/.local/share/claude/versions/2.1.289"), "claude")
        XCTAssertEqual(AppGroup.bundlePath("/Applications/Slack.app/Contents/Frameworks/H.app/Contents/MacOS/H"),
                       "/Applications/Slack.app")
        XCTAssertNil(AppGroup.bundlePath("/usr/local/bin/node"))
    }

    func testInterpreterGroupsByScript() {
        func node(_ args: [String]) -> Proc {
            Proc(pid: 1, ppid: 1, uid: 0, start: 0, path: "/nix/store/x/bin/node", args: args, env: nil, footprint: 0, cpuNanos: 0)
        }
        XCTAssertEqual(AppGroup.scriptName(node(["node", "frontend/node_modules/typescript/lib/tsserver.js", "--x"])), "tsserver (node)")
        XCTAssertEqual(AppGroup.scriptName(node(["node", "/Users/t/lernspiegel/dist/mcp.js"])), "lernspiegel mcp (node)")
        XCTAssertNil(AppGroup.scriptName(node([])))
    }

    func testRecoverySwapInIsNotSlow() {
        let s = SystemSample(time: 0, pressure: .normal, swapUsed: 0, swapTotal: 0, compressed: 0, memTotal: 1,
                             memUsed: 0, appMemory: 0, wired: 0, swapins: 0, swapouts: 0, decompressions: 0,
                             pageSize: 16384, thermal: .nominal)
        let a = Activity(swapInRate: 30 * 1_048_576, swapOutRate: 0, decompressRate: 0)
        XCTAssertNotEqual(Diagnosis.make(sample: s, activity: a, orphans: []).level, .slow)
    }

    func testDockerStatsSubtractsPageCache() {
        let s: [String: Any] = ["memory_stats": ["usage": 100, "stats": ["inactive_file": 30]],
                                "cpu_stats": ["cpu_usage": ["total_usage": 7]]]
        let r = Docker.parseStats(s)
        XCTAssertEqual(r.memory, 70)
        XCTAssertEqual(r.cpu, 7)
    }

    func testDechunk() {
        let raw = Data("4\r\n[1,2\r\n2\r\n,3\r\n1\r\n]\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(String(decoding: Docker.dechunk(raw), as: UTF8.self), "[1,2,3]")
    }
}
