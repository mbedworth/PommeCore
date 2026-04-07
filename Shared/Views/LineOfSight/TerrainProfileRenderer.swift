//
//  TerrainProfileRenderer.swift
//  PommeCore
//
//  Pure drawing logic for the terrain profile canvas.
//  Extracted from Canvas view for testability and separation of concerns.
//

import SwiftUI
import MeshCoreKit

enum TerrainProfileRenderer {

    struct Layout {
        let canvasSize: CGSize
        let margin: EdgeInsets
        let plotWidth: CGFloat
        let plotHeight: CGFloat
        let minElevation: Double
        let maxElevation: Double
        let totalDistance: Double
        let elevationRange: Double

        init(size: CGSize, samples: [ProfileSample], profile: TerrainProfile) {
            canvasSize = size
            margin = EdgeInsets(top: 30, leading: 50, bottom: 30, trailing: 20)
            plotWidth = size.width - margin.leading - margin.trailing
            plotHeight = size.height - margin.top - margin.bottom
            totalDistance = profile.totalDistance

            // Find elevation range across terrain and LoS line
            let terrainMin = samples.map(\.groundElevation).min() ?? 0
            let terrainMax = samples.map(\.groundElevation).max() ?? 0
            let losMax = samples.map(\.losHeight).max() ?? 0
            let fresnelTop = samples.map { $0.losHeight + $0.fresnelRadius }.max() ?? 0

            let dataMin = terrainMin
            let dataMax = max(terrainMax, losMax, fresnelTop)
            let padding = max((dataMax - dataMin) * 0.15, 10)

            minElevation = dataMin - padding
            maxElevation = dataMax + padding
            elevationRange = maxElevation - minElevation
        }

        func xForDistance(_ d: Double) -> CGFloat {
            guard totalDistance > 0 else { return margin.leading }
            return margin.leading + plotWidth * CGFloat(d / totalDistance)
        }

        func yForElevation(_ e: Double) -> CGFloat {
            guard elevationRange > 0 else { return margin.top + plotHeight / 2 }
            return margin.top + plotHeight * CGFloat(1 - (e - minElevation) / elevationRange)
        }
    }

    // MARK: - Main Draw

    static func draw(
        result: LoSResult,
        in size: CGSize,
        context: inout GraphicsContext,
        scrubX: CGFloat? = nil
    ) {
        let samples = result.directSegment.samples
        guard samples.count >= 2 else { return }

        let layout = Layout(size: size, samples: samples, profile: result.profile)

        drawSkyGradient(context: &context, layout: layout)
        drawTerrainFill(context: &context, layout: layout, samples: samples)
        drawTerrainOutline(context: &context, layout: layout, samples: samples)
        drawFresnelZone(context: &context, layout: layout, samples: samples)
        drawLoSLine(context: &context, layout: layout, result: result)
        drawEndpointMarkers(context: &context, layout: layout, result: result)

        if let repeater = result.profile.repeater {
            drawRepeaterMarker(context: &context, layout: layout, repeater: repeater, profile: result.profile)
        }

        drawAxisLabels(context: &context, layout: layout)

        if let x = scrubX {
            drawScrubLine(context: &context, layout: layout, samples: samples, x: x)
        }
    }

    // MARK: - Sky Gradient

    private static func drawSkyGradient(context: inout GraphicsContext, layout: Layout) {
        let rect = CGRect(x: 0, y: 0, width: layout.canvasSize.width, height: layout.canvasSize.height)
        let gradient = Gradient(colors: [
            Color(red: 0.53, green: 0.81, blue: 0.92).opacity(0.3),
            Color(red: 0.68, green: 0.85, blue: 0.90).opacity(0.1)
        ])
        context.fill(Path(rect), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: layout.canvasSize.height)))
    }

    // MARK: - Terrain Fill

    private static func drawTerrainFill(context: inout GraphicsContext, layout: Layout, samples: [ProfileSample]) {
        var path = Path()
        let bottomY = layout.margin.top + layout.plotHeight

        path.move(to: CGPoint(x: layout.xForDistance(samples[0].distanceFromStart), y: bottomY))
        for sample in samples {
            let x = layout.xForDistance(sample.distanceFromStart)
            let y = layout.yForElevation(sample.groundElevation)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: layout.xForDistance(samples.last!.distanceFromStart), y: bottomY))
        path.closeSubpath()

        let gradient = Gradient(colors: [
            Color(red: 0.4, green: 0.6, blue: 0.3),
            Color(red: 0.55, green: 0.45, blue: 0.3)
        ])
        context.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: layout.margin.top), endPoint: CGPoint(x: 0, y: bottomY)))
    }

    // MARK: - Terrain Outline

    private static func drawTerrainOutline(context: inout GraphicsContext, layout: Layout, samples: [ProfileSample]) {
        var path = Path()
        for (i, sample) in samples.enumerated() {
            let pt = CGPoint(x: layout.xForDistance(sample.distanceFromStart),
                             y: layout.yForElevation(sample.groundElevation))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        context.stroke(path, with: .color(.primary.opacity(0.4)), lineWidth: 1.5)
    }

    // MARK: - Fresnel Zone

    private static func drawFresnelZone(context: inout GraphicsContext, layout: Layout, samples: [ProfileSample]) {
        guard samples.count >= 2 else { return }

        // Upper boundary of Fresnel zone
        var upperPath = Path()
        var lowerPath = Path()
        for (i, sample) in samples.enumerated() {
            let x = layout.xForDistance(sample.distanceFromStart)
            let yLos = layout.yForElevation(sample.losHeight)
            let fresnelPixels = max(layout.plotHeight * CGFloat(sample.fresnelRadius / layout.elevationRange), 0)

            let upperPt = CGPoint(x: x, y: yLos - fresnelPixels)
            let lowerPt = CGPoint(x: x, y: yLos + fresnelPixels)

            if i == 0 {
                upperPath.move(to: upperPt)
                lowerPath.move(to: lowerPt)
            } else {
                upperPath.addLine(to: upperPt)
                lowerPath.addLine(to: lowerPt)
            }
        }

        // Fill Fresnel zone as a shape between upper and lower paths
        var zonePath = upperPath
        for sample in samples.reversed() {
            let x = layout.xForDistance(sample.distanceFromStart)
            let yLos = layout.yForElevation(sample.losHeight)
            let fresnelPixels = max(layout.plotHeight * CGFloat(sample.fresnelRadius / layout.elevationRange), 0)
            zonePath.addLine(to: CGPoint(x: x, y: yLos + fresnelPixels))
        }
        zonePath.closeSubpath()

        // Color based on worst clearance
        let worstPercent = samples.map(\.fresnelPercent).min() ?? 100
        let zoneColor: Color = worstPercent >= 60 ? .green : worstPercent >= 0 ? .orange : .red
        context.fill(zonePath, with: .color(zoneColor.opacity(0.15)))
        context.stroke(zonePath, with: .color(zoneColor.opacity(0.3)), lineWidth: 0.5)
    }

    // MARK: - LoS Line

    private static func drawLoSLine(context: inout GraphicsContext, layout: Layout, result: LoSResult) {
        let ptA = CGPoint(
            x: layout.xForDistance(0),
            y: layout.yForElevation(result.profile.pointA.totalHeight)
        )
        let ptB = CGPoint(
            x: layout.xForDistance(result.profile.totalDistance),
            y: layout.yForElevation(result.profile.pointB.totalHeight)
        )

        var path = Path()
        path.move(to: ptA)
        path.addLine(to: ptB)

        let color: Color = result.directSegment.hasLineOfSight ? .green : .red
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
    }

    // MARK: - Endpoint Markers

    private static func drawEndpointMarkers(context: inout GraphicsContext, layout: Layout, result: LoSResult) {
        let profile = result.profile

        // Point A
        let xA = layout.xForDistance(0)
        let yGroundA = layout.yForElevation(profile.pointA.groundElevation)
        let yAntennaA = layout.yForElevation(profile.pointA.totalHeight)
        drawAntennaMarker(context: &context, x: xA, yGround: yGroundA, yAntenna: yAntennaA, label: "A", color: .blue)

        // Point B
        let xB = layout.xForDistance(profile.totalDistance)
        let yGroundB = layout.yForElevation(profile.pointB.groundElevation)
        let yAntennaB = layout.yForElevation(profile.pointB.totalHeight)
        drawAntennaMarker(context: &context, x: xB, yGround: yGroundB, yAntenna: yAntennaB, label: "B", color: .blue)
    }

    private static func drawAntennaMarker(context: inout GraphicsContext, x: CGFloat, yGround: CGFloat, yAntenna: CGFloat, label: String, color: Color) {
        // Vertical antenna line
        var path = Path()
        path.move(to: CGPoint(x: x, y: yGround))
        path.addLine(to: CGPoint(x: x, y: yAntenna))
        context.stroke(path, with: .color(color), lineWidth: 2)

        // Antenna tip dot
        let dot = Path(ellipseIn: CGRect(x: x - 4, y: yAntenna - 4, width: 8, height: 8))
        context.fill(dot, with: .color(color))

        // Label
        let text = Text(label).font(.caption.bold()).foregroundColor(color)
        context.draw(text, at: CGPoint(x: x, y: yAntenna - 14), anchor: .bottom)
    }

    // MARK: - Repeater Marker

    private static func drawRepeaterMarker(context: inout GraphicsContext, layout: Layout, repeater: LoSEndpoint, profile: TerrainProfile) {
        let dist = GeoMath.haversineDistance(
            lat1: profile.pointA.latitude, lon1: profile.pointA.longitude,
            lat2: repeater.latitude, lon2: repeater.longitude
        )
        let x = layout.xForDistance(dist)
        let yGround = layout.yForElevation(repeater.groundElevation)
        let yAntenna = layout.yForElevation(repeater.totalHeight)

        drawAntennaMarker(context: &context, x: x, yGround: yGround, yAntenna: yAntenna, label: "R", color: .orange)
    }

    // MARK: - Axis Labels

    private static func drawAxisLabels(context: inout GraphicsContext, layout: Layout) {
        // Distance labels along bottom
        let distSteps = 5
        for i in 0...distSteps {
            let dist = layout.totalDistance * Double(i) / Double(distSteps)
            let x = layout.xForDistance(dist)
            let label = GeoMath.formatDistance(dist)
            let text = Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            context.draw(text, at: CGPoint(x: x, y: layout.canvasSize.height - 5), anchor: .bottom)
        }

        // Elevation labels along left
        let elevSteps = 4
        for i in 0...elevSteps {
            let elev = layout.minElevation + layout.elevationRange * Double(i) / Double(elevSteps)
            let y = layout.yForElevation(elev)
            let label = GeoMath.formatElevation(elev)
            let text = Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            context.draw(text, at: CGPoint(x: layout.margin.leading - 5, y: y), anchor: .trailing)
        }
    }

    // MARK: - Scrub Line

    private static func drawScrubLine(context: inout GraphicsContext, layout: Layout, samples: [ProfileSample], x: CGFloat) {
        guard x >= layout.margin.leading, x <= layout.margin.leading + layout.plotWidth else { return }

        // Find nearest sample
        let fraction = Double(x - layout.margin.leading) / Double(layout.plotWidth)
        let targetDist = fraction * layout.totalDistance
        guard let nearest = samples.min(by: { abs($0.distanceFromStart - targetDist) < abs($1.distanceFromStart - targetDist) }) else { return }

        // Vertical scrub line
        var line = Path()
        line.move(to: CGPoint(x: x, y: layout.margin.top))
        line.addLine(to: CGPoint(x: x, y: layout.margin.top + layout.plotHeight))
        context.stroke(line, with: .color(.primary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

        // Tooltip
        let elev = String(format: "%.0fm", nearest.groundElevation)
        let clr = String(format: "%.1fm", nearest.clearance)
        let pct = String(format: "%.0f%%", nearest.fresnelPercent)
        let tooltipText = Text("\(elev) | Clr: \(clr) | F1: \(pct)")
            .font(.system(size: 10).monospaced())
            .foregroundColor(.primary)

        // Background for tooltip
        let tooltipY = layout.margin.top - 5
        context.draw(tooltipText, at: CGPoint(x: x, y: tooltipY), anchor: .bottom)
    }
}
