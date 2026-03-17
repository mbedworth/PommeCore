#if !os(watchOS)
import SwiftUI
import MapKit
import CoreLocation
import MeshCoreKit

@available(iOS 17.0, macOS 14.0, *)
struct MeshMapView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @StateObject private var locationManager = LocationManager()

    private var mappableContacts: [Contact] {
        let mapped = viewModel.contacts.filter { $0.latitude != 0 || $0.longitude != 0 }
        return mapped
    }

    var body: some View {

        ZStack {
            Map {
                ForEach(mappableContacts) { contact in
                    Annotation(viewModel.displayName(for: contact),
                               coordinate: CLLocationCoordinate2D(
                                   latitude: contact.latitude,
                                   longitude: contact.longitude
                               )) {
                        VStack(spacing: 2) {
                            Image(systemName: contactTypeIcon(contact))
                                .foregroundStyle(contactTypeColor(contact))
                                .font(.title2)
                                .padding(6)
                                .background(Circle().fill(.background))
                                .shadow(radius: 2)
                            Text(viewModel.displayName(for: contact))
                                .font(.caption2)
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
                Spacer()
                if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
                    Text("Location access denied. Enable in Settings \u{2192} Privacy \u{2192} Location Services.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
                if mappableContacts.isEmpty {
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
        .onAppear {
            locationManager.requestPermission()
        }
    }

    private func contactTypeIcon(_ contact: Contact) -> String {
        switch contact.type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "building.2.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func contactTypeColor(_ contact: Contact) -> Color {
        switch contact.type {
        case .chat: return .blue
        case .repeater: return MeshTheme.accent
        case .room: return .purple
        case .unknown: return .gray
        }
    }
}

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
