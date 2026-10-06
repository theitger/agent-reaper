import AppKit
import SwiftUI
import Darwin
import Foundation
import ReaperCore
import ServiceManagement

/// All processes of one agent-browser session: daemon, Chrome and helpers.
struct BrowserGroup: Identifiable {
    let id: String
    let name: String
    let status: Status
    let reason: String
    let leftovers: [Leftover]
    let footprint: UInt64

    var orphans: [Leftover] { leftovers.filter { $0.status == .orphan } }
}

/// Everything one agent session left running, however many browsers it
/// opened. Titled by the repository it worked in, not by a session id.
struct AgentGroup: Identifiable {
    let id: String
    let agent: Agent?
    let project: String
    let browsers: [BrowserGroup]
    let status: Status
    let footprint: UInt64
    let start: UInt64

    var orphans: [Leftover] { browsers.flatMap(\.orphans) }
    var processCount: Int { browsers.reduce(0) { $0 + $1.leftovers.count } }

    static func group(_ leftovers: [Leftover]) -> [AgentGroup] {
        let bySession = Dictionary(grouping: leftovers) { "\($0.agent?.rawValue ?? "-")/\($0.session ?? "-")" }
        return bySession.map { key, ls in
            let browsers = Dictionary(grouping: ls) { $0.proc.env?["AGENT_BROWSER_SESSION"] ?? "default" }
                .map { name, bls -> BrowserGroup in
                    let statuses = Set(bls.map(\.status))
                    let lead = bls.first { $0.kind == .agentBrowser } ?? bls[0]
                    return BrowserGroup(id: key + "/" + name, name: name, status: combined(statuses),
                                        reason: lead.reason, leftovers: bls,
                                        footprint: bls.reduce(0) { $0 + $1.proc.footprint })
                }
                .sorted { $0.footprint > $1.footprint }
            let pwd = ls.lazy.compactMap { $0.proc.env?["PWD"] }.first
            return AgentGroup(
                id: key,
                agent: ls[0].agent,
                project: pwd.map(repoName) ?? String(localized: "Unknown origin"),
                browsers: browsers,
                status: combined(Set(browsers.map(\.status))),
                footprint: browsers.reduce(0) { $0 + $1.footprint },
                start: ls.map(\.proc.start).min() ?? 0
            )
        }
        .sorted { ($0.status == .orphan ? 0 : 1, $1.footprint) < ($1.status == .orphan ? 0 : 1, $0.footprint) }
    }

    /// Anything alive keeps the whole group's badge on "active"; reaping
    /// still only ever touches the orphaned part.
    private static func combined(_ s: Set<Status>) -> Status {
        s.contains(.alive) ? .alive : s.contains(.orphan) ? .orphan : .unknown
    }

    private static var repoCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// The enclosing git checkout's folder name; the folder itself if none.
    static func repoName(_ pwd: String) -> String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = repoCache[pwd] { return hit }
        var dir = URL(fileURLWithPath: pwd)
        var name = dir.lastPathComponent
        while dir.path != "/" && dir.path != NSHomeDirectory() {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                name = dir.lastPathComponent
                break
            }
            dir.deleteLastPathComponent()
        }
        repoCache[pwd] = name
        return name
    }
}

struct Snapshot {
    var sample: SystemSample
    var activity: Activity
    var diagnosis: Diagnosis
    var sessions: [AgentGroup]
    var apps: [AppGroup]
    var allApps: [AppGroup]
    /// nil: no engine reachable.
    var docker: [DockerStack]?
    var processCount: Int
    var ownFootprint: UInt64
    var ownCPU: UInt64

    var orphans: [Leftover] { sessions.flatMap(\.orphans) }

    /// The VM that holds the containers' memory, as macOS sees it.
    var dockerVM: AppGroup? {
        allApps.first { $0.name == "OrbStack" || $0.name.hasPrefix("Docker") }
    }
}

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var ownCPUPercent: Double = 0
    /// Result of the last action, shown in the footer for a few seconds.
    @Published private(set) var lastAction: String?
    private var actionClear: Task<Void, Never>?

    private func report(_ text: String) {
        lastAction = text
        actionClear?.cancel()
        actionClear = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.ease) { self.lastAction = nil }
        }
    }
    @Published private(set) var busy: Set<String> = []
    /// CPU share per compose project, measured over at least `idleWindow`.
    @Published private(set) var dockerCPU: [String: Double] = [:]
    /// When each app (by bundle path) was last frontmost, since reaper started.
    @Published private(set) var lastActive: [String: Date] = [:]
    let launched = Date()

    @Published var autoReap: Bool {
        didSet { UserDefaults.standard.set(autoReap, forKey: "autoReap"); refresh() }
    }
    @Published var openAtLogin: Bool {
        didSet { if !syncingLogin { setOpenAtLogin(openAtLogin) } }
    }
    private var syncingLogin = false

    private var previous: (sample: SystemSample, cpu: UInt64, time: TimeInterval)?
    private var dockerBaseline: [String: (cpu: UInt64, time: TimeInterval)] = [:]
    private var lastDockerScan: TimeInterval = 0
    private var visible = false
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var loggedOrphans: Set<String> = []
    private var scanning = false

    /// Rare refresh while closed; the pressure source wakes us when it matters.
    private let idleInterval: TimeInterval = 60
    private let openInterval: TimeInterval = 2
    private let idleWindow: TimeInterval = 30
    nonisolated static let appThreshold: UInt64 = 200 * 1_048_576

    private init() {
        autoReap = UserDefaults.standard.bool(forKey: "autoReap")
        openAtLogin = SMAppService.mainApp.status == .enabled

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        source.resume()
        pressureSource = source

        if let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path {
            lastActive[front] = Date()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let path = app?.bundleURL?.path else { return }
            MainActor.assumeIsolated { self?.lastActive[path] = Date() }
        }

        schedule(idleInterval)
        refresh()
    }

    func setSnapshotForRendering(_ snap: Snapshot) { snapshot = snap }

    func panelVisible(_ visible: Bool) {
        self.visible = visible
        schedule(visible ? openInterval : idleInterval)
        if visible { refresh() }
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let prev = previous
        let now = Date().timeIntervalSince1970
        // Docker costs a request per container; every 6 s is plenty.
        let withDocker = now - lastDockerScan >= (visible ? 6 : idleInterval - 5)
        if withDocker { lastDockerScan = now }
        let keptDocker = snapshot?.docker
        Task.detached(priority: .utility) {
            var fresh = Self.scan(previous: prev?.sample, withDocker: withDocker)
            if !withDocker { fresh.docker = keptDocker }
            let snap = fresh
            await MainActor.run { self.apply(snap, dockerFresh: withDocker) }
        }
    }

    private func apply(_ snap: Snapshot, dockerFresh: Bool) {
        let now = Date().timeIntervalSince1970
        if let p = previous, snap.ownCPU >= p.cpu, now > p.time {
            ownCPUPercent = Double(snap.ownCPU - p.cpu) / 1e9 / (now - p.time) * 100
        }
        previous = (snap.sample, snap.ownCPU, now)
        if dockerFresh, let stacks = snap.docker { updateDockerCPU(stacks, now: now) }
        snapshot = snap
        scanning = false

        let orphans = snap.orphans
        if autoReap, !orphans.isEmpty {
            reap(orphans)
        } else {
            logWouldReap(orphans)
        }
    }

    /// CPU share since a baseline at least `idleWindow` old. Short windows
    /// would call a stack idle between two requests.
    private func updateDockerCPU(_ stacks: [DockerStack], now: TimeInterval) {
        var cpu = dockerCPU
        for s in stacks {
            guard let base = dockerBaseline[s.id], s.cpuNanos >= base.cpu else {
                dockerBaseline[s.id] = (s.cpuNanos, now)
                continue
            }
            let dt = now - base.time
            guard dt >= idleWindow else { continue }
            cpu[s.id] = Double(s.cpuNanos - base.cpu) / 1e9 / dt * 100
            dockerBaseline[s.id] = (s.cpuNanos, now)
        }
        let live = Set(stacks.map(\.id))
        dockerCPU = cpu.filter { live.contains($0.key) }
        dockerBaseline = dockerBaseline.filter { live.contains($0.key) }
    }

    nonisolated static func scan(previous: SystemSample?, withDocker: Bool = true) -> Snapshot {
        let sample = SystemSample.now()
        let activity = previous.map { Activity(from: $0, to: sample) }
            ?? Activity(swapInRate: 0, swapOutRate: 0, decompressRate: 0)
        let procs = ProcReader.all {
            LeftoverKind.of(path: $0) != nil || AppGroup.interpreters.contains(($0 as NSString).lastPathComponent)
        }
        let leftovers = LeftoverFinder().find(in: procs)
        let orphans = leftovers.filter { $0.status == .orphan }
        let me = ProcReader.read(pid: getpid(), args: false)
        let apps = AppGroup.group(procs)
        let agentBrowsers = NSHomeDirectory() + "/.agent-browser/"
        // Agent Chrome is listed under leftovers already. The Docker VM stays
        // here too: it is an app you may want to quit as a whole.
        let listed = apps.filter { a in
            a.footprint >= appThreshold && !(a.bundlePath?.hasPrefix(agentBrowsers) ?? false)
        }
        return Snapshot(
            sample: sample,
            activity: activity,
            diagnosis: Diagnosis.make(sample: sample, activity: activity, orphans: orphans),
            sessions: AgentGroup.group(leftovers),
            apps: Array(listed.prefix(8)),
            allApps: apps,
            docker: withDocker ? Docker.stacks() : nil,
            processCount: procs.count,
            ownFootprint: me?.footprint ?? 0,
            ownCPU: me?.cpuNanos ?? 0
        )
    }

    // MARK: Actions

    func reap(_ leftovers: [Leftover]) {
        let ordered = Reaper.order(leftovers)
        let total = ordered.reduce(0) { $0 + $1.proc.footprint }
        Task.detached(priority: .userInitiated) {
            for l in ordered where Reaper.isSame(l.proc) {
                let result = Reaper.reap(l.proc)
                Log.write("reaped \(l.proc.pid) \(l.kind.rawValue) [\(l.reason)] -> \(result)")
            }
            let gone = ordered.filter { !Reaper.isSame($0.proc) }.count
            await MainActor.run {
                self.report(String(localized: "Reaped \(gone) procs · \(Format.bytes(total))"))
                self.refresh()
            }
        }
    }

    /// The running GUI app behind a group, if reaper may quit it.
    func runningApp(for group: AppGroup) -> NSRunningApplication? {
        guard let path = group.bundlePath else { return nil }
        let protected: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
                                      Bundle.main.bundleIdentifier ?? "-"]
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == path && !protected.contains($0.bundleIdentifier ?? "")
        }
    }

    /// Asks the app to quit like ⌘Q would (it may show a save dialog), then
    /// reports the memory that actually disappeared.
    func quit(_ group: AppGroup) {
        guard let app = runningApp(for: group) else { return }
        let pids = Set(group.pids)
        busy.insert(group.name)
        app.terminate()
        Log.write("quit \(group.name) \(Format.bytes(group.footprint))")
        Task { @MainActor in
            for _ in 0..<30 where !app.isTerminated {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let left = await Task.detached { ProcReader.all().filter { pids.contains($0.pid) } }.value
            let remaining = left.reduce(0) { $0 + $1.footprint }
            let released = group.footprint - min(group.footprint, remaining)
            report(app.isTerminated
                ? String(localized: "Quit \(group.name) · \(Format.bytes(released)) released")
                : String(localized: "\(group.name) did not quit (open dialog?)"))
            busy.remove(group.name)
            refresh()
        }
    }

    /// Stops a compose stack, then measures what the VM gave back to macOS:
    /// containers can stop without the VM returning a byte.
    func stop(_ stack: DockerStack) {
        let vmBefore = snapshot?.dockerVM
        busy.insert(stack.id)
        Log.write("stop docker \(stack.id) \(Format.bytes(stack.memory))")
        Task.detached(priority: .userInitiated) {
            Docker.stop(stack)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let after = Self.scan(previous: nil, withDocker: false)
            await MainActor.run {
                var text = String(localized: "Stopped \(stack.id)")
                if let before = vmBefore, let now = after.dockerVM {
                    text += " · " + (before.footprint > now.footprint + 50 * 1_048_576
                        ? String(localized: "\(now.name) −\(Format.bytes(before.footprint - now.footprint))")
                        : String(localized: "\(now.name) kept its memory so far"))
                }
                self.report(text)
                self.busy.remove(stack.id)
                self.lastDockerScan = 0
                self.refresh()
            }
        }
    }

    /// Dry run: every orphan is logged once, so a day of "would have reaped"
    /// can be checked against what really happened before auto-reap goes on.
    private func logWouldReap(_ orphans: [Leftover]) {
        for l in orphans {
            let key = "\(l.proc.pid)/\(l.proc.start)"
            guard loggedOrphans.insert(key).inserted else { continue }
            Log.write("would reap \(l.proc.pid) \(l.kind.rawValue) \(Format.bytes(l.proc.footprint)) [\(l.reason)] \(l.agent?.rawValue ?? "no agent") session=\(l.session ?? "-")")
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("open at login: \(error.localizedDescription)")
        }
        // Show what the system did, not what was asked for.
        syncingLogin = true
        openAtLogin = SMAppService.mainApp.status == .enabled
        syncingLogin = false
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Reaper.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
