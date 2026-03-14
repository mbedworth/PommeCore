import Foundation
import os.log

/// File-based persistent store for chat messages.
/// Uses JSON encoding to a per-contact file in the app's documents directory.
public final class MessageStore {
    private static let logger = Logger(subsystem: "com.meshcore", category: "MessageStore")

    private let directory: URL

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        directory = docs.appendingPathComponent("MeshCoreMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for contactKeyHash: Data) -> URL {
        let hex = contactKeyHash.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).json")
    }

    /// Load messages for a contact from disk.
    public func loadMessages(for contactKeyHash: Data) -> [Message] {
        let url = fileURL(for: contactKeyHash)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Message].self, from: data)
        } catch {
            Self.logger.error("Failed to load messages: \(error.localizedDescription)")
            return []
        }
    }

    /// Save messages for a contact to disk.
    public func saveMessages(_ messages: [Message], for contactKeyHash: Data) {
        let url = fileURL(for: contactKeyHash)
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save messages: \(error.localizedDescription)")
        }
    }

    /// Load all persisted messages grouped by contact key hash.
    public func loadAllMessages() -> [Data: [Message]] {
        var result: [Data: [Message]] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return result }

        for file in files where file.pathExtension == "json" {
            let hex = file.deletingPathExtension().lastPathComponent
            guard let keyHash = Data(hexString: hex) else { continue }
            if let messages = try? JSONDecoder().decode([Message].self, from: Data(contentsOf: file)),
               !messages.isEmpty {
                result[keyHash] = messages
            }
        }
        return result
    }
}

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
