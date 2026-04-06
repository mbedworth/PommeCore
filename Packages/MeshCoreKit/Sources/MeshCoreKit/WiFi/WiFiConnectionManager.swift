//
//  WiFiConnectionManager.swift
//  MeshCoreKit
//
//  TCP socket connection to MeshCore radios over WiFi.
//
//  Created by Michael P. Bedworth on 3/17/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import Combine
import Network
import os.log

/// Manages WiFi/TCP connections to MeshCore devices.
/// Uses the same binary framing as USB serial: `<` (0x3C) + length(2 LE) + payload (inbound),
/// `>` (0x3E) + length(2 LE) + payload (outbound).
public final class WiFiConnectionManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.meshcore", category: "WiFi")

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var connectedHost: String?

    /// Publisher for incoming binary frames.
    public let receivedDataSubject = PassthroughSubject<Data, Never>()

    private var connection: NWConnection?
    private var readBuffer = Data()
    private let queue = DispatchQueue(label: "com.meshcore.wifi", qos: .userInitiated)

    /// Auto-reconnect state
    public private(set) var lastHost: String?
    public private(set) var lastPort: UInt16?
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3
    private var reconnectTask: Task<Void, Never>?
    public private(set) var isUserDisconnect = false

    public init() {}

    // MARK: - Connect / Disconnect

    public func connect(host: String, port: UInt16 = 5000) {
        reconnectTask?.cancel()
        isUserDisconnect = false
        connection?.cancel()
        connection = nil
        readBuffer = Data()

        lastHost = host
        lastPort = port

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Self.logger.error("Invalid port: \(port)")
            return
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Self.logger.info("WiFi connected to \(host):\(port)")
                DebugLogger.shared.log("WIFI: connected to \(host):\(port)", level: .info)
                DispatchQueue.main.async {
                    self.reconnectAttempts = 0
                    self.isConnected = true
                    self.connectedHost = host
                }
                self.receiveLoop()
            case .failed(let error):
                Self.logger.error("WiFi connection failed: \(error)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.connectedHost = nil
                    self.attemptReconnect()
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.connectedHost = nil
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    public func disconnect() {
        isUserDisconnect = true
        reconnectTask?.cancel()
        reconnectAttempts = 0
        connection?.cancel()
        connection = nil
        readBuffer = Data()
        isConnected = false
        connectedHost = nil
    }

    private func attemptReconnect() {
        guard !isUserDisconnect,
              let host = lastHost, let port = lastPort,
              reconnectAttempts < Self.maxReconnectAttempts else {
            if reconnectAttempts >= Self.maxReconnectAttempts {
                DebugLogger.shared.log("WIFI: reconnect attempts exhausted", level: .warning)
            }
            return
        }
        reconnectAttempts += 1
        DebugLogger.shared.log("WIFI: reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts) to \(host):\(port)", level: .warning)

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.connect(host: host, port: port)
        }
    }

    // MARK: - Send

    /// Send a binary frame with framing: `<` + length(2 LE) + frame data.
    public func sendFrame(_ frame: Data) {
        guard let connection, connection.state == .ready else { return }
        var framedData = Data([0x3C])
        var length = UInt16(frame.count).littleEndian
        framedData.append(Data(bytes: &length, count: 2))
        framedData.append(frame)

        connection.send(content: framedData, completion: .contentProcessed { error in
            if let error {
                Self.logger.error("WiFi send error: \(error)")
            }
        })
        Self.logger.debug("TX WiFi [\(frame.count) bytes]")
    }

    // MARK: - Receive

    /// Runs on the WiFi queue — reads data and parses frames.
    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                self.parseBinaryFrames()
            }
            if isComplete || error != nil {
                Self.logger.info("WiFi connection ended")
                DispatchQueue.main.async {
                    guard !self.isUserDisconnect else { return }
                    self.connection?.cancel()
                    self.connection = nil
                    self.readBuffer = Data()
                    self.isConnected = false
                    self.connectedHost = nil
                    self.attemptReconnect()
                }
                return
            }
            self.receiveLoop()
        }
    }

    /// Parses `>` (0x3E) + length(2 LE) + payload frames from readBuffer.
    /// Runs on the WiFi queue.
    private func parseBinaryFrames() {
        while readBuffer.count >= 3 {
            let si = readBuffer.startIndex
            guard readBuffer[si] == 0x3E else {
                // Skip garbage bytes until we find a frame marker
                if let idx = readBuffer.firstIndex(of: 0x3E) {
                    let skip = readBuffer.distance(from: si, to: idx)
                    readBuffer.removeFirst(skip)
                } else {
                    readBuffer.removeAll()
                    return
                }
                continue
            }

            var length: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &length) { dest in
                readBuffer.copyBytes(to: dest, from: (si + 1)..<(si + 3))
            }
            length = UInt16(littleEndian: length)

            let totalNeeded = 3 + Int(length)
            guard readBuffer.count >= totalNeeded else { return }

            let frameData = Data(readBuffer[(si + 3)..<(si + totalNeeded)])
            readBuffer.removeFirst(totalNeeded)

            Self.logger.debug("RX WiFi frame [\(frameData.count) bytes]")
            DispatchQueue.main.async { [weak self] in
                self?.receivedDataSubject.send(frameData)
            }
        }
    }
}
