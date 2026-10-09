# Sweep

A native macOS deep-clean app: a thorough command-line-grade cleanup wrapped in
a proper Mac interface, plus live memory tools and an intelligent background
auto-trim. Built with SwiftUI, no Electron, no sandbox tricks, distributed as a
DMG.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## What it does

| Module | What you get |
|---|---|
| **Dashboard** | Disk gauge, live memory pressure, lifetime-freed counter, one-click Smart Scan. **Honest free-space reporting** — APFS purgeable space is shown separately, never counted as free |
| **Smart Clean** | One scan across every junk category → review with safety badges → clean with undo |
| **Memory** | Pressure graph, memory breakdown, top consumers, **Flush RAM** (system `purge`) |
| **Apps** | Full uninstaller: the bundle plus caches, preferences, containers, launch agents… with **Strict / Enhanced / Deep** match depth (Deep also finds team-ID app groups and heuristic matches, flagged for review), a **Leftovers** scanner for apps you deleted long ago, and a Finder **“Uninstall with Sweep”** right-click service |
| **Large Files** | Files ≥100 MB in your home folder, oldest-first review, explicit selection only |
| **AI Models** | Inventories local LLM/ML models from **Ollama, LM Studio and Hugging Face**, plus weights bundled by other apps (Whisper/TTS/LLM files in their Application Support folders, PyTorch/Whisper caches), with size & last-used; remove selectively. Ollama via its safe `ollama rm`, the rest Trash-first. Never auto-selected |
| **Dev Cleaner** | **Simulator runtimes & devices** (size, last boot, "select suggested" for unusable/old runtimes and stale devices; removed through `simctl`, never raw `rm`), Xcode derived data & device support (keeps the two newest per platform), npm/yarn/pnpm/bun, pip/uv, cargo, gradle, brew, **Cursor/VS Code/Electron caches**, **Claude Desktop VM bundles**, **Android emulators & SDK**, Docker prune and deep prune (with `docker system df`), stale Claude Code / Cursor Agent versions, obsolete editor extensions, npx/Vite/Poetry/rustup/buildx-style tool caches, stale `node_modules`/`target`/`.build`, and an **AI-agent worktree cleaner** that runs `git status` on each worktree — dirty ones are locked, orphaned ones are reclaimable |
| **Optimize** | Flush DNS (asks first when a VPN is connected), rebuild Spotlight, thin Time Machine snapshots, restart Finder/Dock |
| **History** | Every clean logged; one-click **Undo** restores from Trash |
| **Auto-Trim** | Background menu-bar agent trims Safe-tier junk untouched for 30+ days, Trash-first, with a notification and undo. Configurable interval and low-disk threshold, plus a **Run now** button in Settings |

**Appearance:** Settings offers **System / Light / Dark** — System follows your Mac.

## Why it's safe

- **Hard deny-list** — Documents, Desktop, Photos, Mail, Messages, Keychains, iCloud
  Drive, cloud drives, `.ssh` & friends are unreachable by design. Enforced twice
  (scanner *and* cleaner) and locked in by unit tests.
- **Only regenerable data is auto-cleanable.** Real files appear only in explicit
  review flows and are never pre-selected.
- **Trash-first with undo manifests** — permanent deletion is opt-in.
- **Running-app guard** — caches of apps currently running are left alone, matched
  by bundle id *and* app name (Electron apps store data under their display name).
- **Cloud backing stores are hard-protected** — OneDrive and other File Provider
  sync clients keep the real files in a group container, not in `CloudStorage`;
  that container is on the deny-list too.
- **Sandbox, browser-profile and Electron caches are sweeps of cache folders only** —
  never `Documents`, bookmarks, cookies, IndexedDB, local storage or databases.
  Offline web-app storage and Chrome's on-device AI model are Review tier.
- **Simulators go through `simctl`**, never a raw delete of CoreSimulator folders,
  and the newest runtime per platform is never suggested.
- **Build folders Git tracks are not build output** — a `build/`, `dist/` or `Pods/`
  with checked-in files (electron-builder icons and entitlements, committed action
  bundles) or a repository inside is never offered, and is re-checked right before
  removal.
- **Live data inside cache folders is protected with every folder above it** —
  renv libraries, Poetry virtualenvs, Deno origin storage, Google's identity state —
  and `DiagnosticReports` folders are kept (only their reports are cleaned), since
  macOS can't recreate them.
- **Uninstalls take only what provably belongs to the app** — a launch agent is
  pre-selected only when it is named for the app's exact bundle id or runs from
  inside its bundle, and nothing is pre-selected while another copy of the app is
  still installed.
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

Release builds are **Developer ID signed** with the hardened runtime, and are
**notarized**, so the DMG installs without Gatekeeper warnings. Debug/test
builds stay ad-hoc (faster, offline-safe).

- Cut a release: `Scripts/release.sh <version> --notarize`
- One-off DMG (no bump/tag/publish): `Scripts/notarize.sh`

Signing lives only in `Scripts/build.sh`, and the notary step only in
`Scripts/notarize-artifacts.sh` — the other scripts delegate, so the two can't
drift. The helper must be signed with `--identifier com.debroye.sweep.helper`
so it matches its LaunchDaemon `Label`; otherwise SMAppService kills it at
launch with a constraint violation.

## Layout

```
App/        SwiftUI app (features, design system, menu bar, onboarding)
Core/       SweepCore.framework — rules, scanner, cleaner, safety, stats
Helper/     privileged XPC daemon (SMAppService)
Shared/     XPC protocol + privileged path policy (compiled into both sides)
Tests/      safety + engine tests on fixture trees
Scripts/    build.sh · make-dmg.sh · release.sh · notarize.sh ·
            notarize-artifacts.sh · icon & artwork generators
```
