# Mac App Cleaner

Free macOS app uninstaller in pure bash. Finds leftovers, moves to Trash (not `rm`), zero dependencies. Safe. Open-source. Interactive.

> Apple still ships no real uninstaller. Drag-to-Trash leaves caches, prefs, containers, launch agents, login items — gigabytes of forgotten state. This fixes that.

![Mac App Cleaner demo](docs/demo.gif)

## Install in 5 seconds

```bash
git clone https://github.com/rblyz/mac-app-cleaner.git && cd mac-app-cleaner && chmod +x cleaner.sh && ./cleaner.sh
```

## Or in 30 seconds

```bash
git clone https://github.com/rblyz/mac-app-cleaner.git
cd mac-app-cleaner
chmod +x cleaner.sh
./cleaner.sh
```

The first run offers to add a `cleaner` shell alias so you can launch it from anywhere.

No build, no Homebrew, no dependencies — works on stock macOS.

## How to use

1. **Run `./cleaner.sh`** — pick `scan for apps` from the menu
2. **Browse the list** — installed apps, leftover bundles, junk folders. Arrow keys, Enter to inspect
3. **Review** — see exactly what will be moved to Trash, with sizes and a total
4. **Confirm with Y** — everything moves to `~/.Trash` via Finder. No `rm`, no `rm -rf`, nothing destroyed. Restore from Trash if you change your mind

Quit anytime with `q` or `Esc`. Nothing is touched without explicit confirmation.

## What it finds

| | |
|---|---|
| **app** | Bundles in `/Applications` and `~/Applications` |
| **leftover** | Caches, prefs, containers, logs, launch agents — matched by bundle ID and app name |
| **junk** | Orphaned folders with no installed app (under 50 KB or empty) — group-trashable |

Search covers `~/Library/{Application Support, Caches, Preferences, Containers, Group Containers, LaunchAgents, Logs, Cookies, WebKit, HTTPStorages, Application Scripts, PreferencePanes, Internet Plug-Ins, Saved Application State}`, `/Library/{LaunchAgents, LaunchDaemons, Application Support, Preferences, Caches, PrivilegedHelperTools}`, and `/private/var/db/receipts`.

## Safe by default

- **Move to Trash, never `rm`** — every action is recoverable from `~/.Trash`
- **Confirmation required** — y/N prompt before any deletion, with full file list and total size
- **Refuses to trash a running app** — quits cleanly with a warning
- **Skips system bundles** — Apple binaries, frameworks, helper extensions stay untouched
- **Precise matching** — finds files by exact bundle ID and app name, never by vendor guess, so apps from the same developer aren't mistaken for each other

## Limitations

- **Homebrew Cask apps** — uninstall through `brew uninstall` first; we'll find any leftovers it misses
- **Kernel & system extensions** — out of scope (require `kextunload` / system permissions)
- **Apps in iCloud Drive** — paths under `~/Library/Mobile Documents` are intentionally skipped
- **Sandbox containers** for currently-running apps may be locked — quit the app first

## Compatibility

- **macOS 10.15 Catalina (2019)** and newer
- **Intel** and **Apple Silicon** (M1, M2, M3, M4)
- **bash 3.2** — Apple's stock shell, present on every Mac since 2007
- **No Rosetta**, no special permissions, no admin rights
- **No Homebrew**, no installs, no network calls

## Why bash

- **Zero dependencies** — runs on any Mac, today, tomorrow, in 2030
- **bash 3.2 compatible** — works with Apple's stock shell, no installs
- **Single file, ~1000 lines** — read the source, audit it, fork it
- **No network, no telemetry** — does what it says, nothing else

## License

MIT
