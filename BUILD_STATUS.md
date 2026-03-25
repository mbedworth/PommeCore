# MeshCoreApple — Build Status
**Current Build:** Build 55 (v1.1.1)
**Last Updated:** 2026-03-24 22:56

**Build history note:** The project was at Build 40 at the start of the 2026-03-22 session.
An erroneous bump attempted to move it from 39→40 (already current), so that commit
was a no-op in terms of actual change. Build is now set to 45 to get ahead of any
in-flight builds and establish a clean baseline.

---

## Session Summary — Build 53 → 54 (2026-03-24)

6 bugs fixed and 3 features added.

### Bug Fixes

| # | Bug | Fix | Files |
|---|-----|-----|-------|
| E-iOS | iOS Radio Settings "Done" button appeared in ellipsis overflow menu | Changed `ToolbarItem(placement: .topBarLeading)` to `.cancellationAction` | `SettingsView.swift` |
| F | Privacy & Security toggles snapped back after tapping (Manual Add Contacts, Telemetry, Advert Location, Multi-ack) | `setOtherParams()` now does optimistic `deviceConfig` property updates before `sendCommand`, matching `setAutoAddConfig` pattern | `MeshCoreViewModel.swift` |
| A | `autoAddConfig` response dropped `maxHops` byte | `FrameParser` enum case and handler both updated to carry and store `maxHops: UInt8` | `FrameParser.swift`, `DeviceConfig.swift`, `MeshCoreViewModel.swift` |
| B | `outPath` buffer allocations used wrong size formula (`outPathLen * 6` → correct hash encoding) | Fixed to `hashCount * hashSize` using correct firmware bit-field extraction | `FrameParser.swift` |
| C | macOS sidebar showed broken ellipsis toolbar with only one visible action | Replaced single `Menu` with `HStack` of 3 individual icon buttons (advert/discover/refresh) | `ContactListView.swift` |
| D | "Share All Channels" missing from Channels section | Restored `showShareAllChannels` state + sheet; added working entry to Channels `+` Menu | `ContactListView.swift` |

### Features

| Feature | Description | Files |
|---------|-------------|-------|
| Settings gear icon | "Status" section header added to sidebar with `gearshape` button; `openSettings()` helper selects Settings in NavigationSplitView (macOS/iPad) or opens sheet (iPhone) | `ContactListView.swift` |
| Connection bar consistency | Tap connected bar on macOS now opens Settings in the main detail pane (via `sidebarSelection = .settings`) instead of a sheet; removed "Device Settings" sidebar row | `ContactListView.swift` |
| Onboarding Settings slide | New page 4 "Configure Your Device" added between Region(3) and Get Started(now 5); optional "Open Settings Now" CTA wired via `@AppStorage` flag | `OnboardingView.swift`, `MeshCoreApp.swift` |

---

## Session Summary — Build 40 → 45 (2026-03-22)

8 bugs fixed across two Claude Code sessions. All committed.

### Fixed (Bugs 1–8)

| # | Bug | Root Cause | Files Changed |
|---|-----|------------|---------------|
| 1 | iOS Device Info sheet dismissed when SELF_INFO arrives mid-presentation | `if config.radioFrequency > 0` inside DeviceInfoSection changes view structure count, causing SwiftUI to drop the active `.sheet(item:)` | `SettingsView.swift` — lifted sheet state to SettingsView, moved `.sheet(item:)` above the conditional Group |
| 2 | macOS inspector "Done" button missing | `ToolbarItem` used `.cancellationAction` placement (no visible button on Catalyst inspector panels) | `SettingsView.swift` — changed to `.topBarTrailing` |
| 3 | App Lock toggle absent from Privacy & Security section | `appLockBinding` and toggle lived in a separate `securitySection` extension that wasn't wired into the form | `SettingsView.swift` — moved into `PrivacySection` struct body, removed unused extension |
| 4 | "Share All Channels" button in Settings did nothing | Button existed in `channelsSettingsSection` with an empty action body | `SettingsView.swift` — removed dead button from Settings; `ContactListView.swift` — added working entry to the Channels `+` Menu using the existing `showShareAllChannels` state |
| 5 | macOS Tip Jar: NavigationLink has no back button / exits Settings entirely | `SettingsView` lives in `NavigationSplitView` detail column with no `NavigationStack` wrapper; `dismiss()` in a destination clears the detail column on Catalyst instead of popping | `SettingsView.swift` — macOS uses `.sheet` presentation from a `Button`; iOS keeps `NavigationLink`; TipJarView toolbar button changed from "Back" (`.cancellationAction`) to "Done" (`.topBarTrailing`) |
| 6 | Tip Jar products don't reload after initial network failure | `hasLoaded` flag prevented re-fetch once set, even if `products` was empty | `SettingsView.swift` (TipJarManager) — replaced `!hasLoaded` guard with `!isLoading && products.isEmpty`; added "Try Again" button to empty state UI |
| 7 | "Publishing changes from within view updates" warnings | `observeStores()` used `Task { @MainActor }` for `objectWillChange.send()` — Swift Concurrency's cooperative executor can resume tasks during SwiftUI's render phase | `MeshCoreViewModel.swift` — changed `onChange` handler to `DispatchQueue.main.async`; GCD async runs after the current run-loop source (after render) |
| 8 | RESP_CODE_ERR 6 (illegalArg) alert shown on init | Primary cause fixed in protocol audit (CMD_GET_AUTOADD_CONFIG used 0x3A/SET instead of 0x3B/GET). Remaining `illegalArg` responses hit `lastErrorMessage` and showed user-visible alerts | `MeshCoreViewModel.swift` — `illegalArg` now log-only (not an alert); `ChannelStore.swift` — `syncChannels` warns if called before `maxChannels` is known |

---

### Resolved (Bugs 9–10 + channel off-by-one) — Confirmed in Real-Device Testing on Build 54

| # | Bug | Status |
|---|-----|--------|
| 9 | Channel echo "Repeated" not confirmed in practice | **RESOLVED** — confirmed working on build 54. |
| 10 | DM retry aggressiveness (1 attempt before flood) | **RESOLVED** — flood fallback confirmed reliable on build 54. |
| — | CMD_GET_CHANNEL loop off-by-one | **RESOLVED** — `0..<maxChannels` confirmed correct; all group channels appear. |

---

## Session Summary — Build 54 → 55 (2026-03-24)

6 bugs fixed.

### Bug Fixes

| # | Bug | Root Cause | Fix | Files |
|---|-----|------------|-----|-------|
| 8 | Build script fails to commit when `.git/index.lock` exists | Stale lock file left by a previously crashed git process blocks `git add` | Added pre-commit stale lock detection: if `.git/index.lock` exists and no git process is running, removes it automatically; exits if a live git process holds it | `scripts/bump_and_build.sh` |
| 9 | iPad mini landscape: Settings opens as sheet instead of detail pane | iPad mini landscape has `.compact` `horizontalSizeClass`; `openSettings()` was checking only size class, routing all compact layouts to a sheet | Changed to check `UIDevice.current.userInterfaceIdiom == .phone`; iPad always uses `sidebarSelection = .settings` regardless of orientation | `ContactListView.swift` |
| 10 | Map — upload not working | Map API (`/api/v1/uploader/node`) expects JSON `{"params":{freq,bw,sf,cr},"links":["meshcore://..."]}` but code was POSTing raw binary with `Content-Type: application/octet-stream` | Rewrote `uploadNode(exportURL:)` to accept radio params; `post()` now serialises JSON; call site in ViewModel passes DeviceConfig radio values (freq×1000 for Hz, bw direct) | `MeshMapView.swift`, `MeshCoreViewModel.swift` |
| 11 | Map — display not working (nodes never appear) | `fetchIfNeeded()` spawned a Task internally then returned immediately; `fetchInternetMapNodes()` waited only 500ms before copying `nodes`, losing the race on the 7.8MB API response | Made `fetchIfNeeded()` async; `fetchInternetMapNodes()` now awaits it before copying nodes — no sleep needed | `MeshMapView.swift`, `MeshCoreViewModel.swift` |
| 12 | macOS: selecting map view disables gear icon and settings entry | `navigationDestination(for: SidebarSelection.self)` in `ContactListView` was active on macOS, creating a parallel navigation stack. After the map NavigationLink fired, the pushed `MeshMapView` took priority over the outer `NavigationSplitView` switch, so `sidebarSelection = .settings` had no visible effect | Guarded `navigationDestination` to iOS only (`#if os(iOS) && !targetEnvironment(macCatalyst)`); on macOS the `NavigationSplitView` `detail:` block exclusively drives the detail column | `ContactListView.swift` |
| 13 | macOS: info/help popover bubbles fixed-size, require scrolling | `InfoPopoverContent` used `ScrollView` + `frame(minWidth:maxWidth:minHeight:)` on all platforms; macOS popovers clip to a system-imposed height when a fixed frame is set | macOS/Catalyst: removed ScrollView, applied `fixedSize(horizontal:false,vertical:true)` so popover grows to content height; iOS: unchanged (ScrollView + presentationDetents) | `SettingsView.swift` |

### Open Bugs (carry forward)

None — all tracked bugs resolved as of Build 55.

---

## Platform Deployment Targets
- iOS 18.0
- macOS 15.0 (Sequoia)
- watchOS 11.0
- Swift tools 6.0, language mode Swift 5 (MeshCoreKit)

## Build Management
```
./bump-build.sh     # increments build number in project.pbxproj
```
IAP Product IDs: `com.mbedworth.meshcore.tip.decent/.nice/.great/.help`
