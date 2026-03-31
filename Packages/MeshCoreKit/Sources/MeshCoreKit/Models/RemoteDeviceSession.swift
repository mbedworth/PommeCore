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
        case .guest: return "Guest"
        case .readOnly: return "Read Only"
        case .readWrite: return "Editor"
        case .admin: return "Admin"
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

    public init(contact: Contact) {
        self.contact = contact
    }

    /// Wait for a specific command's response to arrive. Polls every 50ms up to timeout.
    /// Returns true if the response arrived, false on timeout.
    public func waitForResponse(at index: Int, timeout: TimeInterval = 3.0) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if index < cliHistory.count && cliHistory[index].isComplete {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
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
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // "get X" → key is X
        if cmd.hasPrefix("get ") {
            let key = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                settings[key] = response
                return
            }
        }

        // Bare commands like "ver", "clock", "powersaving", "gps", "neighbors"
        // use the command itself as the key
        let bareCommands = ["ver", "clock", "powersaving", "gps", "gps advert", "neighbors", "discover.neighbors", "region", "log", "io"]
        if bareCommands.contains(cmd) {
            settings[cmd] = response
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
