//
//  Theme.swift
//  PommeCore
//
//  Color system, mesh theme constants, clipboard helpers, shared UI utilities.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif

// MARK: - App Theme Preference

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

// MARK: - Theme Colors

enum MeshTheme {
    // Primary accent — adaptive green: darker/richer in light mode, bright in dark mode
    static var accent: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.0, green: 0.85, blue: 0.35, alpha: 1.0)
            } else {
                // #00762F — 5.18:1 on the grouped background, 5.78:1 on a
                // card. The previous 0.60/0.25 green measured 3.34:1, under
                // the 4.5:1 bar for body text, and rule 1 puts every label in
                // this color.
                return NSColor(red: 0.0, green: 0.463, blue: 0.184, alpha: 1.0)
            }
        })
        #elseif os(watchOS)
        Color(red: 0.0, green: 0.85, blue: 0.35) // always bright on watch
        #else
        Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.0, green: 0.85, blue: 0.35, alpha: 1.0)
            } else {
                return UIColor(red: 0.0, green: 0.463, blue: 0.184, alpha: 1.0)
            }
        })
        #endif
    }

    // Surface colors — adaptive to light/dark mode
    static var surface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #elseif os(watchOS)
        Color(white: 0.15)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var surfaceLight: Color {
        #if os(macOS)
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #elseif os(watchOS)
        Color(white: 0.22)
        #else
        Color(uiColor: .tertiarySystemGroupedBackground)
        #endif
    }

    static var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(watchOS)
        Color.black
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    // Interactive green — for any element where green is the BACKGROUND with black text on top.
    // Lighter than accent in light mode so black text is readable; medium green in dark mode.
    // Used for: buttons, badges, toggles, pills, login buttons, chat bubbles.
    static var interactiveGreen: Color { outgoingBubble }

    // Message bubbles — independent from accent; light enough for black text
    static var outgoingBubble: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.0, green: 0.65, blue: 0.3, alpha: 1.0)
            } else {
                return NSColor(red: 0.75, green: 0.93, blue: 0.78, alpha: 1.0)
            }
        })
        #elseif os(watchOS)
        Color(red: 0.0, green: 0.65, blue: 0.3)
        #else
        Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.0, green: 0.65, blue: 0.3, alpha: 1.0)
            } else {
                return UIColor(red: 0.75, green: 0.93, blue: 0.78, alpha: 1.0)
            }
        })
        #endif
    }

    static var incomingBubble: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1.0)
            } else {
                return NSColor(red: 1.0, green: 0.88, blue: 0.75, alpha: 1.0)
            }
        })
        #elseif os(watchOS)
        Color(red: 0.80, green: 0.45, blue: 0.10)
        #else
        Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1.0)
            } else {
                return UIColor(red: 1.0, green: 0.88, blue: 0.75, alpha: 1.0)
            }
        })
        #endif
    }

    // Status colors — these system colors adapt automatically
    // Status colors.
    //
    // Apple's system colors are tuned to look vivid on a filled dot, not to be
    // read as text. Against a light background they are far below the 4.5:1
    // WCAG AA bar for body text — system green measures 1.99:1 and orange
    // 1.97:1 on the grouped background — and this app puts the status *text*
    // in the same color as the dot beside it. So light mode gets darker
    // values, measured to clear 5:1.
    //
    // Dark mode keeps Apple's system colors where they pass, and four of them
    // do not. The first version of this measured only the grouped background
    // and the card, where system red reaches 4.99:1 and looks fine. But the
    // app also puts status text on `surfaceLight` — the *tertiary* grouped
    // background, #2C2C2E on iOS and lighter again on macOS — and against
    // that, system red falls to 4.09:1, blue to 3.82:1, the map violet to
    // 3.96:1 and gray to 3.95:1. Those four are brightened 11–29% toward
    // white: enough to clear 4.5:1 on every surface the app actually uses,
    // while still plainly reading as red, blue, violet and gray.
    //
    // Choosing a dark-mode value against the darkest background is the easy
    // mistake, because that is the case that always passes. Measure the
    // lightest surface the color can land on. watchOS is always dark.
    private static func statusColor(light: (Double, Double, Double),
                                    dark: Color) -> Color {
        #if os(watchOS)
        return dark
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1.0)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1.0)
        })
        #endif
    }

    /// Good, healthy, in range. Light #1E7533 — 5.16:1 on the grouped background.
    static let statusGood = statusColor(light: (0.118, 0.459, 0.200), dark: .green)
    /// Degraded but working. Light #965800 — 5.10:1.
    static let statusWarn = statusColor(light: (0.588, 0.345, 0.0), dark: .orange)
    /// Early or indeterminate. Light #7D6400 — 5.09:1.
    static let statusCaution = statusColor(light: (0.490, 0.392, 0.0), dark: .yellow)
    /// Failed, offline, out of range. Light #C62A22 — 5.01:1.
    /// Dark #FF7B73 — see the note below on why this is not `Color.red`.
    static let statusBad = statusColor(light: (0.776, 0.165, 0.133),
                                       dark: Color(red: 1.0, green: 0.482, blue: 0.451))
    /// Informational, in progress. Light #0063D1 — 5.08:1. Dark #51A8FF.
    static let statusInfo = statusColor(light: (0.0, 0.388, 0.820),
                                        dark: Color(red: 0.318, green: 0.658, blue: 1.0))
    /// Dormant. Light #6C6C70 — 4.76:1; `Color.gray` is only 3.3:1 on white.
    /// Dark #A3A3A8.
    static let statusIdle = statusColor(light: (0.424, 0.424, 0.439),
                                        dark: Color(red: 0.641, green: 0.641, blue: 0.658))

    static let connected = statusGood
    static let connecting = statusWarn
    static let initialConnected = statusCaution
    static let scanning = statusInfo
    static let disconnected = statusBad

    // Text — adaptive
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    /// Text and icons sitting *on* a filled accent, status or remote-accent
    /// background — the colours that flip from a darkened light-mode value to
    /// a bright system colour in dark mode. The readable foreground has to
    /// flip with them: white on the dark light-mode fill (accent 5.78:1,
    /// statusBad 5.60:1, remoteRoom 5.57:1), black on the bright dark-mode one
    /// (accent 11.04:1, system red 6.16:1, system teal 10.56:1).
    ///
    /// This replaces the old `textOnAccent = .black`. That was right while the
    /// accent was a mid green, but darkening it to #00762F for contrast took
    /// black down to 3.64:1 — under the 4.5:1 bar — so a constant can no
    /// longer serve both modes.
    static let textOnFill = statusColor(light: (1, 1, 1), dark: .black)

    /// Text and icons on a pale fill: the message bubbles, `interactiveGreen`
    /// badges and pills. Both mode variants of those fills are light enough
    /// that black wins outright (16.18:1 light, 6.54:1 dark), so this one is
    /// genuinely constant.
    static let textOnBubble = Color.black

    /// Text on an always-dark panel or photographic overlay, where there is no
    /// light-mode variant to adapt to. 16.56:1 on the terrain panel.
    static let textOnDarkPanel = Color.white

    /// The opaque panel behind the terrain-profile legend — dark in both modes
    /// because it sits on the rendered profile, not on the app background.
    static let darkPanel = Color(white: 0.12)

    /// The ring that separates a map pin from the map underneath it.
    static let mapPinOutline = Color.white

    /// Neutral black shading for scrims, pin shadows and subtle tints over
    /// imagery. A single entry point, so no view needs a raw `Color.black`.
    static func shade(_ opacity: Double) -> Color { Color.black.opacity(opacity) }

    // MARK: Signal and status mapping
    //
    // One implementation per quantity, using the thresholds documented as the
    // app's status colour standards. These were previously copied into five
    // views; the copies had drifted — one SNR version used >= 5 / >= 0 and so
    // could never return red at all, while the documented scale puts anything
    // below -10 dB in red.

    /// LoRa signal-to-noise ratio. Green > 0 dB, amber 0 to -10, red < -10.
    static func snrColor(_ snr: Double) -> Color {
        if snr > 0 { return statusGood }
        if snr > -10 { return statusWarn }
        return statusBad
    }

    /// Whole-decibel convenience. Taken separately rather than by converting
    /// at the call site, because truncating a fractional SNR would move a
    /// reading like +0.5 dB from green into amber.
    static func snrColor(_ snr: Int) -> Color { snrColor(Double(snr)) }

    /// LoRa received signal strength. Green > -100 dBm, amber -100 to -120,
    /// red < -120.
    static func rssiColor(_ rssi: Int) -> Color {
        if rssi > -100 { return statusGood }
        if rssi > -120 { return statusWarn }
        return statusBad
    }

    /// Which band a signal reading falls into: 0 good, 1 marginal, 2 bad —
    /// the same three bands `snrColor`/`rssiColor` paint.
    static func signalTier(snr: Double) -> Int { snr > 0 ? 0 : snr > -10 ? 1 : 2 }

    /// As above, for received signal strength in dBm.
    static func signalTier(rssi: Int) -> Int { rssi > -100 ? 0 : rssi > -120 ? 1 : 2 }

    /// A dash pattern that tells the three signal bands apart *without*
    /// colour: solid, dashed, dotted.
    ///
    /// The map's link-quality and coverage overlays encoded signal strength in
    /// the line colour and nothing else, which is precisely what Differentiate
    /// Without Color exists to catch. Apply this under that setting and the
    /// band survives for someone who cannot separate the green from the red.
    static func signalDash(tier: Int) -> [CGFloat] {
        switch tier {
        case 0: return []
        case 1: return [6, 3]
        default: return [2, 3]
        }
    }

    /// Colours for charting several nodes on one set of axes.
    ///
    /// Reuses tokens that already carry a measured contrast ratio against every
    /// surface the app draws on, rather than inventing six new ones. Six is the
    /// practical ceiling for telling lines apart at a glance; past that the
    /// palette repeats and `seriesDash` is what keeps the lines distinct.
    static let seriesPalette: [Color] = [accent, statusInfo, statusWarn, mapRoom, remoteRoom, statusBad]

    /// Palette colour for the nth series, wrapping.
    static func seriesColor(_ index: Int) -> Color {
        seriesPalette[((index % seriesPalette.count) + seriesPalette.count) % seriesPalette.count]
    }

    /// Line patterns for charting several series, one per palette entry.
    ///
    /// There are exactly as many patterns as colours on purpose. A caller that
    /// advances this a full palette cycle per series — which is what
    /// Differentiate Without Color asks for — then gets a distinct pattern for
    /// every line the palette can distinguish, instead of running out first and
    /// handing two lines the same pattern in different colours, which is the
    /// one thing that setting says not to rely on.
    static let seriesDashes: [[CGFloat]] = [
        [],                 // solid
        [6, 3],             // dashed
        [2, 3],             // dotted
        [9, 3, 2, 3],       // dash-dot
        [14, 4],            // long dash
        [9, 3, 2, 3, 2, 3], // dash-dot-dot
    ]

    /// A dash pattern per series, so a multi-node chart stays readable for
    /// someone who cannot separate the colours — and once the palette wraps,
    /// for everyone. Changes only after a full cycle of the palette, keeping
    /// the first six lines solid.
    static func seriesDash(_ index: Int) -> [CGFloat] {
        guard index >= 0 else { return [] }
        return seriesDashes[(index / seriesPalette.count) % seriesDashes.count]
    }

    /// Noise floor. Green < -105 dBm, amber -105 to -95, red above -95.
    static func noiseFloorColor(_ dBm: Int) -> Color {
        if dBm < -105 { return statusGood }
        if dBm < -95 { return statusWarn }
        return statusBad
    }

    /// Stored message count. Green < 5,000, amber to 20,000, red beyond.
    static func messageCountColor(_ count: Int) -> Color {
        if count > 20_000 { return statusBad }
        if count > 5_000 { return statusWarn }
        return statusGood
    }

    /// Stored telemetry reading count. Green < 500, amber to 2,000, red beyond.
    static func telemetryCountColor(_ count: Int) -> Color {
        if count > 2_000 { return statusBad }
        if count > 500 { return statusWarn }
        return statusGood
    }

    /// Battery charge. Green > 50%, amber > 20%, red at or below 20%.
    static func batteryColor(percent: Int) -> Color {
        if percent > 50 { return statusGood }
        if percent > 20 { return statusCaution }
        return statusBad
    }

    /// Remote-session permission level, for the badge in contact rows and the
    /// remote management header.
    static func permissionColor(_ permission: RemotePermission) -> Color {
        switch permission {
        case .guest: return textSecondary
        case .readOnly: return statusCaution
        case .readWrite: return statusInfo
        case .admin: return interactiveGreen
        }
    }

    // Remote management accent colors
    // Both of these reach text through `remoteAccent`, so they need the same
    // treatment as the status colours: Color.teal measures 2.31:1 on the light
    // grouped background and Color.orange 1.97:1.
    /// Room servers. Light #1F7281 — 5.00:1.
    static let remoteRoom = statusColor(light: (0.122, 0.446, 0.504), dark: .teal)
    /// Repeaters. Shares the warning amber, which is already measured.
    static let remoteRepeater = statusWarn

    /// Room-server pins on the map. Teal is taken there by the internet-map
    /// nodes, so rooms keep a violet — but a measured one. Light #8E3AB8 is
    /// 5.46:1; `Color.purple` is 3.70:1, under the bar even for a pin label.
    /// Dark #D085F5, brightened from `Color.purple` for the same reason as
    /// `statusBad` — see the note on `statusColor`.
    static let mapRoom = statusColor(light: (0.557, 0.227, 0.722),
                                     dark: Color(red: 0.814, green: 0.521, blue: 0.962))

    /// A tappable link *inside* a message bubble.
    ///
    /// The accent cannot do this job. On the light bubbles it measures
    /// 4.45:1, a hair under the bar, and on the dark-mode bubbles it collapses
    /// to 1.69:1 — the bright green all but disappears into the medium green
    /// fill. Nothing coloured survives on those mid-tone dark fills: even
    /// white only reaches 3.21:1. So dark mode uses the same black as the
    /// bubble's body text (6.54:1) and both modes underline, which is what
    /// actually marks the link, and marks it without relying on colour.
    static let linkInBubble = statusColor(light: (0.0, 0.302, 0.122), dark: .black)

    // Terrain profile — the line-of-sight drawing renders its own landscape,
    // so these are picture colours rather than UI colours. They live here so
    // the renderer holds no literals of its own.
    static let terrainSkyTop = Color(red: 0.53, green: 0.81, blue: 0.92)
    static let terrainSkyBottom = Color(red: 0.68, green: 0.85, blue: 0.90)
    static let terrainGroundTop = Color(red: 0.4, green: 0.6, blue: 0.3)
    static let terrainGroundBottom = Color(red: 0.55, green: 0.45, blue: 0.3)
}

// MARK: - TextField Style
//
// .roundedBorder uses systemBackground which is pure black on OLED in dark mode,
// making it invisible on secondarySystemGroupedBackground list rows.
// This style uses the correct elevated surface color for grouped lists.

#if !os(watchOS)
struct MeshTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .foregroundColor(.primary)
            .padding(7)
            #if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
            #else
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            #endif
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}
#endif

// MARK: - Theme Modifier

struct MeshThemeModifier: ViewModifier {
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }

    func body(content: Content) -> some View {
        content
            .tint(MeshTheme.accent)
            .onAppear { applyToAllWindows() }
            .onChange(of: appTheme) { applyToAllWindows() }
    }

    /// Apply theme via UIKit window override — affects all windows including sheets.
    /// SwiftUI's `.preferredColorScheme(nil)` doesn't propagate to sheets,
    /// but UIKit's `overrideUserInterfaceStyle = .unspecified` does.
    /// Called synchronously on main thread (from onAppear/onChange) to avoid
    /// race conditions when the user switches themes rapidly.
    private func applyToAllWindows() {
        let theme = selectedTheme
        #if os(iOS)
        let style: UIUserInterfaceStyle = switch theme {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
        #elseif os(macOS)
        switch theme {
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp?.appearance = nil
        }
        #endif
    }
}

extension View {
    func meshTheme() -> some View {
        modifier(MeshThemeModifier())
    }

    @ViewBuilder
    func meshListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #elseif os(watchOS)
        self
        #else
        self
        #endif
    }
}

// MARK: - iCloud KV Store Helpers

extension NSUbiquitousKeyValueStore {

    /// The unscoped key an install carried before radio scoping existed.
    ///
    /// **Every reader below falls back to this, so every writer has to clear
    /// it.** Spelling it out at each site is what let `saveDraft` clear the
    /// scoped key and leave `draft.00` behind. One function means a reader and
    /// a writer cannot disagree about what the key is.
    func legacyKey(_ base: String, contactHex: String) -> String {
        "\(base).\(contactHex)"
    }

    /// Build a radio-scoped iCloud key. Returns scoped key if radio prefix available, else legacy key.
    func scopedKey(_ base: String, contactHex: String, radioPrefix: String?) -> String {
        if let prefix = radioPrefix, !prefix.isEmpty {
            return "\(base).\(prefix).\(contactHex)"
        }
        return legacyKey(base, contactHex: contactHex)
    }

    /// Read a string from iCloud, trying scoped key first then legacy fallback.
    func scopedString(base: String, contactHex: String, radioPrefix: String?) -> String? {
        if let prefix = radioPrefix, !prefix.isEmpty {
            let key = "\(base).\(prefix).\(contactHex)"
            if let value = string(forKey: key), !value.isEmpty {
                return value
            }
        }
        let legacy = legacyKey(base, contactHex: contactHex)
        let value = string(forKey: legacy)
        return (value?.isEmpty == true) ? nil : value
    }

    /// Write a scoped value, clearing the legacy key so a read cannot resurrect it.
    ///
    /// **The readers above fall back to an unscoped legacy key, so every writer
    /// must clear it too.** `saveDraft` did not: it hand-built the scoped key
    /// and removed only that, so clearing a draft left `draft.00` in place and
    /// the next `loadDraft` fell through and restored it. That is why the
    /// public channel's compose field refused to empty after sending while a
    /// direct message's did — `draft.00` is the one key every install has
    /// carried since before radio scoping existed.
    ///
    /// Writing through here keeps the two sides symmetrical by construction.
    /// Passing an empty string removes the value, which is how a draft is
    /// cleared.
    ///
    /// **With no radio connected the two keys are the same key.** `scopedKey`
    /// falls back to the unscoped form when it has no prefix, so clearing "the
    /// legacy one" afterwards would delete the value just written — which it
    /// did, and drafts stopped surviving navigation until the simulator said
    /// so. `clearLegacy` exists to make that case impossible to write.
    func setScopedString(_ value: String,
                         base: String,
                         contactHex: String,
                         radioPrefix: String?) {
        let scoped = scopedKey(base, contactHex: contactHex, radioPrefix: radioPrefix)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeObject(forKey: scoped)
            clearLegacy(base, contactHex: contactHex, otherThan: scoped)
        } else {
            set(value, forKey: scoped)
            // The scoped key is now authoritative; a stale legacy value would
            // only ever shadow it on a later read.
            clearLegacy(base, contactHex: contactHex, otherThan: scoped)
        }
        synchronize()
    }

    /// Write a scoped number, clearing the legacy key. See `setScopedString`.
    func setScopedDouble(_ value: Double,
                         base: String,
                         contactHex: String,
                         radioPrefix: String?) {
        let scoped = scopedKey(base, contactHex: contactHex, radioPrefix: radioPrefix)
        set(value, forKey: scoped)
        clearLegacy(base, contactHex: contactHex, otherThan: scoped)
        synchronize()
    }

    /// Remove the unscoped key, unless it *is* the key just written.
    private func clearLegacy(_ base: String, contactHex: String, otherThan scoped: String) {
        let legacy = legacyKey(base, contactHex: contactHex)
        guard legacy != scoped else { return }
        removeObject(forKey: legacy)
    }

    /// Remove both the scoped and legacy forms of a key.
    func removeScoped(base: String, contactHex: String, radioPrefix: String?) {
        removeObject(forKey: scopedKey(base, contactHex: contactHex, radioPrefix: radioPrefix))
        removeObject(forKey: legacyKey(base, contactHex: contactHex))
        synchronize()
    }

    /// Read a double from iCloud, trying scoped key first then legacy fallback.
    func scopedDouble(base: String, contactHex: String, radioPrefix: String?) -> Double {
        if let prefix = radioPrefix, !prefix.isEmpty {
            let key = "\(base).\(prefix).\(contactHex)"
            let val = double(forKey: key)
            if val > 0 { return val }
        }
        let legacy = legacyKey(base, contactHex: contactHex)
        return double(forKey: legacy)
    }

    /// Save a Codable value to iCloud KV store.
    func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            set(data, forKey: key)
            synchronize()
        }
    }

    /// Load a Codable value from iCloud KV store.
    func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Set a value and synchronize in one call.
    func setAndSync(_ value: Any?, forKey key: String) {
        set(value, forKey: key)
        synchronize()
    }
}

// MARK: - Reduced Motion

/// True when the user has asked the system to reduce motion.
///
/// Read from the platform rather than `@Environment(\.accessibilityReduceMotion)`
/// so that non-view code honours it too — `showFeedback` below, and anything in
/// a store that animates a state change. Read at call time, so it always
/// reflects the current setting without needing to observe a change
/// notification.
var isReduceMotionEnabled: Bool {
    #if os(iOS) || targetEnvironment(macCatalyst)
    return UIAccessibility.isReduceMotionEnabled
    #elseif os(macOS)
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #elseif os(watchOS)
    return WKAccessibilityIsReduceMotionEnabled()
    #else
    return false
    #endif
}

/// `withAnimation`, honouring Reduce Motion.
///
/// Under Reduce Motion the state change is applied *without* animation rather
/// than being skipped, so no behaviour is lost — only the movement. Use this in
/// place of `withAnimation` everywhere; a bare `withAnimation` ignores the
/// setting entirely, which is why the app could not claim Reduced Motion
/// support.
func withMeshAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(isReduceMotionEnabled ? nil : animation, body)
}

/// An animation for the `.animation(_:value:)` modifier, `nil` under Reduce
/// Motion. Use in place of passing an animation directly.
func meshAnimation(_ animation: Animation?) -> Animation? {
    isReduceMotionEnabled ? nil : animation
}

// MARK: - Status Indicator

/// A status indicator that stays readable when colour cannot be relied on.
///
/// Status in this app was conveyed by colour alone — a tinted dot or a tinted
/// icon. The two most consequential states, active and offline, were green
/// against red, the single most common confusion for colour-blind users. With
/// Differentiate Without Color enabled this renders a glyph whose silhouette
/// identifies the state; otherwise it stays the plain coloured dot, so the
/// familiar look is unchanged for everyone else.
///
/// Always carries the spoken status, so VoiceOver announces the state rather
/// than describing a dot.
struct StatusIndicator: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let symbolName: String
    let color: Color
    let label: String
    var size: CGFloat = 10

    var body: some View {
        indicator
            .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private var indicator: some View {
        if differentiateWithoutColor {
            Image(systemName: symbolName)
                .font(.system(size: size + 1, weight: .semibold))
                .foregroundStyle(color)
        } else {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Feedback Utility

/// Set a Bool binding to true, then reset to false after a delay. Animates both
/// transitions, unless Reduce Motion is on.
func showFeedback(_ state: Binding<Bool>, duration: TimeInterval = 2) {
    withMeshAnimation { state.wrappedValue = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        withMeshAnimation { state.wrappedValue = false }
    }
}

// MARK: - Linear Progress Bar

/// Custom progress bar that avoids NSProgressIndicator's stacking animation bug on macOS,
/// where rapid value updates cause the bar to visually bounce backwards.
struct LinearProgressBar: View {
    let progress: Double
    var tint: Color = MeshTheme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * max(0, min(progress, 1)))
                    .animation(meshAnimation(.linear(duration: 0.15)), value: progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Copy Button

/// Reusable copy-to-clipboard button with timed "Copied!" feedback and consistent styling.
struct CopyButton: View {
    let text: String
    let label: LocalizedStringKey
    let icon: String
    var copiedLabel: LocalizedStringKey = "Copied!"
    var copiedIcon: String = "checkmark"
    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard(text)
            showFeedback($copied)
        } label: {
            Label(copied ? copiedLabel : label, systemImage: copied ? copiedIcon : icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(MeshTheme.accent.opacity(0.1))
                .foregroundStyle(copied ? MeshTheme.statusGood : MeshTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Label-Value Row

/// Reusable two-column row for displaying a label and value in a List.
struct LabelValueRow: View {
    let label: LocalizedStringKey
    let value: String
    var labelColor: Color = MeshTheme.accent
    var valueColor: Color = MeshTheme.textSecondary
    /// Monospaced value, for figures meant to line up down a column.
    var monospacedValue: Bool = false
    /// Applied to label and value together; `nil` keeps the inherited style.
    var font: Font?

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(labelColor)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .monospaced(monospacedValue)
        }
        .font(font)
        .listRowBackground(MeshTheme.surface)
        // Read label + value as one VoiceOver element (e.g. "Firmware, 1.15.0").
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section Header

/// The header above a `Section`, in one place.
///
/// Every header restated its own styling, and most of them drifted: of 52 in
/// the app, 32 set no colour at all and took SwiftUI's default. The contact
/// list showed the result in a single screen — Repeaters, Sensors and Rooms in
/// accent green with an icon, Contacts, Groups and Channels in grey without
/// one, Pending Contacts in amber. Nothing chose that; it is just where three
/// people stopped.
///
/// Grey is the resting state, which is both the majority here and the iOS
/// convention. `tint` exists for the one header that genuinely means something
/// by its colour — Pending Contacts, where amber *is* the signal that
/// something is waiting — and the fact that it has to be asked for is the
/// point. `trailing` carries whatever the section puts on the right: a sort
/// toggle, an add menu, an unread count.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var tint: Color = MeshTheme.textSecondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(tint)
            } else {
                Text(title)
                    .foregroundStyle(tint)
            }
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey,
         systemImage: String? = nil,
         tint: Color = MeshTheme.textSecondary) {
        self.init(title: title, systemImage: systemImage, tint: tint,
                  trailing: { EmptyView() })
    }
}

extension SectionHeader {
    init(_ title: LocalizedStringKey,
         systemImage: String? = nil,
         tint: Color = MeshTheme.textSecondary,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, systemImage: systemImage, tint: tint,
                  trailing: trailing)
    }
}

// MARK: - Coordinate Input Field

/// Reusable lat/lon text field row for List/Form contexts.
struct CoordinateInputField: View {
    let label: LocalizedStringKey
    let placeholder: String
    @Binding var text: String
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: $text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MeshTheme.textPrimary)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onChange(of: text) { onChange?() }
        }
        .listRowBackground(MeshTheme.surface)
    }
}

// MARK: - macOS Window State

#if os(macOS)
extension NSApplication {
    /// Whether the user can see the app: active and window not miniaturized.
    var isUserViewing: Bool {
        isActive && !(mainWindow?.isMiniaturized ?? true)
    }
}
#endif

// MARK: - Formatting Helpers

extension String {
    /// Strip emoji characters for sorting purposes (e.g. "🐝Mike" sorts as "Mike").
    var strippingEmoji: String {
        unicodeScalars.filter { !$0.properties.isEmoji || $0.properties.isASCIIHexDigit }.map(String.init).joined()
    }
}

/// Localized name for an LPP telemetry type.
///
/// `TelemetryReading.name` is an English literal written by the frame parser —
/// "Temperature", "Battery", "Pressure". It is protocol vocabulary, used as the
/// stable key for history, the icon table and sort order, so it must not change
/// with the user's language. It had also never reached the string catalog,
/// which meant every telemetry screen showed English in all twelve languages
/// while the chrome around it was translated.
///
/// So: translate at the point of display only, and leave the stored name alone.
/// An LPP type the catalog does not know yet falls through unchanged, which is
/// the same English it showed before — a new sensor type in firmware degrades
/// to the old behaviour rather than to a blank.
func localizedTelemetryName(_ name: String) -> String {
    switch name {
    case "Temperature": return String(localized: "Temperature")
    case "Humidity": return String(localized: "Humidity")
    case "Pressure": return String(localized: "Pressure")
    case "Battery": return String(localized: "Battery")
    case "Current": return String(localized: "Current")
    case "Power": return String(localized: "Power")
    // Not the "Light" key: that one is the appearance theme, and sharing it
    // put "Helligkeit" in the German theme picker. An LPP light reading is
    // illuminance in lux.
    case "Light": return String(localized: "Illuminance")
    case "Percentage": return String(localized: "Percentage")
    case "Altitude": return String(localized: "Altitude")
    case "Distance": return String(localized: "Distance")
    case "Presence": return String(localized: "Presence")
    case "Concentration": return String(localized: "Concentration")
    case "Sensor": return String(localized: "Sensor")
    case "GPS Lat": return String(localized: "GPS Lat")
    case "GPS Lon": return String(localized: "GPS Lon")
    default: return name
    }
}

/// A reading's display label with its type name localized.
///
/// `label` is the name plus a channel qualifier when one node reports the same
/// type more than once — "Temperature (Ch 2)". Only the name is translated; the
/// qualifier is a channel number and stays as the firmware numbers it. Built by
/// replacing the known prefix rather than by parsing the qualifier, so a label
/// shape this does not recognise passes through untouched.
func localizedTelemetryLabel(name: String, label: String) -> String {
    guard label.hasPrefix(name) else { return label }
    return localizedTelemetryName(name) + label.dropFirst(name.count)
}

/// Format raw SNR value (SNR * 4 from firmware) to human-readable dB string.
func formatSNR<T: BinaryInteger>(_ rawSNR: T) -> String {
    String(format: "%.1f dB", Double(Int(rawSNR)) / 4.0)
}

/// Format frequency from kHz to MHz display string.
func formatFrequency(_ kHz: Double) -> String {
    String(format: "%.3f MHz", kHz / 1000.0)
}

/// Format a LoRa bandwidth in kHz, dropping a trailing `.0` (250 kHz, 62.5 kHz).
///
/// This was a `private func formatBW` in three views, and the three had already
/// stopped matching: two guarded `bw >= 1`, the third did not. No LoRa bandwidth
/// is below 1 kHz, so nothing was wrong on screen — which is the point. Copies
/// drift before they break, and the drift is the only warning you get.
func formatBandwidth(_ kHz: Double) -> String {
    if kHz == kHz.rounded() && kHz >= 1 {
        return "\(Int(kHz)) kHz"
    }
    return "\(kHz) kHz"
}

/// Format battery voltage from millivolts to volts string.
func formatBatteryVoltage<T: BinaryInteger>(_ mV: T) -> String {
    String(format: "%.2fV", Double(Int(mV)) / 1000.0)
}

/// A time of day for text that goes **out over the mesh**, as 24-hour `HH:mm`.
///
/// Deliberately not locale-aware, and deliberately not the `.short` time style
/// the chat timestamps use. Those are read by the person holding the phone, so
/// they should follow that person's locale. This one is read by whoever is on
/// the other end of the radio, who has a different locale and no way to ask —
/// so it uses the 24-hour convention every other station on the band is already
/// using, and never emits an AM/PM marker that costs bytes and means nothing to
/// half the mesh.
func formatMeshTime(_ date: Date) -> String {
    Self_meshTimeFormatter.string(from: date)
}

/// Held once: `DateFormatter` is expensive to build and this one never varies.
private let Self_meshTimeFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "HH:mm"
    return fmt
}()

/// A hop count as words, for display — `1 hop`, `8 hops`.
///
/// **The only place the inflection markup may be written.** It was written at
/// ten call sites, and the copies had already diverged in the way duplication
/// always eventually does: two of them resolved the key through
/// `String(localized:)`, which does *not* apply automatic grammar agreement, so
/// those two rendered the markup literally — one of them into a message
/// transmitted over the air, where a recipient on another client read
/// `Copy, @[Z-max]! ^[3 hop](inflect: true) @ 21:44`. Fixing one copy fixed one
/// tenth of the bug, which is the argument for this function existing.
///
/// Both forms resolve the **same two catalog keys**, so the wording is decided
/// once and cannot drift between what is shown and what is sent. No automatic
/// grammar agreement: the markup only works where `Text` draws it, and 46 of
/// its translations across the catalog had already been broken by the
/// translator — carets dropped, `inflect: true` rendered as `inflex:
/// verdadero`, `zmień: prawdziwe`, `可变性：true`. Structure inside a translated
/// string is a hazard this project has been bitten by before, with Markdown in
/// the help catalog.
///
/// The cost is the few/many distinction Czech, Polish and Ukrainian make, which
/// one word in a status line can bear.
func hopCountLabel(_ hops: Int) -> LocalizedStringKey {
    hops == 1 ? "1 hop" : "\(hops) hops"
}

/// A hop count as words, for a `String` — a wire payload, or a computed `var`.
func formatHopCount(_ hops: Int) -> String {
    hops == 1 ? String(localized: "1 hop") : String(localized: "\(hops) hops")
}

/// Format a coordinate (latitude or longitude) to 6 decimal places.
func formatCoordinate(_ value: Double) -> String {
    String(format: "%.6f", value)
}

func formatUptime(_ seconds: UInt32) -> String {
    guard seconds > 0 else { return "—" }
    let s = Int(seconds)
    let d = s / 86400; let h = (s % 86400) / 3600; let m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s % 60)s" }
    return "\(s % 60)s"
}

func formatDuration(_ ms: Double) -> String {
    if ms >= 1000 {
        return String(format: "%.2f s", ms / 1000)
    }
    return String(format: "%.1f ms", ms)
}

// MARK: - Shared Settings Components
#if !os(watchOS)

enum SaveButtonState {
    case idle, saved
}

struct SaveButton: View {
    let state: SaveButtonState
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if state == .saved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MeshTheme.statusGood)
                    Text("Saved")
                        .foregroundStyle(MeshTheme.statusGood)
                } else {
                    Text(label)
                        .foregroundStyle(MeshTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .listRowBackground(MeshTheme.surface)
        .animation(meshAnimation(.easeInOut(duration: 0.2)), value: state)
    }
}

private struct InfoPopoverContent: View {
    let text: LocalizedStringKey

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
        Text(text)
            .font(.callout)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(minWidth: 240, maxWidth: 340)
        #else
        ScrollView {
            Text(text)
                .font(.callout)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        // Whether this needs a width depends on the presentation width, not
        // on the hardware: UIKit adapts a popover to a sheet in compact and
        // leaves it floating in regular. Adapted, rule 17 wants its natural
        // full width — a 300pt cap left the help text in a narrow column with
        // dead margins and wrapped it badly at large Dynamic Type sizes.
        // Floating, it does need one.
        //
        // This was `isPadIdiom`, which is wrong in both directions: an iPad in
        // Slide Over is compact and got a cap it should not have, and a
        // foldable iPhone reports `.phone` while unfolded at regular width, so
        // the one case the cap exists for got no width at all.
        .frame(minWidth: horizontalSizeClass == .regular ? 240 : nil,
               maxWidth: horizontalSizeClass == .regular ? 300 : nil,
               minHeight: 60)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

struct InfoButton: View {
    let text: LocalizedStringKey
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(MeshTheme.textSecondary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .popover(isPresented: $showPopover) {
            InfoPopoverContent(text: text)
        }
    }
}

struct SectionInfoHeader: View {
    let title: LocalizedStringKey?
    let info: LocalizedStringKey
    var titleColor: Color?
    var action: (() -> Void)? = nil
    var actionIcon: String = "arrow.clockwise"
    @State private var showInfo = false

    init(title: LocalizedStringKey? = nil, info: LocalizedStringKey, titleColor: Color? = nil, action: (() -> Void)? = nil, actionIcon: String = "arrow.clockwise") {
        self.title = title
        self.info = info
        self.titleColor = titleColor
        self.action = action
        self.actionIcon = actionIcon
    }

    var body: some View {
        let color = titleColor ?? MeshTheme.textSecondary
        HStack(spacing: 4) {
            if let action {
                // Title + spacer + ↺ icon are one large button — whole row is tappable
                Button(action: action) {
                    HStack(spacing: 6) {
                        if let title {
                            Text(title)
                                .foregroundStyle(color)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: actionIcon)
                            .foregroundStyle(color.opacity(0.75))
                    }
                    .contentShape(Rectangle())
                }
                #if os(macOS) || targetEnvironment(macCatalyst)
                .buttonStyle(.borderless)
                #else
                .buttonStyle(.plain)
                #endif
            } else {
                if let title {
                    Text(title)
                        .foregroundStyle(color)
                }
                Spacer(minLength: 0)
            }
            // ⓘ is always independent — tap doesn't interfere with the title action
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(color.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More information")
            .popover(isPresented: $showInfo) {
                InfoPopoverContent(text: info)
            }
        }
    }
}

// MARK: - CLI Shared Components

struct CLICommandButton: View {
    let icon: String
    let label: LocalizedStringKey
    var color: Color = MeshTheme.accent
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(color)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
        .listRowBackground(MeshTheme.surface)
    }
}

struct CLIToggleRow: View {
    let icon: String
    let label: LocalizedStringKey
    let settingKey: String
    let onCommand: String
    let offCommand: String
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    var canEdit: Bool = true

    /// `nil` means "cannot say", which covers both a device that has not
    /// answered yet and one that has no such command.
    ///
    /// Reading `settings[key]` directly happened to return nil for a refusal
    /// here, because none of "unknown command", "??: …" or "error: unsupported"
    /// contains the substring `on` or `off` — correct by luck rather than by
    /// decision, and one differently-worded firmware reply away from a toggle
    /// that renders a refusal as a position.
    private var isOn: Bool? {
        guard let value = session.supportedValue(for: settingKey)?.lowercased() else { return nil }
        if value == "on" || value == "1" || value == "true" || value == "enabled" || value.contains("on") { return true }
        if value == "off" || value == "0" || value == "false" || value == "disabled" || value.contains("off") { return false }
        return nil
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(MeshTheme.accent)
                .frame(width: 24)
            Text(label)
                .foregroundStyle(MeshTheme.accent)
            Spacer()
            if canEdit {
                let toggleActive = MeshTheme.interactiveGreen
                HStack(spacing: 0) {
                    Button {
                        sendCLI(onCommand)
                    } label: {
                        Text("On")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isOn == true ? .black : MeshTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isOn == true ? toggleActive : Color.clear)
                    }
                    .buttonStyle(.plain)

                    Button {
                        sendCLI(offCommand)
                    } label: {
                        Text("Off")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isOn == false ? .black : MeshTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isOn == false ? toggleActive : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
                .background(MeshTheme.background)
                .clipShape(Capsule())
            } else {
                Text(isOn == true ? "On" : isOn == false ? "Off" : "\u{2014}")
                    .foregroundStyle(MeshTheme.textPrimary)
            }
        }
        .listRowBackground(MeshTheme.surface)
    }
}

#endif // !os(watchOS)

// MARK: - Clipboard Utility

/// Copy text to clipboard with auto-expiration for security.
/// iOS: uses UIPasteboard setItems with expirationDate.
/// macOS: uses NSPasteboard with a timed clear.
func copyToClipboard(_ text: String, expireAfter: TimeInterval = 60) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    let changeCount = NSPasteboard.general.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + expireAfter) {
        // Only clear if clipboard hasn't been changed by user since our copy
        if NSPasteboard.general.changeCount == changeCount {
            NSPasteboard.general.clearContents()
        }
    }
    #elseif !os(watchOS)
    UIPasteboard.general.setItems(
        [[UIPasteboard.typeAutomatic: text]],
        options: [.expirationDate: Date().addingTimeInterval(expireAfter)]
    )
    #endif
}
