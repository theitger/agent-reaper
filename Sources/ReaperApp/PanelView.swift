import ReaperCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snap = monitor.snapshot {
                Header(snap: snap, monitor: monitor)
                Divider().overlay(Theme.hairline)
                Leftovers(snap: snap, monitor: monitor)
                Divider().overlay(Theme.hairline)
                if let stacks = snap.docker {
                    DockerSection(stacks: stacks, vm: snap.dockerVM, monitor: monitor)
                    Divider().overlay(Theme.hairline)
                }
                Memory(snap: snap, monitor: monitor)
                Divider().overlay(Theme.hairline)
                Footer(snap: snap, monitor: monitor)
            } else {
                Text("Reading…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .padding(16)
            }
        }
        .frame(width: 340)
        .onAppear { monitor.panelVisible(true) }
        .onDisappear { monitor.panelVisible(false) }
    }
}

private struct SectionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(Theme.textDim)
    }
}

private struct Header: View {
    let snap: Snapshot
    @ObservedObject var monitor: Monitor

    private var headroom: UInt64 {
        snap.sample.memTotal > snap.sample.memUsed ? snap.sample.memTotal - snap.sample.memUsed : 0
    }

    /// Numbers, not a mood: how much room is left and whether macOS is
    /// paging data back in.
    private var headline: String {
        String(localized: "\(Format.bytes(headroom)) available")
    }

    /// Only what is actually happening, as plain facts. Nothing when calm.
    private var qualifiers: [String] {
        var q: [String] = []
        if snap.diagnosis.cause == .thermal { q.append(String(localized: "CPU throttled")) }
        if snap.sample.pressure != .normal { q.append(String(localized: "memory pressure")) }
        let rate = snap.activity.swapInRate
        if rate >= 1_048_576 { q.append(String(localized: "swap-in \(Format.rate(rate))")) }
        return q
    }

    private var tone: Theme.Tone {
        switch snap.diagnosis.level {
        case .ok: return Theme.greenTone
        case .tight: return Theme.yellow
        case .slow: return Theme.redTone
        }
    }

    private var explanation: String {
        let d = snap.diagnosis
        let verdict: String
        switch (d.level, d.cause) {
        case (.ok, _):
            verdict = String(localized: "No memory pressure and nothing is being read back from swap. The Mac has room.")
        case (.slow, .thermal):
            verdict = String(localized: "The Mac is hot and slows the CPU down to cool off.")
        case (.slow, _):
            verdict = String(localized: "Memory is overbooked: macOS keeps moving data to disk and back. Apps stall while it does.")
        case (.tight, _):
            verdict = String(localized: "macOS reports memory pressure or reads data back from swap. Short stalls are possible.")
        }
        let pressure: String
        switch snap.sample.pressure {
        case .normal: pressure = String(localized: "pressure normal")
        case .warning: pressure = String(localized: "pressure warning")
        case .critical: pressure = String(localized: "pressure critical")
        }
        return verdict + "\n\n" + String(localized: "Available: RAM not used by apps, wired or compressed memory.\nSwap-in: data read back from disk per second. This is what you feel.") + "\n" + pressure
    }

    /// What one click could give back right now.
    private var freeable: String? {
        var parts: [String] = []
        let orphans = snap.sessions.flatMap(\.browsers).filter { $0.status == .orphan }
        if !orphans.isEmpty {
            let bytes = orphans.reduce(0) { $0 + $1.footprint }
            parts.append(String(localized: "\(orphans.count) orphaned browsers \(Format.bytes(bytes))"))
        }
        let idle = (snap.docker ?? []).filter { (monitor.dockerCPU[$0.id] ?? 100) < 0.5 }
        if !idle.isEmpty {
            let bytes = idle.reduce(0) { $0 + $1.memory }
            parts.append(String(localized: "\(idle.count) idle stacks \(Format.bytes(bytes))"))
        }
        return parts.isEmpty ? nil : String(localized: "Can be freed: \(parts.joined(separator: " · "))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(tone.strong).frame(width: 7, height: 7)
                (Text(verbatim: headline).foregroundColor(Theme.textPrimary)
                    + Text(verbatim: qualifiers.map { " · " + $0 }.joined())
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            .help(explanation)
            MeterRow(label: String(localized: "RAM"), used: snap.sample.memUsed, total: snap.sample.memTotal)
                .help(String(localized: "Memory used, counted like Activity Monitor (file cache left out):\napps \(Format.bytes(snap.sample.appMemory)) · wired \(Format.bytes(snap.sample.wired)) · compressed \(Format.bytes(snap.sample.compressed))\nA lot of compressed memory means macOS is already squeezing."))
            MeterRow(label: String(localized: "Swap"), used: snap.sample.swapUsed, total: nil)
                .help(String(localized: "Data parked on disk. macOS adds swap files only when needed, so there is no meaningful total. A full swap alone is harmless; reading it back is what you feel."))
            if let freeable {
                Text(verbatim: freeable)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct Leftovers: View {
    let snap: Snapshot
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "Started by agents")
                    .help(String(localized: "What coding agents started and left running (for now agent-browser and its Chrome), grouped by the agent session. The agents themselves are listed under Apps. Orphaned means the session has ended."))
                Spacer()
                let orphans = snap.orphans
                if !orphans.isEmpty {
                    QuietButton(title: "Reap all · \(Format.bytes(orphans.reduce(0) { $0 + $1.proc.footprint }))") {
                        monitor.reap(orphans)
                    }
                }
            }
            if snap.sessions.isEmpty {
                Text("None.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            } else {
                ForEach(snap.sessions) { AgentRow(group: $0, monitor: monitor) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private func statusBadge(_ status: Status) -> (String, Theme.Tone, String) {
    switch status {
    case .orphan:
        return (String(localized: "orphaned"), Theme.orange,
                String(localized: "Its agent session has ended. Safe to reap."))
    case .alive:
        return (String(localized: "active"), Theme.greenTone,
                String(localized: "Its agent session is still running. Hands off."))
    case .unknown:
        return (String(localized: "unclear"), Theme.neutral,
                String(localized: "No proof yet that it is abandoned. Shown, not touched."))
    }
}

/// One agent session: repository, agent, browsers. Click to see each browser.
private struct AgentRow: View {
    let group: AgentGroup
    @ObservedObject var monitor: Monitor
    @State private var hover = false
    @State private var expanded = false

    var body: some View {
        let badge = statusBadge(group.status)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: group.project)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let agent = group.agent {
                            Text(verbatim: agent.rawValue)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(verbatim: detail)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                Spacer(minLength: 8)
                if hover, !group.orphans.isEmpty {
                    QuietButton(title: "Reap") { monitor.reap(group.orphans) }
                } else {
                    Badge(text: badge.0, tone: badge.1)
                }
            }
            if expanded {
                ForEach(group.browsers) { b in
                    HStack(spacing: 8) {
                        Text(verbatim: b.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textBody)
                        Text(verbatim: String(localized: "\(b.leftovers.count) procs"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Text(verbatim: Format.bytes(b.footprint))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .monospacedDigit()
                    .padding(.leading, 12)
                    .help(statusBadge(b.status).2 + "\n" + b.reason)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.ease) { expanded.toggle() } }
        .onHover { hover = $0 }
        .help(badge.2)
    }

    private var detail: String {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let age = Format.age(now > group.start ? now - group.start : 0)
        return String(localized: "\(group.browsers.count) browsers · \(Format.bytes(group.footprint)) · \(age)")
    }
}

/// One line per app with at least 200 MB. Hover shows Quit for GUI apps.
private struct Memory: View {
    let snap: Snapshot
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title: "Apps")
                .padding(.bottom, 4)
                .help(String(localized: "Apps using at least 200 MB, helper processes included. Quit works like ⌘Q."))
            ForEach(snap.apps, id: \.name) { AppRow(app: $0, monitor: monitor) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct AppRow: View {
    let app: AppGroup
    @ObservedObject var monitor: Monitor
    @State private var hover = false

    /// "used 3h ago", only when reaper actually saw it; never a guess.
    private var lastUsed: String? {
        guard let path = app.bundlePath else { return nil }
        if NSWorkspace.shared.frontmostApplication?.bundleURL?.path == path { return nil }
        let now = Date()
        if let seen = monitor.lastActive[path] {
            let idle = now.timeIntervalSince(seen)
            return idle >= 1800 ? String(localized: "used \(Format.age(UInt64(idle * 1e6))) ago") : nil
        }
        let watching = now.timeIntervalSince(monitor.launched)
        return watching >= 1800 ? String(localized: "unused for \(Format.age(UInt64(watching * 1e6)))+") : nil
    }

    var body: some View {
        let quittable = monitor.runningApp(for: app) != nil
        HStack(spacing: 8) {
            Text(verbatim: app.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
            if let lastUsed {
                Text(verbatim: lastUsed)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if monitor.busy.contains(app.name) {
                ProgressView().controlSize(.mini)
            } else if hover, quittable {
                QuietButton(title: "Quit") { monitor.quit(app) }
            } else {
                Text(verbatim: Format.bytes(app.footprint))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .monospacedDigit()
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(String(localized: "\(app.count) processes"))
    }
}

/// Running compose stacks. Never stopped automatically.
private struct DockerSection: View {
    let stacks: [DockerStack]
    let vm: AppGroup?
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(title: "Docker")
                Spacer()
                if let vm {
                    Text(verbatim: String(localized: "\(vm.name) VM \(Format.bytes(vm.footprint))"))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(.bottom, 4)
            .help(String(localized: "Running compose stacks. Their memory lives inside the VM; stopping a stack does not always make the VM give memory back to macOS. Reaper measures it after each stop."))
            if stacks.isEmpty {
                Text("No containers running.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            }
            ForEach(stacks) { StackRow(stack: $0, monitor: monitor) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct StackRow: View {
    let stack: DockerStack
    @ObservedObject var monitor: Monitor
    @State private var hover = false

    var body: some View {
        let cpu = monitor.dockerCPU[stack.id]
        let age = Format.age(UInt64(max(0, Date().timeIntervalSince1970 - stack.created) * 1e6))
        HStack(spacing: 8) {
            Text(verbatim: stack.id)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
            Text(verbatim: String(localized: "\(stack.containerIDs.count) · up \(age)"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
            if let cpu, cpu < 0.5 {
                Badge(text: String(localized: "idle"))
                    .help(String(localized: "Under 0.5 % CPU over at least 30 seconds."))
            }
            Spacer(minLength: 6)
            if monitor.busy.contains(stack.id) {
                ProgressView().controlSize(.mini)
            } else if hover {
                QuietButton(title: "Stop") { monitor.stop(stack) }
            } else {
                Text(verbatim: Format.bytes(stack.memory))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .monospacedDigit()
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(cpu.map { String(format: "CPU %.1f%%", $0) } ?? "")
    }
}

private struct Footer: View {
    let snap: Snapshot
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "Reap orphans automatically", isOn: $monitor.autoReap)
                .help(String(localized: "Off: orphans are only written to the log. On: reaped as soon as they are found."))
            SettingRow(title: "Open at login", isOn: $monitor.openAtLogin)
            LanguageRow()
            HStack {
                // The last action's result takes this spot for a few seconds.
                Group {
                    if let action = monitor.lastAction {
                        Text(verbatim: action)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textBody)
                    } else {
                        Text(verbatim: String(format: "reaper · %@ · %.1f%%", Format.bytes(snap.ownFootprint), monitor.ownCPUPercent))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .transition(.opacity)
                Spacer()
                Button { NSWorkspace.shared.open(Log.url) } label: {
                    Text("Log").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                Button { NSApp.terminate(nil) } label: {
                    Text("Quit").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SettingRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textBody)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// System / English / Deutsch. Takes effect after a relaunch, which it does itself.
private struct LanguageRow: View {
    @State private var choice = AppLanguage.current

    var body: some View {
        HStack {
            Text("Language")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textBody)
            Spacer()
            Picker("", selection: $choice) {
                Text("System").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.en)
                Text(verbatim: "Deutsch").tag(AppLanguage.de)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .onChange(of: choice) { _, new in AppLanguage.apply(new) }
        }
    }
}

enum AppLanguage: String, Hashable {
    case system, en, de

    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let langs = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = langs.first else { return .system }
        return first.hasPrefix("de") ? .de : .en
    }

    static func apply(_ language: AppLanguage) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        var domain = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        if language == .system { domain.removeValue(forKey: "AppleLanguages") }
        else { domain["AppleLanguages"] = [language.rawValue] }
        UserDefaults.standard.setPersistentDomain(domain, forName: id)
        // Bundles pick their language at launch, so start a fresh copy.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

/// Label, bar, numbers. Without a total there is no bar: a fraction of
/// something that grows on demand would always look full.
private struct MeterRow: View {
    let label: String
    let used: UInt64
    let total: UInt64?

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 34, alignment: .leading)
            if let total, total > 0 {
                Meter(fraction: Double(used) / Double(total))
            } else {
                Spacer()
            }
            Text(verbatim: total.map { "\(Format.bytes(used)) / \(Format.bytes($0))" } ?? Format.bytes(used))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textBody)
                .frame(width: 104, alignment: .trailing)
        }
    }
}
