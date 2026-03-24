#if !os(watchOS)
import SwiftUI
import MapKit
import CoreLocation
import MeshCoreKit

// MARK: - InternetMapNode

/// A node fetched from the MeshCore internet map (map.meshcore.dev).
struct InternetMapNode: Identifiable, Sendable {
    /// Stable identity derived from coordinates + name.
    var id: String { "\(latitude),\(longitude),\(name)" }
    let name: String
    let latitude: Double
    let longitude: Double
    /// Node type matching MeshCore contact types: 1=chat, 2=repeater, 3=room, 4=sensor.
    let type: Int
}

// MARK: - MeshMapService

/// Handles communication with the MeshCore internet map at map.meshcore.dev.
///
/// **Upload:** Receives the local node's signed advert data (from CMD_EXPORT_CONTACT
/// for self) and POSTs it to the upload endpoint. The advert packet is already signed
/// by the device's Ed25519 private key; no additional signing is needed in the app.
///
/// **Fetch:** Downloads and MessagePack-decodes the public node list for display on
/// the in-app map alongside local mesh contacts.
@MainActor
final class MeshMapService {

    static let shared = MeshMapService()

    private static let uploadURL = URL(string: "https://map.meshcore.dev/api/v1/uploader/node")!
    private static let nodesURL  = URL(string: "https://map.meshcore.dev/api/v1/nodes?binary=1&short=1")!

    private(set) var nodes: [InternetMapNode] = []
    private var lastFetch: Date = .distantPast
    private let fetchInterval: TimeInterval = 300  // 5 minutes

    private init() {}

    // MARK: Upload

    /// Upload the local node's signed advert to the internet map.
    ///
    /// - Parameter exportURL: The `meshcore://hexbytes` URL returned by CMD_EXPORT_CONTACT
    ///   (self-export, no pubkey in the frame). The hex bytes are the raw signed advert
    ///   packet produced by the firmware. The device coordinates already have the GPS fudge
    ///   applied before being stored, so the map receives the fuzzed position.
    func uploadNode(exportURL: String) {
        guard exportURL.hasPrefix("meshcore://") else { return }
        let hex = String(exportURL.dropFirst("meshcore://".count))
        guard !hex.isEmpty, hex.count % 2 == 0 else { return }

        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let nextIdx = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<nextIdx], radix: 16) {
                data.append(byte)
            }
            idx = nextIdx
        }
        guard !data.isEmpty else { return }

        // Fire-and-forget background upload; does not block UI.
        Task.detached { await MeshMapService.post(data: data) }
    }

    private static func post(data: Data) async {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DebugLogger.shared.log("MAP UPLOAD: HTTP \(http.statusCode)", level: .info)
            }
        } catch {
            DebugLogger.shared.log("MAP UPLOAD: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: Fetch

    /// Fetch internet nodes if the cached data is older than 5 minutes.
    func fetchIfNeeded() {
        guard Date().timeIntervalSince(lastFetch) > fetchInterval else { return }
        Task { await fetch() }
    }

    /// Force-refresh the internet node list from map.meshcore.dev.
    func fetch() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.nodesURL)
            let decoded = MeshMapMessagePackDecoder.decodeNodes(from: data)
            nodes = decoded
            lastFetch = Date()
            DebugLogger.shared.log("MAP FETCH: \(decoded.count) internet nodes", level: .info)
        } catch {
            DebugLogger.shared.log("MAP FETCH: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - MeshMapMessagePackDecoder

/// Minimal MessagePack decoder for the MeshCore internet map nodes API response.
///
/// Handles all standard MessagePack types. The map API returns an array of node
/// maps with string or integer keys. Latitude and longitude may be floating-point
/// degrees or integer microdegrees; both are handled automatically.
enum MeshMapMessagePackDecoder {

    // MARK: Value type

    enum MPValue {
        case null
        case bool(Bool)
        case int(Int64)
        case uint(UInt64)
        case float(Double)
        case string(String)
        case binary(Data)
        case array([MPValue])
        case map([(MPValue, MPValue)])
    }

    // MARK: Reader

    private struct Reader {
        let data: Data
        var offset: Int = 0

        mutating func readByte() throws -> UInt8 {
            guard offset < data.count else { throw DecodeError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readBytes(_ count: Int) throws -> Data {
            guard offset + count <= data.count else { throw DecodeError.truncated }
            defer { offset += count }
            return data[data.startIndex + offset ..< data.startIndex + offset + count]
        }

        mutating func readUInt16() throws -> UInt16 {
            let b = try readBytes(2)
            return (UInt16(b[b.startIndex]) << 8) | UInt16(b[b.startIndex + 1])
        }

        mutating func readUInt32() throws -> UInt32 {
            let b = try readBytes(4)
            return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        mutating func readUInt64() throws -> UInt64 {
            let b = try readBytes(8)
            return b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }

    enum DecodeError: Error {
        case truncated
        case unsupportedFormat(UInt8)
    }

    // MARK: Decode

    static func decode(data: Data) throws -> MPValue {
        var r = Reader(data: data)
        return try readValue(&r)
    }

    private static func readValue(_ r: inout Reader) throws -> MPValue {
        let byte = try r.readByte()

        switch byte {
        // Positive fixint 0x00–0x7F
        case 0x00...0x7F: return .int(Int64(byte))

        // Fixmap 0x80–0x8F
        case 0x80...0x8F: return try readMap(count: Int(byte & 0x0F), r: &r)

        // Fixarray 0x90–0x9F
        case 0x90...0x9F: return try readArray(count: Int(byte & 0x0F), r: &r)

        // Fixstr 0xA0–0xBF
        case 0xA0...0xBF:
            return .string(try readString(len: Int(byte & 0x1F), r: &r))

        case 0xC0: return .null
        case 0xC2: return .bool(false)
        case 0xC3: return .bool(true)

        // bin8, bin16, bin32
        case 0xC4: return .binary(try r.readBytes(Int(try r.readByte())))
        case 0xC5: return .binary(try r.readBytes(Int(try r.readUInt16())))
        case 0xC6: return .binary(try r.readBytes(Int(try r.readUInt32())))

        // float32, float64
        case 0xCA:
            let bits = try r.readUInt32()
            return .float(Double(Float(bitPattern: bits)))
        case 0xCB:
            let bits = try r.readUInt64()
            return .float(Double(bitPattern: bits))

        // uint8..64
        case 0xCC: return .uint(UInt64(try r.readByte()))
        case 0xCD: return .uint(UInt64(try r.readUInt16()))
        case 0xCE: return .uint(UInt64(try r.readUInt32()))
        case 0xCF: return .uint(try r.readUInt64())

        // int8..64
        case 0xD0: return .int(Int64(Int8(bitPattern: try r.readByte())))
        case 0xD1: return .int(Int64(Int16(bitPattern: try r.readUInt16())))
        case 0xD2: return .int(Int64(Int32(bitPattern: try r.readUInt32())))
        case 0xD3: return .int(Int64(bitPattern: try r.readUInt64()))

        // str8, str16, str32
        case 0xD9: return .string(try readString(len: Int(try r.readByte()), r: &r))
        case 0xDA: return .string(try readString(len: Int(try r.readUInt16()), r: &r))
        case 0xDB: return .string(try readString(len: Int(try r.readUInt32()), r: &r))

        // array16, array32
        case 0xDC: return try readArray(count: Int(try r.readUInt16()), r: &r)
        case 0xDD: return try readArray(count: Int(try r.readUInt32()), r: &r)

        // map16, map32
        case 0xDE: return try readMap(count: Int(try r.readUInt16()), r: &r)
        case 0xDF: return try readMap(count: Int(try r.readUInt32()), r: &r)

        // Negative fixint 0xE0–0xFF
        case 0xE0...0xFF:
            return .int(Int64(Int8(bitPattern: byte)))

        default:
            throw DecodeError.unsupportedFormat(byte)
        }
    }

    private static func readString(len: Int, r: inout Reader) throws -> String {
        let bytes = try r.readBytes(len)
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    private static func readArray(count: Int, r: inout Reader) throws -> MPValue {
        var arr = [MPValue]()
        arr.reserveCapacity(count)
        for _ in 0..<count { arr.append(try readValue(&r)) }
        return .array(arr)
    }

    private static func readMap(count: Int, r: inout Reader) throws -> MPValue {
        var pairs = [(MPValue, MPValue)]()
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            let k = try readValue(&r)
            let v = try readValue(&r)
            pairs.append((k, v))
        }
        return .map(pairs)
    }

    // MARK: Node extraction

    /// Decode the top-level MessagePack array into `InternetMapNode` values.
    /// Nodes without valid lat/lon are silently skipped.
    static func decodeNodes(from data: Data) -> [InternetMapNode] {
        guard let root = try? decode(data: data),
              case .array(let arr) = root else { return [] }
        return arr.compactMap { extractNode(from: $0) }
    }

    private static func extractNode(from value: MPValue) -> InternetMapNode? {
        guard case .map(let pairs) = value else { return nil }

        // Normalise all keys to strings for uniform lookup.
        var dict = [String: MPValue]()
        for (k, v) in pairs {
            switch k {
            case .string(let s): dict[s] = v
            case .int(let i):    dict[String(i)] = v
            case .uint(let u):   dict[String(u)] = v
            default: break
            }
        }

        // Latitude — try "lat", "lt", "latitude"
        let latRaw = dict["lat"] ?? dict["lt"] ?? dict["latitude"]
        // Longitude — try "lon", "ln", "longitude"
        let lonRaw = dict["lon"] ?? dict["ln"] ?? dict["longitude"]

        guard let latRaw, let lonRaw,
              let lat = toDouble(latRaw),
              let lon = toDouble(lonRaw) else { return nil }

        // Convert microdegrees → degrees when the magnitude exceeds valid degree range.
        let finalLat = abs(lat) > 180 ? lat / 1_000_000.0 : lat
        let finalLon = abs(lon) > 180 ? lon / 1_000_000.0 : lon

        guard abs(finalLat) <= 90, abs(finalLon) <= 180,
              finalLat != 0 || finalLon != 0 else { return nil }

        let name = toString(dict["name"] ?? dict["n"] ?? dict["nm"]) ?? "Unknown"
        let type = toInt(dict["type"] ?? dict["t"]) ?? 0

        return InternetMapNode(name: name, latitude: finalLat, longitude: finalLon, type: type)
    }

    private static func toDouble(_ v: MPValue) -> Double? {
        switch v {
        case .float(let d): return d
        case .int(let i):   return Double(i)
        case .uint(let u):  return Double(u)
        default:            return nil
        }
    }

    private static func toString(_ v: MPValue?) -> String? {
        guard case .string(let s) = v else { return nil }
        return s.isEmpty ? nil : s
    }

    private static func toInt(_ v: MPValue?) -> Int? {
        switch v {
        case .int(let i):  return Int(i)
        case .uint(let u): return Int(u)
        default:           return nil
        }
    }
}

// MARK: - MeshMapView

@available(iOS 17.0, macOS 14.0, *)
struct MeshMapView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @StateObject private var locationManager = LocationManager()

    private var mappableContacts: [Contact] {
        viewModel.contacts.filter { $0.latitude != 0 || $0.longitude != 0 }
    }

    private var internetNodes: [InternetMapNode] {
        viewModel.internetMapNodes
    }

    var body: some View {
        ZStack {
            Map {
                // Local mesh contacts
                ForEach(mappableContacts) { contact in
                    Annotation(viewModel.displayName(for: contact),
                               coordinate: CLLocationCoordinate2D(
                                   latitude: contact.latitude,
                                   longitude: contact.longitude
                               )) {
                        Button {
                            viewModel.sidebarSelection = .contact(contact.publicKeyPrefix)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: contactTypeIcon(contact))
                                    .foregroundStyle(contactTypeColor(contact))
                                    .font(.title2)
                                    .padding(6)
                                    .background(Circle().fill(.background))
                                    .shadow(radius: 2)
                                Text(viewModel.displayName(for: contact))
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Internet map nodes (map.meshcore.dev) — teal markers
                ForEach(internetNodes) { node in
                    Annotation(node.name,
                               coordinate: CLLocationCoordinate2D(
                                   latitude: node.latitude,
                                   longitude: node.longitude
                               )) {
                        VStack(spacing: 2) {
                            Image(systemName: internetNodeIcon(node))
                                .foregroundStyle(.white)
                                .font(.caption)
                                .padding(5)
                                .background(Circle().fill(Color.teal.opacity(0.85)))
                                .shadow(radius: 2)
                            Text(node.name)
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textPrimary)
                                .lineLimit(1)
                        }
                    }
                }

                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            // Overlays
            VStack {
                // Legend when internet nodes are present
                if !internetNodes.isEmpty {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(MeshTheme.accent).frame(width: 8, height: 8)
                            Text("Local mesh")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.teal.opacity(0.85)).frame(width: 8, height: 8)
                            Text("Internet map (\(internetNodes.count))")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                }

                Spacer()

                if locationManager.authorizationStatus == .denied ||
                   locationManager.authorizationStatus == .restricted {
                    Text("Location access denied. Enable in Settings \u{2192} Privacy \u{2192} Location Services.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
                if mappableContacts.isEmpty && internetNodes.isEmpty {
                    VStack(spacing: 4) {
                        Text("No contacts with location data")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("\(viewModel.contacts.count) contacts total, \(mappableContacts.count) with coordinates")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom)
                }
            }
        }
        .navigationTitle("Map")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.refreshInternetMapNodes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh internet map nodes")
            }
        }
        .onAppear {
            locationManager.requestPermission()
            viewModel.fetchInternetMapNodes()
        }
    }

    private func contactTypeIcon(_ contact: Contact) -> String {
        switch contact.type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "building.2.fill"
        case .sensor: return "sensor.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func contactTypeColor(_ contact: Contact) -> Color {
        switch contact.type {
        case .chat: return .blue
        case .repeater: return MeshTheme.accent
        case .room: return .purple
        case .sensor: return .orange
        case .unknown: return .gray
        }
    }

    /// SF Symbol for an internet map node based on its MeshCore node type.
    private func internetNodeIcon(_ node: InternetMapNode) -> String {
        switch node.type {
        case 1: return "person.fill"
        case 2: return "antenna.radiowaves.left.and.right"
        case 3: return "building.2.fill"
        case 4: return "sensor.fill"
        default: return "globe"
        }
    }
}

// MARK: - LocationManager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
        }
    }
}
#endif
