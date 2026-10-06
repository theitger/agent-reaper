import Darwin
import Foundation
import ReaperCore

let usage = """
usage: reaper status            why the Mac is slow, in one line
       reaper ls [--json]       agent leftovers and their verdict
       reaper reap [--yes]      reap orphans (dry run without --yes)
       reaper docker            running compose stacks and their memory
"""

let args = Array(CommandLine.arguments.dropFirst())
let flags = Set(args.filter { $0.hasPrefix("--") })
let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)

func line(_ l: Leftover) -> String {
    let p = l.proc
    let age = Format.age(now > p.start ? now - p.start : 0)
    return String(format: "%-7@ %7d %6@ %8@  %-20@  %@",
                  l.status.rawValue, p.pid, age, Format.bytes(p.footprint),
                  l.kind.rawValue, l.reason)
}

func wanted(_ path: String) -> Bool {
    LeftoverKind.of(path: path) != nil || AppGroup.interpreters.contains((path as NSString).lastPathComponent)
}

func ownFootprint() -> String {
    let me = ProcReader.read(pid: getpid(), args: false)
    return "reaper · \(Format.bytes(me?.footprint ?? 0))"
}

switch args.first {
case "status":
    let a = SystemSample.now()
    usleep(1_000_000)
    let b = SystemSample.now()
    let procs = ProcReader.all(argsFor: wanted)
    let orphans = LeftoverFinder().find(in: procs).filter { $0.status == .orphan }
    let activity = Activity(from: a, to: b)
    print(Diagnosis.make(sample: b, activity: activity, orphans: orphans).headline)
    print("")
    print("pressure  \(b.pressure)   swap-in \(Format.rate(activity.swapInRate))   swap-out \(Format.rate(activity.swapOutRate))")
    print("memory    \(Format.bytes(b.memUsed)) / \(Format.bytes(b.memTotal))")
    print("swap      \(Format.bytes(b.swapUsed)) / \(Format.bytes(b.swapTotal))   compressed \(Format.bytes(b.compressed))   thermal \(["nominal", "fair", "serious", "critical"][b.thermal.rawValue])")
    print("")
    for g in AppGroup.group(procs).prefix(8) {
        print(String(format: "%9@  %4d  %@", Format.bytes(g.footprint), g.count, g.name))
    }
    print("\n\(procs.count) own processes · \(ownFootprint())")

case "ls":
    let leftovers = LeftoverFinder().find(in: ProcReader.all(argsFor: wanted))
    if flags.contains("--json") {
        let rows = leftovers.map { l -> [String: Any] in
            ["pid": l.proc.pid, "status": l.status.rawValue, "kind": l.kind.rawValue,
             "reason": l.reason, "footprint": l.proc.footprint, "start": l.proc.start,
             "session": l.session ?? NSNull(), "agent": l.agent?.rawValue ?? NSNull(), "path": l.proc.path]
        }
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else if leftovers.isEmpty {
        print("No agent leftovers.")
    } else {
        leftovers.sorted { $0.proc.pid < $1.proc.pid }.forEach { print(line($0)) }
    }

case "reap":
    let orphans = Reaper.order(LeftoverFinder().find(in: ProcReader.all(argsFor: wanted)).filter { $0.status == .orphan })
    let total = orphans.reduce(0) { $0 + $1.proc.footprint }
    guard !orphans.isEmpty else { print("Nothing to reap."); exit(0) }
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard flags.contains("--yes") else {
        print("\(stamp) dry run: would reap \(orphans.count) procs, \(Format.bytes(total))")
        orphans.forEach { print("  " + line($0)) }
        exit(0)
    }
    for l in orphans {
        // Helpers usually die with their parent before their turn comes.
        guard Reaper.isSame(l.proc) else { continue }
        print("  \(Reaper.reap(l.proc))  " + line(l))
    }
    let done = orphans.filter { !Reaper.isSame($0.proc) }.count
    print("\(stamp) reaped \(done)/\(orphans.count) procs, ~\(Format.bytes(total))")

case "docker":
    guard let stacks = Docker.stacks() else { print("No Docker engine reachable."); exit(1) }
    for s in stacks {
        let age = Format.age(UInt64(max(0, Date().timeIntervalSince1970 - s.created)) * 1_000_000)
        print(String(format: "%9@  %2d  %5@  %@", Format.bytes(s.memory), s.containerIDs.count, age, s.id))
    }

default:
    print(usage)
    exit(args.isEmpty || flags.contains("--help") ? 0 : 64)
}
