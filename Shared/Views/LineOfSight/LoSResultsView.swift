//
//  LoSResultsView.swift
//  PommeCore
//
//  Pass/fail badge, distance, clearance, and Fresnel zone summary.
//

import SwiftUI
import MeshCoreKit

struct LoSResultsView: View {
    let result: LoSResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pass/Fail header
            HStack(spacing: 10) {
                Image(systemName: result.overallPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(result.overallPass ? .green : .red)
                VStack(alignment: .leading) {
                    Text(result.overallPass ? "Line of Sight Clear" : "Line of Sight Obstructed")
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }

            // Stats grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                statCard("Distance", value: GeoMath.formatDistance(result.profile.totalDistance), icon: "ruler")
                statCard("Frequency", value: String(format: "%.1f MHz", result.frequencyMHz), icon: "antenna.radiowaves.left.and.right")
                statCard("Min Clearance", value: String(format: "%.1f m", result.directSegment.minClearance), icon: "arrow.up.and.down",
                         color: result.directSegment.minClearance >= 0 ? .green : .red)
                statCard("Fresnel Zone", value: String(format: "%.0f%%", result.directSegment.fresnelClearancePercent), icon: "circle.dashed",
                         color: fresnelColor(result.directSegment.fresnelClearancePercent))
            }

            // Endpoint elevations
            HStack(spacing: 16) {
                elevationLabel("Point A", elevation: result.profile.pointA.groundElevation, antenna: result.profile.pointA.antennaHeight)
                Spacer()
                elevationLabel("Point B", elevation: result.profile.pointB.groundElevation, antenna: result.profile.pointB.antennaHeight)
            }

            // Repeater segments (if present)
            if let arResult = result.segmentAtoRepeater, let rbResult = result.segmentRepeaterToB {
                Divider()
                Text("Relay Analysis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MeshTheme.textPrimary)

                HStack(spacing: 16) {
                    segmentSummary("A \u{2192} R", result: arResult)
                    segmentSummary("R \u{2192} B", result: rbResult)
                }
            }
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var summaryText: String {
        let direct = result.directSegment
        if direct.fresnelClearancePercent >= 60 {
            return "Full Fresnel zone clearance (\(String(format: "%.0f%%", direct.fresnelClearancePercent)))"
        } else if direct.hasLineOfSight {
            return "Partial Fresnel zone clearance — signal may be degraded"
        } else {
            return "Terrain blocks the direct path at \(GeoMath.formatDistance(direct.minClearanceDistance))"
        }
    }

    private func statCard(_ label: String, value: String, icon: String, color: Color = MeshTheme.accent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MeshTheme.textPrimary)
            }
        }
    }

    private func elevationLabel(_ label: String, elevation: Double, antenna: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
            Text("\(GeoMath.formatElevation(elevation)) + \(String(format: "%.0fm", antenna)) antenna")
                .font(.caption)
                .foregroundStyle(MeshTheme.textPrimary)
        }
    }

    private func segmentSummary(_ label: String, result: LoSSegmentResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: result.hasLineOfSight ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.hasLineOfSight ? .green : .red)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MeshTheme.textPrimary)
            }
            Text("Clearance: \(String(format: "%.1fm", result.minClearance))")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
            Text("Fresnel: \(String(format: "%.0f%%", result.fresnelClearancePercent))")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    private func fresnelColor(_ percent: Double) -> Color {
        if percent >= 60 { return .green }
        if percent >= 0 { return .orange }
        return .red
    }
}
