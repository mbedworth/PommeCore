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
    /// The map API (map.meshcore.dev/api/v1/uploader/node) expects a JSON body:
    /// ```json
    /// {
    ///   "params": { "freq": 906.0, "bw": 250.0, "sf": 9, "cr": 8 },
    ///   "links": ["meshcore://HEXDATA"]
    /// }
    /// ```
    /// Radio params convert DeviceConfig units → API units:
    ///   freq: radioFrequency (kHz) ÷ 1000 → MHz  (e.g. 906000 kHz → 906.0 MHz)
    ///   bw:   radioBandwidth (Hz) ÷ 1000 → kHz   (e.g. 250000 Hz → 250.0 kHz)
    ///   sf:   radioSpreadingFactor (raw byte)
    ///   cr:   radioCodingRate (raw byte, 5–8)
    ///
    /// - Parameters:
    ///   - exportURL: The `meshcore://hexbytes` URL from CMD_EXPORT_CONTACT (self).
    ///   - freq: Frequency in MHz (radioFrequency ÷ 1000).
    ///   - bw:   Bandwidth in kHz (radioBandwidth ÷ 1000).
    ///   - sf:   Spreading factor.
    ///   - cr:   Coding rate (5–8).
    func uploadNode(exportURL: String, freq: Double, bw: Double, sf: Int, cr: Int) {
        guard exportURL.hasPrefix("meshcore://") else { return }
        guard !exportURL.dropFirst("meshcore://".count).isEmpty else { return }

        let body: [String: Any] = [
            "params": ["freq": freq, "bw": bw, "sf": sf, "cr": cr],
            "links": [exportURL]
        ]
        // Fire-and-forget background upload; does not block UI.
        Task.detached { await MeshMapService.post(body: body) }
    }

    private static func post(body: [String: Any]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            DebugLogger.shared.log("MAP UPLOAD: failed to serialise JSON body", level: .error)
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
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
    /// Async so callers can await completion before reading `nodes`.
    func fetchIfNeeded() async {
        guard Date().timeIntervalSince(lastFetch) > fetchInterval else { return }
        await fetch()
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

        // fixext1..16 — read and discard (e.g. MessagePack Timestamps used by map API)
        case 0xD4: _ = try r.readBytes(2);  return .null  // type(1) + data(1)
        case 0xD5: _ = try r.readBytes(3);  return .null  // type(1) + data(2)
        case 0xD6: _ = try r.readBytes(5);  return .null  // type(1) + data(4)
        case 0xD7: _ = try r.readBytes(9);  return .null  // type(1) + data(8)
        case 0xD8: _ = try r.readBytes(17); return .null  // type(1) + data(16)

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
    @State private var cameraPosition: MapCameraPosition = .automatic
    /// Mirrors the camera's current region. Set explicitly when we move the camera
    /// programmatically so nodes appear without waiting for onMapCameraChange to fire.
    @State private var visibleRegion: MKCoordinateRegion? = nil
    /// True once we've applied the initial 500-mile camera jump; avoids re-jumping on pans.
    @State private var hasSetInitialCamera = false

    // ~500 miles as degrees of latitude (1° ≈ 69 mi → 500 mi ÷ 69 ≈ 7.25°)
    private static let initialSpanDegrees = 7.25

    private var mappableContacts: [Contact] {
        viewModel.contacts.filter { $0.latitude != 0 || $0.longitude != 0 }
    }

    /// Internet nodes filtered to the currently visible region, capped at 500.
    private var visibleInternetNodes: [InternetMapNode] {
        let all = viewModel.internetMapNodes
        guard !all.isEmpty, let region = visibleRegion else { return [] }
        let latHalf = region.span.latitudeDelta / 2
        let lonHalf = region.span.longitudeDelta / 2
        let lat = region.center.latitude
        let lon = region.center.longitude
        let filtered = all.filter {
            abs($0.latitude - lat) <= latHalf && abs($0.longitude - lon) <= lonHalf
        }
        return filtered.count > 500 ? Array(filtered.prefix(500)) : filtered
    }

    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                // Local mesh contacts — custom annotations with tap-to-navigate
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

                // Internet map nodes — lightweight Marker (system pin, MapKit-managed).
                // Filtered to visible region so MapKit never holds more than ~500 at once.
                ForEach(visibleInternetNodes) { node in
                    Marker(node.name,
                           systemImage: internetNodeIcon(node),
                           coordinate: CLLocationCoordinate2D(
                               latitude: node.latitude,
                               longitude: node.longitude
                           ))
                    .tint(.teal)
                }

                UserAnnotation()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // Keep visibleRegion in sync as the user pans/zooms
                DispatchQueue.main.async {
                    visibleRegion = context.region
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            // Overlays
            VStack {
                // Status bar: loading indicator or legend
                if viewModel.isLoadingInternetNodes {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading internet map…")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                } else if !viewModel.internetMapNodes.isEmpty {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(MeshTheme.accent).frame(width: 8, height: 8)
                            Text("Local mesh")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.teal.opacity(0.85)).frame(width: 8, height: 8)
                            Text("Internet map (\(viewModel.internetMapNodes.count))")
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
                    Text("Location access denied. Enable in Settings → Privacy → Location Services.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
                if mappableContacts.isEmpty && viewModel.internetMapNodes.isEmpty && !viewModel.isLoadingInternetNodes {
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
                .disabled(viewModel.isLoadingInternetNodes)
                .help("Refresh internet map nodes")
            }
        }
        .task {
            locationManager.requestPermission()
            viewModel.fetchInternetMapNodes()
        }
        .onChange(of: locationManager.currentLocation) { _, location in
            guard let location, !hasSetInitialCamera else { return }
            hasSetInitialCamera = true
            let region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: Self.initialSpanDegrees,
                    longitudeDelta: Self.initialSpanDegrees
                )
            )
            // Set both the camera and the filter region together so nodes appear immediately
            cameraPosition = .region(region)
            visibleRegion = region
        }
        // Also update visible region once nodes load (handles case where location
        // arrived before the nodes were fetched)
        .onChange(of: viewModel.internetMapNodes.count) { _, count in
            guard count > 0, visibleRegion == nil,
                  let loc = locationManager.currentLocation else { return }
            visibleRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: Self.initialSpanDegrees,
                    longitudeDelta: Self.initialSpanDegrees
                )
            )
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
    @Published var currentLocation: CLLocation? = nil

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(macOS)
            manager.requestAlwaysAuthorization()
            #else
            manager.requestWhenInUseAuthorization()
            #endif
        default:
            if isAuthorized(manager.authorizationStatus) {
                manager.requestLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if self.isAuthorized(manager.authorizationStatus) {
                manager.requestLocation()
            }
        }
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        return status == .authorized || status == .authorizedAlways
        #else
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.currentLocation = loc
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // requestLocation() failure is non-fatal — map still works without location
    }
}
#endif
