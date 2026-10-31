//
//  RemoteDeviceSession.swift
//  MeshCoreKit
//
//  Remote admin session state: login, permissions, CLI settings cache.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// Permission levels for remote device management.
public enum RemotePermission: Int, Comparable, Sendable {
    case guest = 0
    case readOnly = 1
    case readWrite = 2
    case admin = 3

    public var displayName: String {
        switch self {
        case .guest: return String(localized: "Guest")
        case .readOnly: return String(localized: "Read Only")
        case .readWrite: return String(localized: "Editor")
        case .admin: return String(localized: "Admin")
        }
    }

    public var isAdmin: Bool { self == .admin }
    public var canEdit: Bool { self >= .readWrite }
    public var canRead: Bool { self >= .readOnly }
    public var canPost: Bool { self >= .readWrite }

    public static func < (lhs: RemotePermission, rhs: RemotePermission) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Login state for a remote device management session.
public enum RemoteLoginState: Sendable {
    case notLoggedIn
    case loggingIn
    case loggedIn(permission: RemotePermission)
    case loginFailed(message: String)
}

/// A single CLI command/response interaction.
public struct CLIInteraction: Identifiable, Sendable {
    public let id = UUID()
    public let command: String
    public let timestamp: Date
    public var response: String?
    public var isComplete: Bool { response != nil }

    public init(command: String, timestamp: Date = Date(), response: String? = nil) {
        self.command = command
        self.timestamp = timestamp
        self.response = response
    }
}

/// Tracks a remote management session with a repeater or room server.
@MainActor
public final class RemoteDeviceSession: ObservableObject {
    /// The contact being managed.
    public let contact: Contact

    /// Current login state.
    @Published public var loginState: RemoteLoginState = .notLoggedIn

    /// CLI interaction history (command + response pairs).
    @Published public var cliHistory: [CLIInteraction] = []

    /// Parsed setting values from CLI "get" responses.
    @Published public var settings: [String: String] = [:]

    /// Whether we're waiting for a CLI response.
    @Published public var isWaitingForResponse = false

    /// Whether initial settings are being fetched after login.
    @Published public var isFetchingSettings = false

    /// Whether full settings have been fetched at least once this session.
    public var hasLoadedFullSettings = false

    /// Tracks which setting sections have been fetched (on-demand loading).
    @Published public var fetchedSections: Set<String> = []

    /// Section currently being fetched.
    @Published public var fetchingSection: String?

    /// Total number of settings commands sent during auto-fetch.
    @Published public var fetchTotalCount = 0

    /// Number of settings responses received during auto-fetch.
    @Published public var fetchReceivedCount = 0

    /// Whether there are pending CLI commands awaiting responses.
    public var hasPendingCLICommands: Bool {
        cliHistory.contains(where: { !$0.isComplete })
    }

    /// Number of pending (unanswered) CLI commands.
    public var pendingCommandCount: Int {
        cliHistory.filter({ !$0.isComplete }).count
    }

    /// The oldest pending (unanswered) command, used for response attribution logging.
    public var oldestPendingCommand: String? {
        cliHistory.first(where: { !$0.isComplete })?.command
    }

    /// Keys that change automatically and should always be fetched fresh (never served from cache alone).
    public static let volatileKeys: Set<String> = [
        // Values that describe the moment they were read — caching them across launches
        // would show state from before the device's last reboot.
        "clock", "neighbors", "pwrmgt.bootreason"
    ]

    public init(contact: Contact) {
        self.contact = contact
        loadCachedSettings()
    }

    // MARK: - Settings Cache

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("MeshCore/remote_settings", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    private var cacheFileURL: URL {
        let keyHex = contact.publicKey.map { String(format: "%02x", $0) }.joined()
        return Self.cacheDirectory.appendingPathComponent("settings_\(keyHex).json")
    }

    /// Section command mapping — must match RemoteSessionManager.sectionCommands keys.
    /// Maps section name to the setting keys that section would populate.
    private static let sectionSettingKeys: [String: [String]] = [
        "info": ["ver", "clock", "name", "role", "public.key"],
        "radio": ["radio", "tx", "repeat"],
        "timing": ["af", "rxdelay", "txdelay", "direct.txdelay", "flood.max", "int.thresh", "agc.reset.interval", "cad"],
        "routing": ["loop.detect", "path.hash.mode", "region default"],
        "advertising": ["name", "lat", "lon", "owner.info", "advert.interval", "flood.advert.interval", "multi.acks"],
        "gps": ["gps", "gps advert"],
        "security": ["allow.read.only", "guest.password", "adc.multiplier"],
        "maintenance": ["powersaving", "pwrmgt.bootreason"],
    ]

    /// A setting's value, or nil when the device said it doesn't support the command.
    ///
    /// Firmware answers an unknown command with "??: <command>", and getters for hardware
    /// a board lacks reply "Error: unsupported". Both are stored like any other response,
    /// so callers that gate UI on firmware support must ask for the value this way rather
    /// than reading `settings` directly.
    ///
    /// **"Unknown command" is a third form, and it is the one the companion CLI
    /// uses.** `CMD_RUN_CLI_COMMAND` (firmware 1.18.0+) runs the command through
    /// `handleCommand` and, when that returns false, appends the literal string
    /// `Unknown command` rather than the `??:` prefix the serial CLI produces
    /// (`examples/companion_radio/MyMesh.cpp`). Without this case every setting
    /// a companion does not implement would read back as *having the value*
    /// "Unknown command", and any UI gated on `supportedValue` would show the
    /// control as supported and working.
    public func supportedValue(for key: String) -> String? {
        guard let raw = settings[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("??") || lower.hasPrefix("error")
            || lower.contains("unsupported") || lower.contains("unknown command") {
            return nil
        }
        return raw
    }

    /// The first supported value among several keys.
    ///
    /// For a setting the firmware renamed: `dutycycle` replaced `af` in 1.15.0 and
    /// the app fetches both, so the reading is "whichever one answered". Written as
    /// `settings["dutycycle"] ?? settings["af"]` at the call site this silently
    /// prefers an *unsupported* reply from the newer key over a working value from
    /// the older one, because `??` only falls through on `nil` and an
    /// `Unknown command` reply is not nil.
    public func supportedValue(forAny keys: [String]) -> String? {
        for key in keys {
            if let value = supportedValue(for: key) { return value }
        }
        return nil
    }

    /// Whether the device answered this command with a usable value.
    public func isSupported(_ key: String) -> Bool {
        supportedValue(for: key) != nil
    }

    /// A setting's value for display, or a placeholder when the device does not
    /// support the command.
    ///
    /// **This is what a view should call.** `settings[key] ?? "—"` puts the literal
    /// text `Unknown command` on screen as though it were the setting's value: the
    /// `??` never fires, because the key *exists* and holds the refusal. A companion
    /// radio reached over the 1.18 CLI answers that way for most of the repeater
    /// command set, so the Device Clock row read "Unknown command" and the device
    /// role did too. Seen on hardware 2026-10-30.
    public func displayValue(for key: String, placeholder: String = "\u{2014}") -> String {
        supportedValue(for: key) ?? placeholder
    }

    /// Same, for a setting that may answer under one of several names.
    public func displayValue(forAny keys: [String], placeholder: String = "\u{2014}") -> String {
        supportedValue(forAny: keys) ?? placeholder
    }

    /// `get radio` parsed into its four components, or nil when unsupported or
    /// malformed.
    ///
    /// Frequency is returned in kHz, matching `RadioPreset` comparison. Parsing
    /// lived in a view and began `guard let radio = session.settings["radio"]`,
    /// which succeeds on an `Unknown command` reply and then falls through to
    /// `(0, 0, 0, 0)` — a radio apparently tuned to 0 MHz, indistinguishable from
    /// a genuine parse failure and fed straight into preset detection.
    public var radioParameters: (freqKHz: Double, bw: Double, sf: UInt8, cr: UInt8)? {
        guard let radio = supportedValue(for: "radio") else { return nil }
        let parts = radio.replacingOccurrences(of: " ", with: "").split(separator: ",")
        guard parts.count >= 4,
              let freqMHz = Double(parts[0]),
              let bw = Double(parts[1]),
              let sf = UInt8(parts[2]),
              let cr = UInt8(parts[3]) else { return nil }
        return (freqMHz * 1000, bw, sf, cr)
    }

    /// The device clock for display: a formatted date when the reply is a raw
    /// epoch, the reply verbatim when it is already human-readable, and the
    /// placeholder when the device has no `clock` command at all.
    ///
    /// A companion radio does not implement `clock` — its time is set over the
    /// binary link with `CMD_SET_DEVICE_TIME`, not the CLI — so this is the row
    /// that displayed `Unknown command` on an iPhone.
    public func clockDisplay(placeholder: String = "\u{2014}",
                             formatter: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> String {
        guard let raw = supportedValue(for: "clock") else { return placeholder }
        if let epoch = Double(raw), epoch > 1_000_000_000 {
            return formatter(Date(timeIntervalSince1970: epoch))
        }
        return raw
    }

    /// Whether the device clock looks wrong, judged against `now`.
    ///
    /// False when there is no clock to judge. An unsupported reply must not read
    /// as stale: offering to fix a clock the device does not expose is a prompt
    /// the user can never satisfy.
    ///
    /// `now` is a parameter so this is testable without waiting for a year to
    /// turn over.
    public func isClockStale(now: Date = Date()) -> Bool {
        guard let raw = supportedValue(for: "clock") else { return false }
        let currentYear = Calendar.current.component(.year, from: now)
        if let pattern = try? NSRegularExpression(pattern: "\\b(20\\d{2})\\b"),
           let match = pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 1), in: raw),
           let year = Int(raw[range]) {
            return abs(year - currentYear) >= 1
        }
        if let epoch = Double(raw) {
            return abs(epoch - now.timeIntervalSince1970) > 60
        }
        return false
    }

    /// The device's role for display, falling back to the contact's own type.
    ///
    /// The fallback is the point: `settings["role"] ?? typeName` never reached the
    /// fallback on a companion, because `role` held `Unknown command`.
    public func roleLabel(fallback: String) -> String {
        supportedValue(for: "role") ?? fallback
    }

    /// Whether any key in a section came back with a usable value.
    ///
    /// Distinct from `hasCachedSettings(for:)`, which asks only whether a reply
    /// was ever stored — and an `Unknown command` reply is a stored reply, so a
    /// section of entirely unsupported commands reports as populated.
    public func hasSupportedSettings(for section: String) -> Bool {
        guard let keys = Self.sectionSettingKeys[section] else { return false }
        return keys.contains { isSupported($0) }
    }

    /// The remote device's firmware version, as reported by `get ver`.
    ///
    /// Nil until the info section has been fetched, or if the reply is not
    /// version-shaped.
    public var firmwareVersion: FirmwareVersion? {
        supportedValue(for: "ver").flatMap { FirmwareVersion($0) }
    }

    /// Whether the remote device runs at least the given firmware version.
    ///
    /// False when the version is not yet known, which hides a gated control until the
    /// info section lands rather than offering a command the device may reject. Only
    /// use this for commands that cannot be probed — prefer `supportedValue(for:)`
    /// whenever a getter exists, since it reflects the board rather than the version.
    public func firmwareAtLeast(_ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool {
        guard let version = firmwareVersion else { return false }
        return version >= FirmwareVersion(major: major, minor: minor, patch: patch)
    }

    /// Whether cached settings exist for any keys in the given section.
    public func hasCachedSettings(for section: String) -> Bool {
        guard let keys = Self.sectionSettingKeys[section] else { return false }
        return keys.contains { settings[$0] != nil }
    }

    /// Debounce timer for cache saves — avoids writing on every single setting update.
    private var cacheSaveTask: Task<Void, Never>?

    /// Schedule a debounced save of non-volatile settings to disk.
    public func saveSettingsCache() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s debounce
            guard !Task.isCancelled, let self else { return }
            self.writeCacheToDisk()
        }
    }

    /// Immediately flush cached settings to disk (called when a section completes).
    public func flushCacheNow() {
        cacheSaveTask?.cancel()
        writeCacheToDisk()
    }

    /// Immediately write non-volatile settings to disk.
    private func writeCacheToDisk() {
        let cacheable = settings.filter { !Self.volatileKeys.contains($0.key) }
        guard !cacheable.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(cacheable)
            try data.write(to: cacheFileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Cache save is best-effort
        }
    }

    /// Load cached settings from disk into the settings dictionary.
    /// Also marks sections as fetched so Phase 1 skips them on subsequent launches.
    private func loadCachedSettings() {
        let url = cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let cached = try JSONDecoder().decode([String: String].self, from: data)
            guard !cached.isEmpty else { return }
            for (key, value) in cached {
                settings[key] = value
            }
            // Mark sections as fetched if their keys exist in cache
            for (section, _) in Self.sectionSettingKeys {
                if hasCachedSettings(for: section) {
                    fetchedSections.insert(section)
                }
            }
        } catch {
            // Cache load is best-effort — stale cache is deleted
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Wait for a specific command's response to arrive. Polls every 50ms up to timeout.
    /// Returns true if the response arrived, false on timeout.
    public func waitForResponse(at index: Int, timeout: TimeInterval = 3.0) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if index < cliHistory.count && cliHistory[index].isComplete {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        return false
    }

    /// Record that a CLI command was sent. Returns the index for timeout tracking.
    @discardableResult
    public func commandSent(_ command: String) -> Int {
        let idx = cliHistory.count
        cliHistory.append(CLIInteraction(command: command))
        isWaitingForResponse = true
        return idx
    }

    /// Mark a pending command as timed out if it hasn't received a response.
    public func timeoutCommand(at index: Int) {
        guard index < cliHistory.count, !cliHistory[index].isComplete else { return }
        cliHistory[index].response = "(no response)"
        isWaitingForResponse = cliHistory.contains(where: { !$0.isComplete })
    }

    /// Flush all currently-pending commands as "(flushed)" before starting a structured fetch.
    /// Prevents FIFO response attribution from routing fetch responses to stale fire-and-forget slots.
    public func flushPendingCommands() {
        for i in cliHistory.indices where !cliHistory[i].isComplete {
            cliHistory[i].response = "(flushed)"
        }
        isWaitingForResponse = false
    }

    /// Strip all known CLI prefixes from a response value.
    public static func cleanCLIValue(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip "-> > ", "-> ", "> " prefixes (may be nested)
        while s.hasPrefix("->") || s.hasPrefix("> ") || s.hasPrefix(">") {
            if s.hasPrefix("->") {
                s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("> ") {
                s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix(">") {
                s = String(s.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    /// Record a CLI response received from the device.
    public func responseReceived(_ text: String) {
        var trimmedResponse = Self.cleanCLIValue(text)

        // Skip empty lines
        guard !trimmedResponse.isEmpty else { return }

        // FIFO match: find the first unanswered command (oldest pending)
        if let idx = cliHistory.firstIndex(where: { !$0.isComplete }) {
            let command = cliHistory[idx].command

            // Skip echoed command lines (USB serial echoes "get name" before sending the value)
            if trimmedResponse.lowercased() == command.lowercased() { return }

            // Handle "key = value" format — extract just the value
            if let eqRange = trimmedResponse.range(of: " = ") {
                let responseKey = String(trimmedResponse[trimmedResponse.startIndex..<eqRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                // For "get X" commands, check if key matches
                if command.lowercased().hasPrefix("get ") {
                    let settingKey = String(command.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased()
                    if responseKey == settingKey {
                        trimmedResponse = String(trimmedResponse[eqRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
                // Also handle bare "key = value" where key matches the command itself
                else if responseKey == command.lowercased() {
                    trimmedResponse = String(trimmedResponse[eqRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            cliHistory[idx].response = trimmedResponse
            parseSettingFromCommand(command, response: trimmedResponse)
        } else {
            // Unsolicited response — add as standalone, try "key = value" fallback
            var entry = CLIInteraction(command: "(unsolicited)")
            entry.response = trimmedResponse
            cliHistory.append(entry)
            parseKeyValueFallback(trimmedResponse)
        }
        isWaitingForResponse = cliHistory.contains(where: { !$0.isComplete })
    }

    /// Derive the setting key from the CLI command and store the response as its value.
    private func parseSettingFromCommand(_ command: String, response: String) {
        // Reject overly long responses before caching — guards against rogue device cache poisoning.
        guard response.count <= 512 else { return }

        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // "get X" → key is X
        if cmd.hasPrefix("get ") {
            let key = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                settings[key] = response
                saveSettingsCache()
                return
            }
        }

        // "set X value" → optimistically update settings[X] = value from the command itself.
        // Firmware may respond with "OK" which carries no key/value, so we use the sent value.
        if cmd.hasPrefix("set ") {
            let rest = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            // key = everything up to last space; value = last word
            if let lastSpace = rest.lastIndex(of: " ") {
                let key = String(rest[rest.startIndex..<lastSpace]).trimmingCharacters(in: .whitespaces)
                let setValue = String(rest[rest.index(after: lastSpace)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !setValue.isEmpty {
                    settings[key] = setValue
                    saveSettingsCache()
                }
            }
            return
        }

        // Bare toggle commands like "powersaving on/off" — update settings[key] = value.
        let bareToggleValues: Set<String> = ["on", "off", "1", "0", "enable", "disable"]
        if let lastSpace = cmd.lastIndex(of: " ") {
            let bareKey = String(cmd[cmd.startIndex..<lastSpace]).trimmingCharacters(in: .whitespaces)
            let bareVal = String(cmd[cmd.index(after: lastSpace)...]).trimmingCharacters(in: .whitespaces)
            if !bareKey.isEmpty && bareToggleValues.contains(bareVal) {
                settings[bareKey] = bareVal
                saveSettingsCache()
                return
            }
        }

        // Bare commands like "ver", "clock", "powersaving", "gps", "neighbors"
        // use the command itself as the key
        let bareCommands = ["ver", "clock", "powersaving", "gps", "gps advert", "neighbors", "discover.neighbors", "region", "region default", "log", "io"]
        if bareCommands.contains(cmd) {
            settings[cmd] = response
            saveSettingsCache()
            return
        }

        // Fallback: try "key = value" format in the response
        parseKeyValueFallback(response)
    }

    /// Fallback parser for responses in "key = value" format.
    private func parseKeyValueFallback(_ text: String) {
        if let eqRange = text.range(of: " = ") {
            let key = String(text[text.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(text[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                settings[key] = value
            }
        }
    }
}
