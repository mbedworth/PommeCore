import Foundation
import os.log

/// File-based persistent store for chat messages.
/// Uses JSON encoding to a per-contact file in the app's documents directory.
/// Messages are stored in per-radio subdirectories to isolate data between radios.
public final class MessageStore {
    private static let logger = Logger(subsystem: "com.meshcore", category: "MessageStore")

    private static var rootDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MeshCoreMessages", isDirectory: true)
    }

    private let directory: URL

    /// Legacy initializer — points at flat root directory. Used only for migration.
    public init() {
        directory = Self.rootDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Per-radio initializer — stores messages in a radio-specific subdirectory.
    /// - Parameter radioPrefix: First 12 hex chars of the radio's public key.
    public init(radioPrefix: String) {
        directory = Self.rootDirectory.appendingPathComponent(radioPrefix, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Migrate flat message files into a per-radio subdirectory.
    /// Only runs if the subdirectory is empty and the root has flat `.json` files.
    /// The first radio to connect after upgrade "claims" the existing messages.
    @discardableResult
    public static func migrateToPerRadioStorage(radioPrefix: String) -> Bool {
        let root = rootDirectory
        let radioDir = root.appendingPathComponent(radioPrefix, isDirectory: true)

        // Skip if radio subdirectory already has files
        if let existing = try? FileManager.default.contentsOfDirectory(at: radioDir, includingPropertiesForKeys: nil),
           existing.contains(where: { $0.pathExtension == "json" }) {
            return false
        }

        // Find flat .json files at root level (not in subdirectories)
        guard let rootFiles = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        let flatJsonFiles = rootFiles.filter { url in
            guard url.pathExtension == "json" else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return !isDir
        }
        guard !flatJsonFiles.isEmpty else { return false }

        // Create subdirectory and move files
        try? FileManager.default.createDirectory(at: radioDir, withIntermediateDirectories: true)
        var movedCount = 0
        for file in flatJsonFiles {
            let dest = radioDir.appendingPathComponent(file.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: file, to: dest)
                movedCount += 1
            } catch {
                logger.error("Failed to migrate \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if movedCount > 0 {
            logger.info("Migrated \(movedCount) message files to radio subdirectory \(radioPrefix)")
        }
        return movedCount > 0
    }

    /// Returns 12-char hex subdirectory names under MeshCoreMessages/.
    public static func knownRadioPrefixes() -> [String] {
        let root = rootDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return contents.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            let name = url.lastPathComponent
            // 12-char hex string = 6 bytes of public key prefix
            guard name.count == 12, name.allSatisfy({ $0.isHexDigit }) else { return nil }
            return name
        }.sorted()
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

    /// Delete all message files from disk.
    public func deleteAllMessages() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
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
    public init?(hexString: String) {
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
