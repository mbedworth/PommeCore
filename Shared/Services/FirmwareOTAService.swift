//
//  FirmwareOTAService.swift
//  PommeCore
//
//  State machine for ESP32 WiFi OTA firmware updates.
//  Flow: fetch assets → select binary → download → wait for OTA WiFi → upload → done.
//

import Foundation

// MARK: - OTAAsset

struct OTAAsset: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let downloadURL: String
    let sizeBytes: Int

    var boardName: String {
        guard let range = name.range(of: "_companion_radio") else { return name }
        return String(name[name.startIndex..<range.lowerBound])
    }

    var isBLE: Bool { name.contains("_companion_radio_ble") }
    var isMerged: Bool { name.hasSuffix("-merged.bin") }

    var displayName: String {
        boardName.replacingOccurrences(of: "_", with: " ")
    }

    var sizeFormatted: String {
        let kb = Double(sizeBytes) / 1024
        return kb < 1024 ? String(format: "%.0f KB", kb) : String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - FirmwareOTAService

@MainActor @Observable
final class FirmwareOTAService {

    enum Step {
        case ready
        case fetchingAssets
        case selectingFirmware(assets: [OTAAsset], suggested: OTAAsset?)
        case downloading(progress: Double, asset: OTAAsset)
        case activateOTA(firmwareData: Data, asset: OTAAsset)
        case detectingRadio(firmwareData: Data, asset: OTAAsset)
        case uploading(progress: Double)
        case done
        case failed(String, canRetry: Bool)
    }

    var step: Step = .ready
    private var isCancelled = false

    static let otaSSID = "MeshCore-OTA"
    private static let otaHost = "http://192.168.4.1"
    private static let releaseURL = "https://api.github.com/repos/meshcore-dev/MeshCore/releases/latest"

    // MARK: - Public API

    func start(manufacturer: String) async {
        isCancelled = false
        step = .fetchingAssets
        do {
            let assets = try await fetchAssets()
            let candidates = assets.filter { $0.name.contains("companion_radio") && !$0.isMerged }
            let bleAssets = candidates.filter(\.isBLE)
            let displayAssets = bleAssets.isEmpty ? candidates : bleAssets

            let lowerMfr = manufacturer.lowercased()
            let suggested = displayAssets.first {
                let board = $0.boardName.lowercased()
                return !lowerMfr.isEmpty && (lowerMfr.contains(board) || board.contains(lowerMfr))
            }

            step = .selectingFirmware(assets: displayAssets, suggested: suggested)
        } catch {
            guard !isCancelled else { return }
            step = .failed(error.localizedDescription, canRetry: true)
        }
    }

    func selectAsset(_ asset: OTAAsset) async {
        step = .downloading(progress: 0, asset: asset)
        do {
            let data = try await downloadBinary(asset)
            guard !isCancelled else { return }
            step = .activateOTA(firmwareData: data, asset: asset)
        } catch {
            guard !isCancelled else { return }
            step = .failed(error.localizedDescription, canRetry: true)
        }
    }

    func beginDetection(firmwareData: Data, asset: OTAAsset) {
        step = .detectingRadio(firmwareData: firmwareData, asset: asset)
        Task {
            await detectAndUpload(firmwareData: firmwareData)
        }
    }

    func cancel() {
        isCancelled = true
        step = .ready
    }

    func reset() {
        isCancelled = false
        step = .ready
    }

    // MARK: - GitHub Asset Fetch

    private func fetchAssets() async throws -> [OTAAsset] {
        guard let url = URL(string: Self.releaseURL) else { throw OTAError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OTAError.networkError("GitHub API unavailable — check internet connection")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw OTAError.parseError
        }

        return assets.compactMap { item -> OTAAsset? in
            guard let name = item["name"] as? String, name.hasSuffix(".bin"),
                  let url = item["browser_download_url"] as? String,
                  let size = item["size"] as? Int else { return nil }
            return OTAAsset(name: name, downloadURL: url, sizeBytes: size)
        }
    }

    // MARK: - Binary Download

    private func downloadBinary(_ asset: OTAAsset) async throws -> Data {
        guard let url = URL(string: asset.downloadURL) else { throw OTAError.invalidURL }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)

        let (asyncBytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OTAError.networkError("Download failed — check internet connection")
        }

        // GitHub uses chunked encoding — expectedContentLength is often -1.
        // Fall back to the known asset size for progress reporting.
        // GitHub uses chunked encoding — expectedContentLength is often -1.
        // Fall back to the known asset size for progress reporting.
        let contentLength = Int(response.expectedContentLength)
        let total = contentLength > 0 ? contentLength : asset.sizeBytes
        var received = Data()
        received.reserveCapacity(max(total, asset.sizeBytes))

        var lastReportedPct = 0.0
        for try await byte in asyncBytes {
            guard !isCancelled else { throw OTAError.cancelled }
            received.append(byte)
            if total > 0 {
                let pct = min(Double(received.count) / Double(total), 1.0)
                // Throttle UI updates to every 0.5% — firing on every byte causes
                // 1.2M SwiftUI state mutations and brings the download to a crawl.
                if pct - lastReportedPct >= 0.005 {
                    lastReportedPct = pct
                    if case .downloading(_, let a) = step {
                        step = .downloading(progress: pct, asset: a)
                    }
                }
            }
        }

        guard !received.isEmpty else { throw OTAError.networkError("Downloaded file is empty") }
        return received
    }

    // MARK: - OTA Detection + Upload

    private func detectAndUpload(firmwareData: Data) async {
        guard let pollURL = URL(string: "\(Self.otaHost)/update") else { return }

        let pollConfig = URLSessionConfiguration.default
        pollConfig.timeoutIntervalForRequest = 3
        pollConfig.timeoutIntervalForResource = 5
        pollConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let pollSession = URLSession(configuration: pollConfig)

        let maxAttempts = 90   // 90 × ~3s = ~4.5 minutes
        var attempts = 0

        while attempts < maxAttempts && !isCancelled {
            do {
                let (_, response) = try await pollSession.data(from: pollURL)
                if (response as? HTTPURLResponse)?.statusCode != nil {
                    // Radio is reachable — upload
                    step = .uploading(progress: 0)
                    do {
                        try await uploadFirmware(firmwareData)
                        step = .done
                    } catch {
                        guard !isCancelled else { return }
                        step = .failed(error.localizedDescription, canRetry: false)
                    }
                    return
                }
            } catch { /* not reachable yet */ }
            attempts += 1
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        guard !isCancelled else { return }
        step = .failed(
            "Timed out waiting for radio. Make sure you're connected to '\(Self.otaSSID)' WiFi and that your radio is in OTA mode.",
            canRetry: false
        )
    }

    private func uploadFirmware(_ data: Data) async throws {
        guard let url = URL(string: "\(Self.otaHost)/update") else { throw OTAError.invalidURL }

        let boundary = "MeshCoreOTA\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        body += "--\(boundary)\r\n".utf8Data
        body += "Content-Disposition: form-data; name=\"update\"; filename=\"firmware.bin\"\r\n".utf8Data
        body += "Content-Type: application/octet-stream\r\n\r\n".utf8Data
        body += data
        body += "\r\n--\(boundary)--\r\n".utf8Data

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = body

        let delegate = UploadProgressDelegate { [weak self] progress in
            guard let self else { return }
            self.step = .uploading(progress: progress)
        }

        // 30s idle timeout per segment; 10 min total — ESP32 AP is slow
        // timeoutInterval on URLRequest is unreliable for large body uploads on macOS;
        // set it on the configuration instead.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OTAError.uploadFailed(0)
            }
            // AsyncElegantOTA returns 200 on success; it may also redirect
            guard http.statusCode < 400 else {
                throw OTAError.uploadFailed(http.statusCode)
            }
        } catch _ as URLError where delegate.allBytesUploaded {
            // ESP32 reboots immediately after flashing, dropping the connection
            // before the HTTP response is fully sent. If all bytes were uploaded,
            // treat any connection error as success.
            return
        }
    }

    // MARK: - Errors

    enum OTAError: LocalizedError {
        case invalidURL
        case networkError(String)
        case parseError
        case cancelled
        case uploadFailed(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .networkError(let m): return m
            case .parseError: return "Could not parse release information from GitHub"
            case .cancelled: return "Cancelled"
            case .uploadFailed(let c): return c == 0 ? "No response from radio" : "Upload failed (HTTP \(c))"
            }
        }
    }
}

// MARK: - Upload progress delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    /// True once all upload bytes have been sent to the ESP32.
    private(set) var allBytesUploaded = false

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        if totalBytesSent >= totalBytesExpectedToSend { allBytesUploaded = true }
        DispatchQueue.main.async { self.onProgress(progress) }
    }
}

// MARK: - Data helper

private extension String {
    var utf8Data: Data { Data(utf8) }
}

private func += (lhs: inout Data, rhs: Data) { lhs.append(rhs) }
