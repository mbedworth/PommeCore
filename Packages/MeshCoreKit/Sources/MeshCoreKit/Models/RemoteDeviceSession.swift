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

    public init(contact: Contact) {
        self.contact = contact
    }

    /// Record that a CLI command was sent.
    public func commandSent(_ command: String) {
        cliHistory.append(CLIInteraction(command: command))
        isWaitingForResponse = true
    }

    /// Record a CLI response received from the device.
    public func responseReceived(_ text: String) {
        // FIFO match: find the first unanswered command (oldest pending)
        if let idx = cliHistory.firstIndex(where: { !$0.isComplete }) {
            cliHistory[idx].response = text
        } else {
            // Unsolicited response — add as standalone
            var entry = CLIInteraction(command: "(unsolicited)")
            entry.response = text
            cliHistory.append(entry)
        }
        isWaitingForResponse = cliHistory.contains(where: { !$0.isComplete })

        // Try to parse as a setting value (responses like "name = MyRepeater")
        parseSetting(from: text)
    }

    /// Parse a CLI response to extract a setting key/value pair.
    private func parseSetting(from text: String) {
        // Common response formats:
        // "name = MyRepeater"
        // "tx = 22"
        // "radio = 906000,250,12,8"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eqRange = trimmed.range(of: " = ") {
            let key = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(trimmed[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            settings[key] = value
        }
    }
}
