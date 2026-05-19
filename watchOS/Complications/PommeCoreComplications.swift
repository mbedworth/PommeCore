//
//  PommeCoreComplications.swift
//  PommeCore Watch Complications
//
//  Watch face complications showing DM and channel unread counts.
//  Reads WatchWidgetState from the shared App Group written by the watch app.
//
//  ADD THIS FILE to a new watchOS Widget Extension target in Xcode:
//    File > New Target > Widget Extension (watchOS)
//    Target name: PommeCore Watch Complications
//    Bundle ID: com.mbedworth.meshcore.watchcomplications
//    Enable App Group capability: group.com.mbedworth.meshcore
//
//  Created by Michael P. Bedworth on 05/19/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import WidgetKit
import SwiftUI
import PommeCoreWatchKit

// MARK: - Provider

struct WatchEntry: TimelineEntry {
    let date: Date
    let state: WatchWidgetState
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry {
        WatchEntry(date: .now, state: placeholderState)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        let state = context.isPreview ? placeholderState : WatchWidgetState.load()
        completion(WatchEntry(date: .now, state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let entry = WatchEntry(date: .now, state: WatchWidgetState.load())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? Date(timeIntervalSinceNow: 900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private var placeholderState: WatchWidgetState {
        WatchWidgetState(isConnected: true, deviceName: "Mesh Pocket", unreadDMCount: 3, unreadChannelCount: 2)
    }
}

// MARK: - DM Complication Views

private struct DMCircularView: View {
    let state: WatchWidgetState

    var body: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.15))
            VStack(spacing: 1) {
                Text(state.unreadDMCount > 99 ? "99+" : "\(state.unreadDMCount)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .widgetAccentable()
                    .minimumScaleFactor(0.6)
                Text("DMs")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DMInlineView: View {
    let state: WatchWidgetState

    var body: some View {
        if state.unreadDMCount > 0 {
            Label("\(state.unreadDMCount) DM\(state.unreadDMCount == 1 ? "" : "s")", systemImage: "person.fill")
        } else {
            Label("No DMs", systemImage: "person")
        }
    }
}

// MARK: - Channel Complication Views

private struct ChannelCircularView: View {
    let state: WatchWidgetState

    var body: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.15))
            VStack(spacing: 1) {
                Text(state.unreadChannelCount > 99 ? "99+" : "\(state.unreadChannelCount)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .widgetAccentable()
                    .minimumScaleFactor(0.6)
                Text("Chs")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChannelInlineView: View {
    let state: WatchWidgetState

    var body: some View {
        if state.unreadChannelCount > 0 {
            Label("\(state.unreadChannelCount) Ch", systemImage: "antenna.radiowaves.left.and.right")
        } else {
            Label("No channels", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

// MARK: - Split Complication Views

private struct SplitRectangularView: View {
    let state: WatchWidgetState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("\(state.unreadDMCount)", systemImage: "person.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .widgetAccentable()
                Text("Private")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Label("\(state.unreadChannelCount)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .widgetAccentable()
                Text("Channels")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SplitInlineView: View {
    let state: WatchWidgetState

    var body: some View {
        if state.unreadDMCount > 0 || state.unreadChannelCount > 0 {
            Label("\(state.unreadDMCount) DM · \(state.unreadChannelCount) Ch", systemImage: "message.fill")
        } else if state.isConnected {
            Label(state.deviceName.isEmpty ? "Connected" : state.deviceName,
                  systemImage: "dot.radiowaves.left.and.right")
        } else {
            Label("Disconnected", systemImage: "wifi.slash")
        }
    }
}

// MARK: - Entry Views

struct DMComplicationEntryView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            DMCircularView(state: entry.state)
        case .accessoryInline:
            DMInlineView(state: entry.state)
        default:
            DMCircularView(state: entry.state)
        }
    }
}

struct ChannelComplicationEntryView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ChannelCircularView(state: entry.state)
        case .accessoryInline:
            ChannelInlineView(state: entry.state)
        default:
            ChannelCircularView(state: entry.state)
        }
    }
}

struct SplitComplicationEntryView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            SplitRectangularView(state: entry.state)
        case .accessoryInline:
            SplitInlineView(state: entry.state)
        default:
            SplitRectangularView(state: entry.state)
        }
    }
}

// MARK: - Complications

struct PommeCoreDMComplication: Widget {
    let kind = "PommeCoreDMComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchProvider()) { entry in
            DMComplicationEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PommeCore DMs")
        .description("Unread direct message count.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct PommeCoreChannelComplication: Widget {
    let kind = "PommeCoreChannelComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchProvider()) { entry in
            ChannelComplicationEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PommeCore Channels")
        .description("Unread channel message count.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct PommeCoreSplitComplication: Widget {
    let kind = "PommeCoreSplitComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchProvider()) { entry in
            SplitComplicationEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PommeCore Messages")
        .description("DM and channel unread counts side by side.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Bundle

@main
struct PommeCoreComplicationsBundle: WidgetBundle {
    var body: some Widget {
        PommeCoreDMComplication()
        PommeCoreChannelComplication()
        PommeCoreSplitComplication()
    }
}
