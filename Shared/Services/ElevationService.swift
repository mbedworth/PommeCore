//
//  ElevationService.swift
//  PommeCore
//
//  Open-Meteo API client for terrain elevation data.
//  Free API, no key required, max 100 points per request.
//
//  Created by Michael P. Bedworth on 04/06/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import os.log
import MeshCoreKit

actor ElevationService {
    static let shared = ElevationService()

    private static let logger = Logger(subsystem: "com.pommecore", category: "Elevation")
    private static let apiEndpoint = "https://api.open-meteo.com/v1/elevation"
    private static let maxPointsPerRequest = 100
    private static let maxRetries = 3

    /// Per-request timeout.
    ///
    /// URLSession's default is 60s. With `maxRetries` attempts per batch and
    /// batches fetched one after another, a long line-of-sight profile could
    /// sit unresponsive for several minutes before failing. The users of this
    /// app are frequently on poor or absent connectivity — that is the point
    /// of a mesh radio — so failing quickly matters more here than persisting.
    /// Matches the explicit timeouts the sibling services already set.
    private static let requestTimeout: TimeInterval = 10

    /// Cached elevations, keyed to roughly 110m resolution.
    ///
    /// Capped because the key space is continuous: each line-of-sight analysis
    /// over new terrain adds up to several hundred entries that are never
    /// evicted, so a long session over a wide area grows this without limit.
    private var cache: [String: Double] = [:]
    private static let maxCachedPoints = 10_000

    enum ElevationError: Error, LocalizedError {
        case networkError(String)
        case invalidResponse
        case apiError(String)
        case tooManyPoints

        var errorDescription: String? {
            switch self {
            case .networkError(let msg): return "Network error: \(msg)"
            case .invalidResponse: return "Invalid response from elevation API"
            case .apiError(let msg): return "Elevation API error: \(msg)"
            case .tooManyPoints: return "Too many elevation points requested"
            }
        }
    }

    // MARK: - Public API

    /// Fetch elevations for an array of coordinates. Returns elevations in same order.
    func fetchElevations(
        coordinates: [(latitude: Double, longitude: Double)]
    ) async throws -> [Double] {
        guard !coordinates.isEmpty else { return [] }

        // Check cache first
        var results = [Double?](repeating: nil, count: coordinates.count)
        var uncachedIndices: [Int] = []

        for (i, coord) in coordinates.enumerated() {
            if let cached = cache[cacheKey(coord.latitude, coord.longitude)] {
                results[i] = cached
            } else {
                uncachedIndices.append(i)
            }
        }

        // Fetch uncached in batches of 100
        if !uncachedIndices.isEmpty {
            let batches = stride(from: 0, to: uncachedIndices.count, by: Self.maxPointsPerRequest).map {
                Array(uncachedIndices[$0..<min($0 + Self.maxPointsPerRequest, uncachedIndices.count)])
            }

            for batch in batches {
                let batchCoords = batch.map { coordinates[$0] }
                let elevations = try await fetchBatch(batchCoords)

                for (j, idx) in batch.enumerated() where j < elevations.count {
                    results[idx] = elevations[j]
                    let coord = coordinates[idx]
                    cache[cacheKey(coord.latitude, coord.longitude)] = elevations[j]
                }
                evictCacheIfNeeded()
            }
        }

        return results.map { $0 ?? 0 }
    }

    /// Build a complete terrain profile between two endpoints with optional relay points.
    /// Relays are provided as an ordered array from A to B — the service fetches their
    /// elevations in the same batch as the terrain samples.
    func buildTerrainProfile(
        latA: Double, lonA: Double, antennaHeightA: Double,
        latB: Double, lonB: Double, antennaHeightB: Double,
        relays: [(lat: Double, lon: Double, antennaHeight: Double)] = []
    ) async throws -> TerrainProfile {
        let totalDistance = GeoMath.haversineDistance(lat1: latA, lon1: lonA, lat2: latB, lon2: lonB)
        let sampleCount = GeoMath.adaptiveSampleCount(distanceMeters: totalDistance)
        let sampleCoords = GeoMath.samplePoints(lat1: latA, lon1: lonA, lat2: latB, lon2: lonB, count: sampleCount)

        // Append relay coordinates after the terrain samples so indices are predictable
        var allCoords = sampleCoords
        for relay in relays {
            allCoords.append((relay.lat, relay.lon))
        }

        let elevations = try await fetchElevations(coordinates: allCoords)

        // Build elevation points
        var samples: [ElevationPoint] = []
        for (i, coord) in sampleCoords.enumerated() where i < elevations.count {
            let dist = GeoMath.haversineDistance(lat1: latA, lon1: lonA, lat2: coord.latitude, lon2: coord.longitude)
            samples.append(ElevationPoint(
                latitude: coord.latitude,
                longitude: coord.longitude,
                elevation: elevations[i],
                distanceFromStart: dist
            ))
        }

        let pointA = LoSEndpoint(latitude: latA, longitude: lonA,
                                  groundElevation: elevations.first ?? 0,
                                  antennaHeight: antennaHeightA)
        let pointB = LoSEndpoint(latitude: latB, longitude: lonB,
                                  groundElevation: elevations[sampleCount - 1],
                                  antennaHeight: antennaHeightB)

        var repeaterEndpoints: [LoSEndpoint] = []
        for (i, relay) in relays.enumerated() {
            let elevIdx = sampleCount + i
            let rElevation = elevIdx < elevations.count ? elevations[elevIdx] : 0
            repeaterEndpoints.append(LoSEndpoint(
                latitude: relay.lat, longitude: relay.lon,
                groundElevation: rElevation,
                antennaHeight: relay.antennaHeight
            ))
        }

        return TerrainProfile(pointA: pointA, pointB: pointB, repeaters: repeaterEndpoints,
                              samples: samples, totalDistance: totalDistance)
    }

    /// Clear the elevation cache.
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func cacheKey(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.3f,%.3f", lat, lon)
    }

    /// Drop cached points once over the cap.
    ///
    /// Elevation does not change, so any entry is as valid as any other and
    /// there is no recency to preserve — this keeps the memory bounded without
    /// pretending to be an LRU. Terrain just gets re-fetched if revisited.
    private func evictCacheIfNeeded() {
        guard cache.count > Self.maxCachedPoints else { return }
        let excess = cache.count - Self.maxCachedPoints
        for key in cache.keys.prefix(excess) {
            cache.removeValue(forKey: key)
        }
        Self.logger.debug("Elevation cache trimmed to \(self.cache.count) points")
    }

    private func fetchBatch(_ coordinates: [(latitude: Double, longitude: Double)]) async throws -> [Double] {
        let lats = coordinates.map { String(format: "%.6f", $0.latitude) }.joined(separator: ",")
        let lons = coordinates.map { String(format: "%.6f", $0.longitude) }.joined(separator: ",")
        let urlString = "\(Self.apiEndpoint)?latitude=\(lats)&longitude=\(lons)"

        guard let url = URL(string: urlString) else {
            throw ElevationError.invalidResponse
        }

        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = Self.requestTimeout
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ElevationError.invalidResponse
                }

                if httpResponse.statusCode == 429 {
                    // Rate limited — wait and retry
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                    lastError = ElevationError.apiError("Rate limited")
                    continue
                }

                guard httpResponse.statusCode == 200 else {
                    throw ElevationError.apiError("HTTP \(httpResponse.statusCode)")
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elevations = json["elevation"] as? [Double] else {
                    throw ElevationError.invalidResponse
                }

                Self.logger.debug("Fetched \(elevations.count) elevations")
                return elevations

            } catch let error as ElevationError {
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            } catch {
                lastError = ElevationError.networkError(error.localizedDescription)
                if attempt < Self.maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError ?? ElevationError.networkError("Unknown error")
    }
}
