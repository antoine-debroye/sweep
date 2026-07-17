# Sweep

A native macOS deep-clean app — everything [mole](https://github.com/tw93/mole) does in the
terminal, wrapped in a proper Mac interface, plus live memory tools and an
intelligent background auto-trim. Built with SwiftUI, no Electron, no sandbox
tricks, distributed as a DMG.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## What it does

| Module | What you get |
|---|---|
| **Dashboard** | Disk gauge, live memory pressure, lifetime-freed counter, one-click Smart Scan |
| **Smart Clean** | One scan across every junk category → review with safety badges → clean with undo |
| **Memory** | Pressure graph, memory breakdown, top consumers, **Flush RAM** (system `purge`) |
| **Apps** | Full uninstaller: the bundle plus caches, preferences, containers, launch agents… and a **Leftovers** scanner for apps you deleted long ago |
| **Large Files** | Files ≥100 MB in your home folder, oldest-first review, explicit selection only |
| **Dev Cleaner** | Xcode derived data & device support, npm/yarn/pnpm/bun, pip/uv, cargo, gradle, brew, Docker prune, and stale `node_modules`/`target`/`.build` in your projects |
| **Optimize** | Flush DNS, rebuild Spotlight/LaunchServices, thin Time Machine snapshots, restart Finder/Dock |
| **History** | Every clean logged; one-click **Undo** restores from Trash |
| **Auto-Trim** | Background menu-bar agent trims Safe-tier junk untouched for 30+ days, Trash-first, with a notification and undo |

## Why it's safe

- **Hard deny-list** — Documents, Desktop, Photos, Mail, Messages, Keychains, iCloud
  Drive, cloud drives, `.ssh` & friends are unreachable by design. Enforced twice
  (scanner *and* cleaner) and locked in by unit tests.
- **Only regenerable data is auto-cleanable.** Real files appear only in explicit
  review flows and are never pre-selected.
- **Trash-first with undo manifests** — permanent deletion is opt-in.
- **Running-app guard** — caches of apps currently running are left alone.
- **Whitelist** anything else in Settings; iCloud placeholders are never touched.
- The privileged helper accepts only an allow-listed set of system-junk paths —
  it can't be used as a generic delete-as-root service.

## Build & install

Requirements: Xcode 26+, Homebrew.

```bash
brew install xcodegen create-dmg
./Scripts/make-dmg.sh          # builds Release + creates dist/Sweep-1.0.0.dmg
open dist/Sweep-1.0.0.dmg      # drag Sweep → Applications
```

Development: `xcodegen generate && open Sweep.xcodeproj`
Tests (the safety gate): `xcodebuild -project Sweep.xcodeproj -scheme Sweep test`

## Permissions

Sweep walks you through these on first launch — all optional, all revocable:

1. **Full Disk Access** (System Settings → Privacy & Security) — needed to scan
   Mail, Safari and Trash. Without it those categories simply stay empty.
2. **Privileged helper** (approve under Login Items → Allow in Background) —
   lets Flush RAM and system-cache cleaning run without password prompts.
   Skipped? Sweep falls back to the standard macOS admin prompt.
3. **Notifications** — auto-trim results with an undo pointer.

## Signing

The default build is **ad-hoc signed**: perfect on your own Mac. If you share
the DMG, recipients right-click → Open once. With an Apple Developer ID, run
`TEAM_ID=XXXXXXXXXX ./Scripts/notarize.sh` for a fully notarized,
warning-free DMG.

## Layout

```
App/        SwiftUI app (features, design system, menu bar, onboarding)
Core/       SweepCore.framework — rules, scanner, cleaner, safety, stats
Helper/     privileged XPC daemon (SMAppService)
Shared/     XPC protocol + privileged path policy (compiled into both sides)
Tests/      safety + engine tests on fixture trees
Scripts/    build.sh · make-dmg.sh · notarize.sh · icon & artwork generators
```
