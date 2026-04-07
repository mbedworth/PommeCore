//
//  LineOfSightCalculator.swift
//  MeshCoreKit
//
//  Core LoS analysis engine: profile analysis, clearance computation.
//

import Foundation

public enum LineOfSightCalculator {

    /// Analyze a single path segment between two endpoints.
    public static func analyzeSegment(
        pointA: LoSEndpoint,
        pointB: LoSEndpoint,
        samples: [ElevationPoint],
        frequencyMHz: Double,
        kFactor: Double = FresnelZone.standardKFactor
    ) -> LoSSegmentResult {
        guard !samples.isEmpty else {
            return LoSSegmentResult(hasLineOfSight: false, minClearance: 0,
                                   minClearanceDistance: 0, fresnelClearancePercent: 0, samples: [])
        }

        let segmentStart = samples.first!.distanceFromStart
        let segmentEnd = samples.last!.distanceFromStart
        let segmentLength = segmentEnd - segmentStart

        var profileSamples: [ProfileSample] = []
        var worstClearance = Double.infinity
        var worstClearanceDistance: Double = 0
        var worstFresnelPercent: Double = 100

        for sample in samples {
            let dFromA = sample.distanceFromStart - segmentStart
            let dFromB = segmentLength - dFromA

            let los = FresnelZone.losHeight(
                heightA: pointA.totalHeight,
                heightB: pointB.totalHeight,
                distanceFromA: dFromA,
                totalDistance: segmentLength
            )

            let fresnel = FresnelZone.fresnelRadius(
                frequencyMHz: frequencyMHz,
                distanceFromA: dFromA,
                distanceFromB: dFromB
            )

            let bulge = FresnelZone.earthBulge(
                distanceFromA: dFromA,
                distanceFromB: dFromB,
                kFactor: kFactor
            )

            let clr = FresnelZone.clearance(
                losHeight: los,
                groundElevation: sample.elevation,
                earthBulge: bulge
            )

            let fresnelPct = FresnelZone.fresnelPercent(clearance: clr, fresnelRadius: fresnel)

            profileSamples.append(ProfileSample(
                distanceFromStart: sample.distanceFromStart,
                groundElevation: sample.elevation,
                losHeight: los,
                fresnelRadius: fresnel,
                earthBulge: bulge,
                clearance: clr,
                fresnelPercent: fresnelPct
            ))

            if clr < worstClearance {
                worstClearance = clr
                worstClearanceDistance = sample.distanceFromStart
                worstFresnelPercent = fresnelPct
            }
        }

        return LoSSegmentResult(
            hasLineOfSight: worstClearance >= 0,
            minClearance: worstClearance,
            minClearanceDistance: worstClearanceDistance,
            fresnelClearancePercent: worstFresnelPercent,
            samples: profileSamples
        )
    }

    /// Full LoS analysis. If a repeater is present, analyzes A→Repeater and Repeater→B separately.
    public static func analyze(
        profile: TerrainProfile,
        frequencyMHz: Double,
        kFactor: Double = FresnelZone.standardKFactor
    ) -> LoSResult {
        // Direct A→B analysis
        let directResult = analyzeSegment(
            pointA: profile.pointA,
            pointB: profile.pointB,
            samples: profile.samples,
            frequencyMHz: frequencyMHz,
            kFactor: kFactor
        )

        // If no repeater, return direct result only
        guard let repeater = profile.repeater else {
            return LoSResult(
                profile: profile,
                directSegment: directResult,
                segmentAtoRepeater: nil,
                segmentRepeaterToB: nil,
                overallPass: directResult.hasLineOfSight && directResult.fresnelClearancePercent >= 60,
                frequencyMHz: frequencyMHz
            )
        }

        // Find the repeater's position in the sample array
        let repeaterDistance = GeoMath.haversineDistance(
            lat1: profile.pointA.latitude, lon1: profile.pointA.longitude,
            lat2: repeater.latitude, lon2: repeater.longitude
        )

        // Split samples at the repeater distance
        let samplesAtoR = profile.samples.filter { $0.distanceFromStart <= repeaterDistance }
        let samplesRtoB = profile.samples.filter { $0.distanceFromStart >= repeaterDistance }

        let segmentAR = analyzeSegment(
            pointA: profile.pointA,
            pointB: repeater,
            samples: samplesAtoR,
            frequencyMHz: frequencyMHz,
            kFactor: kFactor
        )

        let segmentRB = analyzeSegment(
            pointA: repeater,
            pointB: profile.pointB,
            samples: samplesRtoB,
            frequencyMHz: frequencyMHz,
            kFactor: kFactor
        )

        let arPass = segmentAR.hasLineOfSight && segmentAR.fresnelClearancePercent >= 60
        let rbPass = segmentRB.hasLineOfSight && segmentRB.fresnelClearancePercent >= 60

        return LoSResult(
            profile: profile,
            directSegment: directResult,
            segmentAtoRepeater: segmentAR,
            segmentRepeaterToB: segmentRB,
            overallPass: arPass && rbPass,
            frequencyMHz: frequencyMHz
        )
    }
}
