#if !os(watchOS)
import SwiftUI
import MapKit
import MeshCoreKit

@available(iOS 17.0, macOS 14.0, *)
struct MeshMapView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel

    private var mappableContacts: [Contact] {
        viewModel.contacts.filter { $0.latitude != 0 || $0.longitude != 0 }
    }

    var body: some View {
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
        .overlay(alignment: .bottom) {
            if mappableContacts.isEmpty {
                Text("No contacts with location data")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .navigationTitle("Map")
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
#endif
