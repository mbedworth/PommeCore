//
//  LineOfSightStore.swift
//  PommeCore
//
//  @Observable store for Line of Sight terrain analysis state.
//

import Foundation
import CoreLocation
import MeshCoreKit

/// Source for selecting an LoS endpoint.
enum LoSPointSource: String, CaseIterable {
    case gps = "My Location"
    case contact = "Contact"
    case mapPin = "Map Pin"
}

/// Source for repeater placement.
enum RepeaterSource {
    case slider
    case contact
}

@MainActor @Observable
final class LineOfSightStore {

    // MARK: - Point Selection

    var pointASource: LoSPointSource = .gps
    var pointBSource: LoSPointSource = .contact
    var pointAContact: Contact?
    var pointBContact: Contact?
    var pointAMapPin: CLLocationCoordinate2D?
    var pointBMapPin: CLLocationCoordinate2D?

    // MARK: - Repeater

    var repeaterEnabled = false
    var repeaterSource: RepeaterSource = .slider
    var repeaterSliderFraction: Double = 0.5
    var repeaterContact: Contact?
    var repeaterAntennaHeight: Double = 7.0

    // MARK: - Settings

    var antennaHeightA: Double = 7.0
    var antennaHeightB: Double = 7.0
    var frequencyMHz: Double = 910.525
    var manualFrequencyOverride = false

    // MARK: - State

    var isAnalyzing = false
    var currentResult: LoSResult?
    var errorMessage: String?

    // MARK: - Dependencies

    var userLocationProvider: (() -> CLLocation?)?

    // MARK: - Session Cache

    private var resultCache: [String: LoSResult] = [:]

    // MARK: - Public Methods

    func loadFromDeviceConfig(_ config: DeviceConfig) {
        guard !manualFrequencyOverride else { return }
        frequencyMHz = config.frequencyMHz
    }

    /// Pre-configure for analyzing path to a specific contact.
    func configureForContact(_ contact: Contact) {
        pointASource = .gps
        pointBSource = .contact
        pointBContact = contact
        currentResult = nil
        errorMessage = nil
    }

    /// Pre-configure for two map pins.
    func configureForMapPins(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) {
        pointASource = .mapPin
        pointBSource = .mapPin
        pointAMapPin = a
        pointBMapPin = b
        currentResult = nil
        errorMessage = nil
    }

    /// Resolve the configured points to lat/lon coordinates.
    func resolveCoordinates() -> (latA: Double, lonA: Double, latB: Double, lonB: Double)? {
        guard let a = resolvePoint(pointASource, contact: pointAContact, mapPin: pointAMapPin),
              let b = resolvePoint(pointBSource, contact: pointBContact, mapPin: pointBMapPin) else {
            return nil
        }
        return (a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Run the full LoS analysis.
    func runAnalysis() async {
        guard let coords = resolveCoordinates() else {
            errorMessage = "Select both points before analyzing."
            return
        }

        // Check cache
        let key = cacheKey(coords)
        if let cached = resultCache[key] {
            currentResult = cached
            return
        }

        isAnalyzing = true
        errorMessage = nil
        currentResult = nil

        do {
            // Resolve repeater coordinates
            var rLat: Double?, rLon: Double?, rHeight: Double?
            if repeaterEnabled {
                if let rCoord = resolveRepeater(coords) {
                    rLat = rCoord.latitude
                    rLon = rCoord.longitude
                    rHeight = repeaterAntennaHeight
                }
            }

            let profile = try await ElevationService.shared.buildTerrainProfile(
                latA: coords.latA, lonA: coords.lonA, antennaHeightA: antennaHeightA,
                latB: coords.latB, lonB: coords.lonB, antennaHeightB: antennaHeightB,
                repeaterLat: rLat, repeaterLon: rLon, repeaterAntennaHeight: rHeight
            )

            let result = LineOfSightCalculator.analyze(
                profile: profile,
                frequencyMHz: frequencyMHz
            )

            currentResult = result
            resultCache[key] = result
            isAnalyzing = false
        } catch {
            errorMessage = error.localizedDescription
            isAnalyzing = false
        }
    }

    func clearResults() {
        currentResult = nil
        errorMessage = nil
        resultCache.removeAll()
    }

    func clearCache() {
        resultCache.removeAll()
    }

    // MARK: - Private

    private func resolvePoint(_ source: LoSPointSource, contact: Contact?, mapPin: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        switch source {
        case .gps:
            guard let loc = userLocationProvider?() else { return nil }
            return loc.coordinate
        case .contact:
            guard let c = contact, c.latitude != 0 || c.longitude != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        case .mapPin:
            return mapPin
        }
    }

    private func resolveRepeater(_ coords: (latA: Double, lonA: Double, latB: Double, lonB: Double)) -> CLLocationCoordinate2D? {
        switch repeaterSource {
        case .slider:
            let pt = GeoMath.intermediatePoint(
                lat1: coords.latA, lon1: coords.lonA,
                lat2: coords.latB, lon2: coords.lonB,
                fraction: repeaterSliderFraction
            )
            return CLLocationCoordinate2D(latitude: pt.latitude, longitude: pt.longitude)
        case .contact:
            guard let c = repeaterContact, c.latitude != 0 || c.longitude != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        }
    }

    private func cacheKey(_ c: (latA: Double, lonA: Double, latB: Double, lonB: Double)) -> String {
        String(format: "%.4f,%.4f->%.4f,%.4f@%.1f", c.latA, c.lonA, c.latB, c.lonB, frequencyMHz)
    }
}
