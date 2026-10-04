//
//  SensorDashboardView.swift
//  PommeCore
//
//  Every node's telemetry on one screen, one chart per measurement.
//
//  Created by Michael P. Bedworth on 10/4/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

#if !os(watchOS)
import SwiftUI
import Charts
import MeshCoreKit

/// All collected telemetry, grouped by what is being measured rather than by node.
///
/// `TelemetryChartView` answers "what has this node been reporting". This answers
/// the question the per-contact chart cannot: "how do my nodes compare" — which
/// battery is sagging, which site is hottest — by putting every node that reports
/// a given measurement on one set of axes.
///
/// Read-only. It draws the history already on disk and sends nothing to the mesh,
/// so it works with the radio disconnected and costs no airtime.
struct SensorDashboardView: View {
    @Environment(RFMonitorStore.self) private var rfStore
    @Environment(ContactStore.self) private var contactStore
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var range: TimeRange = .day

    /// How far back the charts reach.
    private enum TimeRange: String, CaseIterable, Identifiable {
        case hour, day, week

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .hour: return "1 hour"
            case .day: return "24 hours"
            case .week: return "7 days"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .hour: return 3600
            case .day: return 86_400
            case .week: return 604_800
            }
        }
    }

    // MARK: - Shaping the history

    /// One node's readings of one measurement.
    private struct NodeSeries: Identifiable {
        let contactKey: Data
        let nodeName: String
        let series: TelemetrySeries
        let unit: String
        let points: [(date: Date, value: Double)]

        var id: String { "\(contactKey.hexCompact)|\(series.key)" }
        var latest: (date: Date, value: Double)? { points.last }
    }

    /// Every node reporting the same measurement.
    private struct MetricGroup: Identifiable {
        let name: String
        let label: String
        let unit: String
        let series: [NodeSeries]

        var id: String { name }
    }

    /// Measurements that lead the list when present. Everything else follows
    /// alphabetically, so a new LPP type the firmware adds still appears without
    /// a code change here.
    private static let preferredOrder = ["Battery", "Temperature", "Humidity", "Pressure"]

    private var groups: [MetricGroup] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        var byMetric: [String: [NodeSeries]] = [:]

        // Indexed once: a linear search per history key is quadratic in the
        // contact list, and both sides grow together on a busy mesh.
        let contactsByPrefix = Dictionary(
            contactStore.contacts.map { ($0.publicKeyPrefix, $0) },
            uniquingKeysWith: { first, _ in first })

        for contactKey in rfStore.telemetryHistory.keys {
            let contact = contactsByPrefix[contactKey]
            // History can outlive its contact, so fall back to the key prefix
            // rather than dropping readings that were really collected.
            //
            // Deleting a contact *does* purge its telemetry
            // (ContactStore.purgeLocalData). This covers the case the app
            // cannot purge: the radio evicting a contact when its storage
            // fills (PUSH contactDeleted), which is not the user asking to
            // forget anything — the contact's next advert re-adds it and the
            // history reconnects by key prefix. Until then it charts under the
            // prefix instead of vanishing.
            let nodeName = contact.map { contactStore.displayName(for: $0) }
                ?? contactKey.hexCompact.uppercased()

            for series in rfStore.availableReadings(for: contactKey) {
                let points = rfStore.history(for: contactKey, series: series)
                    .filter { $0.date >= cutoff }
                guard !points.isEmpty else { continue }
                byMetric[series.name, default: []].append(NodeSeries(
                    contactKey: contactKey,
                    nodeName: nodeName,
                    series: series,
                    unit: rfStore.unit(for: contactKey, series: series),
                    points: points))
            }
        }

        return byMetric.map { name, series in
            // Ends on the key, which is unique, so the order is total. Without
            // that last component two nodes sharing a display name tie, and
            // since this is built by walking a Dictionary the winner — and so
            // the colour each one gets — changes between launches.
            let sorted = series.sorted {
                ($0.nodeName.lowercased(), $0.series.label, $0.contactKey.hexCompact)
                    < ($1.nodeName.lowercased(), $1.series.label, $1.contactKey.hexCompact)
            }
            return MetricGroup(name: name,
                               // The LPP type, never a series label: a label carries
                               // the channel ("Humidity (ch 2)"), which belongs on the
                               // legend row for the node that has several, not on a
                               // header covering every node.
                               label: name,
                               // The heading's unit is the one most nodes report.
                               // Taking whichever happened to sort first let a
                               // single odd node relabel the axis for everyone;
                               // snapshots written before units were recorded
                               // decode with an empty unit and must not win.
                               unit: Self.consensusUnit(sorted),
                               series: sorted)
        }
        .sorted { lhs, rhs in
            let l = Self.preferredOrder.firstIndex(of: lhs.name) ?? Int.max
            let r = Self.preferredOrder.firstIndex(of: rhs.name) ?? Int.max
            return l == r ? lhs.name < rhs.name : l < r
        }
    }

    /// Dash pattern for the nth line.
    ///
    /// Normally only kicks in once the palette wraps. Under Differentiate Without
    /// Color every line gets its own pattern, by advancing a whole palette cycle
    /// per series.
    private func dash(_ index: Int) -> [CGFloat] {
        MeshTheme.seriesDash(differentiateWithoutColor
            ? index * MeshTheme.seriesPalette.count
            : index)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Time range", selection: $range) {
                    ForEach(TimeRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                let groups = groups
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        metricCard(group)
                    }

                    Text("Collected from telemetry requests you have already made. Nothing on this screen contacts the mesh.")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
            }
            .padding()
        }
        .background(MeshTheme.background)
        .navigationTitle("Sensors")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sensor")
                .font(.title)
                .foregroundStyle(MeshTheme.textSecondary)
            Text("No telemetry in this period")
                .font(.headline)
                .foregroundStyle(MeshTheme.textSecondary)
            Text("Request telemetry from a node \u{2014} from its detail sheet \u{2014} and its readings collect here. History is kept for seven days.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - One measurement

    @ViewBuilder
    private func metricCard(_ group: MetricGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: Self.icon(for: group.name))
                    .foregroundStyle(MeshTheme.accent)
                Text(localizedTelemetryName(group.name))
                    .font(.headline)
                    .foregroundStyle(MeshTheme.accent)
                Spacer()
                if !group.unit.isEmpty {
                    Text(group.unit)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }

            chart(group)
            legend(group)
        }
        .padding()
        .background(MeshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func chart(_ group: MetricGroup) -> some View {
        Chart {
            ForEach(Array(group.series.enumerated()), id: \.element.id) { index, node in
                // Keyed by position, not by date: two snapshots can carry the
                // same timestamp, and a duplicate ForEach id renders wrongly.
                ForEach(Array(node.points.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(localizedTelemetryName(group.name), point.value),
                        series: .value("Node", node.id)
                    )
                    .foregroundStyle(MeshTheme.seriesColor(index))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: dash(index)))
                    .interpolationMethod(.catmullRom)

                    // A node polled once has no line to draw, so mark the point.
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value(localizedTelemetryName(group.name), point.value)
                    )
                    .foregroundStyle(MeshTheme.seriesColor(index))
                    .symbolSize(node.points.count == 1 ? 90 : 0)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: range == .week
                               ? .dateTime.weekday(.abbreviated)
                               : .dateTime.hour().minute())
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYScale(domain: Self.yDomain(group))
        // Axis labels are chrome drawn inside a fixed plot area. Left to scale
        // with the rest, at the larger accessibility sizes they overlap into an
        // illegible smear — six y labels stacked on each other, the x labels
        // written straight through one another. Capped here and nowhere else,
        // so the headings, legend and values all still scale.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .chartLegend(.hidden)   // The legend below carries the latest value too.
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 180)
        .accessibilityLabel(Text(localizedTelemetryName(group.name)))
        .accessibilityValue(Text(chartSummary(group)))
    }

    /// What VoiceOver reads instead of the chart: the comparison the chart is for.
    private func chartSummary(_ group: MetricGroup) -> String {
        // Node name, value, unit — nothing to translate, so no catalog key.
        let parts = group.series.compactMap { node -> String? in
            guard let latest = node.latest else { return nil }
            return "\(node.nodeName) \(Self.format(latest.value))\(node.unit)"
        }
        guard !parts.isEmpty else { return String(localized: "No readings") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func legend(_ group: MetricGroup) -> some View {
        // Which nodes report this measurement more than once, worked out once
        // instead of re-scanning every series for every row.
        let multiSensor = Set(
            Dictionary(grouping: group.series, by: \.contactKey)
                .filter { $0.value.count > 1 }.keys)

        VStack(spacing: 6) {
            ForEach(Array(group.series.enumerated()), id: \.element.id) { index, node in
                legendRow(node, index: index,
                          showsChannel: multiSensor.contains(node.contactKey))
            }
        }
    }

    /// One legend row: swatch, who, what it last read, and when.
    ///
    /// Four columns on one line at normal sizes. At an accessibility size that
    /// line cannot hold them — the name truncated to an ellipsis and the value
    /// and age ran off the right edge entirely, so the row said nothing. It
    /// stacks instead, which costs height and keeps the information.
    @ViewBuilder
    private func legendRow(_ node: NodeSeries, index: Int, showsChannel: Bool) -> some View {
        let name = Text(node.nodeName)
            .font(.caption)
            .foregroundStyle(MeshTheme.textPrimary)
        let channel = Text(localizedTelemetryLabel(name: node.series.name, label: node.series.label))
            .font(.caption2)
            .foregroundStyle(MeshTheme.textSecondary)
        let reading = node.latest.map { latest in
            HStack(spacing: 6) {
                Text("\(Self.format(latest.value))\(node.unit)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(MeshTheme.textPrimary)
                Text(latest.date, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        SeriesSwatch(color: MeshTheme.seriesColor(index), dash: dash(index))
                        name
                    }
                    if showsChannel { channel }
                    reading
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    SeriesSwatch(color: MeshTheme.seriesColor(index), dash: dash(index))
                    // Which node it is matters more than which of its sensors,
                    // so the channel label truncates first.
                    name.lineLimit(1).layoutPriority(1)
                    if showsChannel { channel.lineLimit(1) }
                    Spacer(minLength: 4)
                    reading.lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Formatting

    /// The unit most nodes report for a measurement.
    ///
    /// Readings of one LPP type do share a unit in practice, but snapshots
    /// written before telemetry recorded units at all decode with an empty one,
    /// so a node whose history predates that must not get to label the axis.
    /// Ties break on the unit string to stay deterministic.
    private static func consensusUnit(_ series: [NodeSeries]) -> String {
        var tally: [String: Int] = [:]
        for node in series where !node.unit.isEmpty { tally[node.unit, default: 0] += 1 }
        return tally.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key ?? ""
    }

    /// The y range to plot a measurement over.
    ///
    /// Computed rather than left to `.automatic` because automatic fails badly
    /// at both ends of the range of real telemetry:
    ///
    ///   - Including zero, the default, flattens anything with a large offset.
    ///     Atmospheric pressure moves about 20 hPa around 1013, so a 0-based
    ///     axis drew eight distinct nodes as one line at the bottom.
    ///   - Excluding zero, a series whose value never changes — a repeater on
    ///     mains at 4.20 V, a still day's pressure — collapses the domain to a
    ///     single point. Charts then drew the axis *inverted*, labelled 4 at the
    ///     top and 5 at the bottom, and for a flat multi-point series dropped
    ///     the labels altogether. Both were on screen before this existed.
    ///
    /// A percentage keeps 0-100 so nodes stay comparable against a fixed scale
    /// rather than against today's spread, widening only if a reading exceeds
    /// it. Everything else gets the data's own range plus a margin, and a flat
    /// series gets a margin derived from its magnitude so the line lands in the
    /// middle of a sensibly labelled axis.
    private static func yDomain(_ group: MetricGroup) -> ClosedRange<Double> {
        let values = group.series.flatMap { $0.points.map(\.value) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }

        if group.unit == "%" {
            return min(0, low)...max(100, high)
        }

        let span = high - low
        guard span > 0 else {
            let margin = Swift.max(abs(high) * 0.01, 0.5)
            return (low - margin)...(high + margin)
        }
        let margin = span * 0.1
        return (low - margin)...(high + margin)
    }

    /// Telemetry carries no precision hint, so drop a decimal that says nothing.
    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 10_000
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private static func icon(for metric: String) -> String {
        switch metric {
        case "Battery": return "battery.100"
        case "Temperature": return "thermometer.medium"
        case "Humidity": return "humidity"
        case "Pressure": return "barometer"
        case "Voltage": return "bolt"
        case "Current": return "bolt.horizontal"
        case "Illuminance": return "sun.max"
        case "Altitude": return "mountain.2"
        default: return "sensor"
        }
    }
}

/// The line style of one chart series, drawn at legend size.
private struct SeriesSwatch: View {
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, dash: dash))
        }
        .frame(width: 22, height: 8)
        .accessibilityHidden(true)
    }
}
#endif
