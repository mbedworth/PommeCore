# MeshCoreApple — Build Status
**Current Build:** Build 49 (v1.1.1)
**Last Updated:** 2026-03-23 12:53

**Build history note:** The project was at Build 40 at the start of the 2026-03-22 session.
An erroneous bump attempted to move it from 39→40 (already current), so that commit
was a no-op in terms of actual change. Build is now set to 45 to get ahead of any
in-flight builds and establish a clean baseline.

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

### Pending (Bugs 9–10) — Needs Real-Device Testing

| # | Bug | Status |
|---|-----|--------|
| 9 | Channel echo "Repeated" not confirmed in practice | Code is correct (verified against firmware: 0x88 LOG_RX_DATA within 30s of channel send). Needs a repeater in range to confirm the status flip. |
| 10 | DM retry aggressiveness (1 attempt before flood) | Shortened from 3 direct retries to 1. May be too aggressive. Needs real-world testing to verify flood fallback works reliably. |

---

### Open Verification Item

**CMD_GET_CHANNEL loop off-by-one?** `syncChannels` fetches `0..<maxChannels` (exclusive upper bound).
If firmware's channel table uses indices `0...maxChannels-1` (inclusive), this is correct.
If firmware expects a request for index `maxChannels` to confirm end-of-table, the last group
channel is silently missing. Verify on a device with `MAX_GROUP_CHANNELS > 1` by checking
whether all configured group channels appear in the app.

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
