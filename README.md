# Reaper

A macOS menu bar app that shows why your Mac is short on memory and
cleans up what coding agents leave behind: browser daemons from dead
sessions, forgotten Docker stacks, apps you stopped using hours ago.

On its own it only removes what is provably abandoned; everything else
waits for your click. Every action reports the memory it actually freed. No "free RAM" button, no purge, no root.

## Install

```sh
brew tap theitger/tap
brew trust theitger/tap        # Homebrew ≥ 6 requires tap trust
brew install --cask agent-reaper
xattr -dr com.apple.quarantine /Applications/Reaper.app
```

The last line is needed because the app is ad-hoc signed (no Apple
Developer certificate). Without it Gatekeeper blocks the first launch.

Requires macOS 14 or later.

## What it shows

- **Memory.** Available RAM, used RAM counted like Activity Monitor
  (app memory + wired + compressed, file cache left out) and swap. The
  status dot follows the kernel's memory pressure and the swap-in rate,
  not how full swap is: a full swap file costs nothing until macOS reads
  it back.
- **Agent processes.** `agent-browser` daemons and their Chrome for
  Testing instances, grouped per session. Each is marked *orphaned*,
  *active* or *unclear* (see below). Orphans can be reaped with one click.
- **Docker.** Running compose stacks with memory, age and an *idle* badge
  (under 0.5 % CPU for 30 s). Stopped on click only, never automatically.
  After a stop Reaper measures whether the VM actually gave memory back.
- **Apps.** Every app using 200 MB or more, helpers included. Node and
  Python processes are listed by script (`tsserver (node)`), not as one
  anonymous `node`. Quit works like ⌘Q and reports the memory released.

Hover any value for an explanation. English and German; switch under
*Language* in the panel.

## How orphans are detected

Processes started from a Claude Code session inherit `CLAUDE_PID`. Reaper
reads the environment of your own processes (`sysctl KERN_PROCARGS2`) and
checks whether that Claude process still exists, comparing start times so
a reused PID does not count as alive.

- Session still running: *active*, never touched.
- Session gone and the browser ran under its own `AGENT_BROWSER_SESSION`:
  *orphaned*.
- Session gone but it was agent-browser's shared `default` daemon, and
  another agent is running: *unclear* until it is three hours old, because
  a second session may be using it.
- No session information at all: *unclear* until three hours old.

Processes are matched by their real executable path, never by command
line, so a shell that merely mentions `agent-browser` is never hit. Before
every signal the PID, start time and path are checked again; reaping is
SIGTERM, then SIGKILL after three seconds.

Automatic reaping is off by default. Until you turn it on, orphans are
only written to `~/Library/Logs/Reaper.log`, so you can check what it
would have done.

## Command line

The bundle ships a CLI next to the app:

```sh
alias reaper=/Applications/Reaper.app/Contents/MacOS/reaper
reaper status         # one-line diagnosis, memory, top apps
reaper ls --json      # agent processes and their verdict
reaper reap           # dry run; add --yes to act
reaper docker         # running compose stacks
```

`reaper ls --json` is meant for agents: a session can check what it left
running before it ends.

## What it does not do

- Free or purge RAM. That only throws away cache macOS would reuse anyway.
- Run as root, install helpers or kernel extensions.
- Touch other users' processes.
- Talk to the network. The only socket it opens is the local Docker one.

It is not on the Mac App Store because the App Sandbox does not allow
sending signals to other processes.

## Footprint

About 15 MB of memory and 0.0 % CPU when idle (measured with `footprint`
on an M2 Pro). It rescans every 60 s while the panel is closed, every 2 s
while it is open, and immediately on a memory pressure event. The panel
shows its own footprint at the bottom.

## Build from source

```sh
swift test
./Scripts/make-app.sh        # builds ~/Applications/Reaper.app
./Scripts/make-release.sh    # zips it into dist/ for a GitHub release
```

## License

MIT
