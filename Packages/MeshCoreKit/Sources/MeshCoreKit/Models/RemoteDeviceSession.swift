import Foundation

/// Login state for a remote device management session.
public enum RemoteLoginState: Sendable {
    case notLoggedIn
    case loggingIn
    case loggedIn(isAdmin: Bool)
    case loginFailed
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

    public init(contact: Contact) {
        self.contact = contact
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

    /// Record a CLI response received from the device.
    public func responseReceived(_ text: String) {
        let trimmedResponse = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // FIFO match: find the first unanswered command (oldest pending)
        if let idx = cliHistory.firstIndex(where: { !$0.isComplete }) {
            cliHistory[idx].response = trimmedResponse
            // Derive setting key from the command that triggered this response
            let command = cliHistory[idx].command
            parseSettingFromCommand(command, response: trimmedResponse)
        } else {
            // Unsolicited response — add as standalone, try "key = value" fallback
            var entry = CLIInteraction(command: "(unsolicited)")
            entry.response = trimmedResponse
            cliHistory.append(entry)
            parseKeyValueFallback(trimmedResponse)
        }
        isWaitingForResponse = cliHistory.contains(where: { !$0.isComplete })

        if isFetchingSettings {
            fetchReceivedCount += 1
        }
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
        let bareCommands = ["ver", "clock", "powersaving", "gps", "neighbors", "region", "log"]
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
