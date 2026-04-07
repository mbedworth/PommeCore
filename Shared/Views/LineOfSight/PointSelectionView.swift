//
//  PointSelectionView.swift
//  PommeCore
//
//  Reusable picker for selecting an LoS endpoint: GPS, Contact, or Map Pin.
//

import SwiftUI
import CoreLocation
import MeshCoreKit

struct PointSelectionView: View {
    let label: String
    @Binding var source: LoSPointSource
    @Binding var contact: Contact?
    @Binding var mapPin: CLLocationCoordinate2D?
    @State private var showMapPicker = false

    @Environment(ContactStore.self) private var contactStore
    @Environment(LineOfSightStore.self) private var store

    private var contactsWithLocation: [Contact] {
        contactStore.contacts.filter { $0.latitude != 0 || $0.longitude != 0 }
    }

    var body: some View {
        Section {
            Picker(label, selection: $source) {
                ForEach(LoSPointSource.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(MeshTheme.surface)

            switch source {
            case .gps:
                if let loc = store.userLocationProvider?() {
                    coordinateRow(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
                } else {
                    HStack {
                        Image(systemName: "location.slash")
                            .foregroundStyle(.orange)
                        Text("Location unavailable")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(MeshTheme.surface)
                }

            case .contact:
                if contactsWithLocation.isEmpty {
                    Text("No contacts with GPS coordinates")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .listRowBackground(MeshTheme.surface)
                } else {
                    Picker("Contact", selection: $contact) {
                        Text("Select...").tag(Contact?.none)
                        ForEach(contactsWithLocation, id: \.publicKey) { c in
                            HStack {
                                Text(contactStore.displayName(for: c))
                                if c.type == .repeater {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.caption2)
                                        .foregroundStyle(MeshTheme.textSecondary)
                                }
                            }
                            .tag(Contact?.some(c))
                        }
                    }
                    .listRowBackground(MeshTheme.surface)

                    if let c = contact {
                        coordinateRow(lat: c.latitude, lon: c.longitude)
                    }
                }

            case .mapPin:
                if let pin = mapPin {
                    coordinateRow(lat: pin.latitude, lon: pin.longitude)
                }
                Button {
                    showMapPicker = true
                } label: {
                    Label(mapPin == nil ? "Drop Pin on Map" : "Change Pin", systemImage: "mappin.and.ellipse")
                        .foregroundStyle(MeshTheme.accent)
                }
                .listRowBackground(MeshTheme.surface)
                #if !os(watchOS)
                .sheet(isPresented: $showMapPicker) {
                    MapPointPickerView(selectedCoordinate: $mapPin)
                }
                #endif
            }
        } header: {
            Text(label)
        }
    }

    private func coordinateRow(lat: Double, lon: Double) -> some View {
        HStack {
            Image(systemName: "location")
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Text(String(format: "%.6f, %.6f", lat, lon))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MeshTheme.textPrimary)
        }
        .listRowBackground(MeshTheme.surface)
    }
}
