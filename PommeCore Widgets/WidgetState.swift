//
//  WidgetState.swift
//  PommeCore
//
//  Shared between the main iOS app (writes) and the widget extension (reads)
//  via a shared App Group UserDefaults container.
//

import Foundation

let widgetAppGroupID = "group.com.mbedworth.meshcore"
private let widgetStateKey = "widgetState"

struct WidgetState: Codable {
    var isConnected: Bool = false
    var deviceName: String = ""
    var batteryPct: Int = -1        // -1 = unknown
    var unreadCount: Int = 0
    var activeZoneCount: Int = 0
    var alertZoneName: String? = nil
    var lastMessageSender: String? = nil
    var lastMessagePreview: String? = nil
    var lastMessageDate: Date? = nil

    static func load() -> WidgetState {
        guard let defaults = UserDefaults(suiteName: widgetAppGroupID),
              let data = defaults.data(forKey: widgetStateKey),
              let state = try? JSONDecoder().decode(WidgetState.self, from: data) else {
            return WidgetState()
        }
        return state
    }

    func save() {
        guard let defaults = UserDefaults(suiteName: widgetAppGroupID),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: widgetStateKey)
    }
}
