//
//  MapPointPickerView.swift
//  PommeCore
//
//  Full-screen map with tap-to-drop-pin for selecting LoS endpoints.
//

#if !os(watchOS)
import SwiftUI
import MapKit

struct MapPointPickerView: View {
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pinLocation: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let pin = pinLocation {
                            Annotation("Selected", coordinate: pin) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.red)
                            }
                        }
                        UserAnnotation()
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .onTapGesture { screenPoint in
                        if let coordinate = proxy.convert(screenPoint, from: .local) {
                            pinLocation = coordinate
                        }
                    }
                }

                // Instruction overlay
                if pinLocation == nil {
                    VStack {
                        Spacer()
                        Text("Tap the map to place a pin")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Select Location")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        selectedCoordinate = pinLocation
                        dismiss()
                    }
                    .disabled(pinLocation == nil)
                }
            }
        }
        .onAppear {
            if let existing = selectedCoordinate {
                pinLocation = existing
                cameraPosition = .region(MKCoordinateRegion(
                    center: existing,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))
            }
        }
    }
}
#endif
