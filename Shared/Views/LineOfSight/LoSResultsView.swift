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

            // Stats grid — show relay worst-case when repeater is active
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                statCard("Distance", value: GeoMath.formatDistance(result.profile.totalDistance), icon: "ruler")
                statCard("Frequency", value: String(format: "%.1f MHz", result.frequencyMHz), icon: "antenna.radiowaves.left.and.right")

                if hasRelay, let ar = result.segmentAtoRepeater, let rb = result.segmentRepeaterToB {
                    let worstClearance = min(ar.minClearance, rb.minClearance)
                    let worstFresnel = min(ar.fresnelClearancePercent, rb.fresnelClearancePercent)
                    statCard("Min Clearance", value: String(format: "%.1f m", worstClearance), icon: "arrow.up.and.down",
                             color: worstClearance >= 0 ? .green : .red)
                    statCard("Fresnel Zone", value: String(format: "%.0f%%", worstFresnel), icon: "circle.dashed",
                             color: fresnelColor(worstFresnel))
                } else {
                    statCard("Min Clearance", value: String(format: "%.1f m", result.directSegment.minClearance), icon: "arrow.up.and.down",
                             color: result.directSegment.minClearance >= 0 ? .green : .red)
                    statCard("Fresnel Zone", value: String(format: "%.0f%%", result.directSegment.fresnelClearancePercent), icon: "circle.dashed",
                             color: fresnelColor(result.directSegment.fresnelClearancePercent))
                }
            }

            // Direct path note when relay is active
            if hasRelay && !result.directSegment.hasLineOfSight {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Direct path blocked — relay required")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
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
                    .foregroundStyle(MeshTheme.accent)

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

    private var hasRelay: Bool {
        result.segmentAtoRepeater != nil
    }

    private var summaryText: String {
        if hasRelay {
            if result.overallPass {
                return "Relay path clear — both segments have adequate Fresnel clearance"
            } else {
                let arOk = result.segmentAtoRepeater?.fresnelClearancePercent ?? 0 >= 60
                let rbOk = result.segmentRepeaterToB?.fresnelClearancePercent ?? 0 >= 60
                if !arOk && !rbOk { return "Both relay segments are obstructed" }
                if !arOk { return "A \u{2192} Repeater segment is obstructed" }
                return "Repeater \u{2192} B segment is obstructed"
            }
        }
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
                    .foregroundStyle(MeshTheme.textSecondary)
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
                .foregroundStyle(MeshTheme.textSecondary)
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
                    .foregroundStyle(MeshTheme.accent)
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
