//
//  NodeRole.swift
//  MeshCoreApple
//
//  Device role definitions for the Node Setup Wizard.
//  Maps firmware device types + connection transport to standardized naming codes.
//
//  Created by Michael P. Bedworth on 4/1/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// Active connection transport, derived from ConnectionManager routing state.
enum Transport: String, CaseIterable {
    case ble
    case usb
    case wifi
}

/// Standardized node role for mesh naming convention.
/// Each role has a 2-character code used in the generated node name.
enum NodeRole: String, CaseIterable, Identifiable {
    case coreRepeater
    case edgeRepeater
    case roomServer
    case mqttGateway
    case kissModem
    case companionBLE
    case companionUSB
    case companionWiFi
    case sensor
    case secureChat

    var id: String { rawValue }

    /// 2-character code used in the node name (e.g. "CR", "CB").
    var code: String {
        switch self {
        case .coreRepeater:  return "CR"
        case .edgeRepeater:  return "ER"
        case .roomServer:    return "RS"
        case .mqttGateway:   return "MQ"
        case .kissModem:     return "KS"
        case .companionBLE:  return "CB"
        case .companionUSB:  return "CU"
        case .companionWiFi: return "CW"
        case .sensor:        return "SN"
        case .secureChat:    return "SC"
        }
    }

    var displayName: String {
        switch self {
        case .coreRepeater:  return "Core Repeater"
        case .edgeRepeater:  return "Edge Repeater"
        case .roomServer:    return "Room Server"
        case .mqttGateway:   return "MQTT Gateway"
        case .kissModem:     return "KISS Modem"
        case .companionBLE:  return "Companion BLE"
        case .companionUSB:  return "Companion USB"
        case .companionWiFi: return "Companion WiFi"
        case .sensor:        return "Sensor"
        case .secureChat:    return "Secure Chat"
        }
    }

    var icon: String {
        switch self {
        case .coreRepeater:  return "antenna.radiowaves.left.and.right"
        case .edgeRepeater:  return "wifi.router"
        case .roomServer:    return "server.rack"
        case .mqttGateway:   return "network"
        case .kissModem:     return "cable.connector"
        case .companionBLE:  return "wave.3.right"
        case .companionUSB:  return "cable.connector.horizontal"
        case .companionWiFi: return "wifi"
        case .sensor:        return "sensor"
        case .secureChat:    return "lock.shield"
        }
    }

    var isInfrastructure: Bool {
        switch self {
        case .coreRepeater, .edgeRepeater, .roomServer, .mqttGateway, .kissModem:
            return true
        case .companionBLE, .companionUSB, .companionWiFi, .sensor, .secureChat:
            return false
        }
    }

    /// Attempt to auto-detect role from firmware selfType and active transport.
    /// Returns nil when the role is ambiguous and the user must choose (e.g. repeater → CR or ER).
    static func detect(selfType: UInt8, transport: Transport) -> NodeRole? {
        switch selfType {
        case 1: // companion / chat
            switch transport {
            case .ble:  return .companionBLE
            case .usb:  return .companionUSB
            case .wifi: return .companionWiFi
            }
        case 2: // repeater — ambiguous (core vs edge)
            return nil
        case 3: // room server
            return .roomServer
        case 4: // sensor
            return .sensor
        default:
            return nil
        }
    }

    /// Roles to present when auto-detection returns nil for a given selfType.
    static func ambiguousChoices(selfType: UInt8) -> [NodeRole] {
        switch selfType {
        case 2: // repeater
            return [.coreRepeater, .edgeRepeater, .mqttGateway, .kissModem]
        default:
            return NodeRole.allCases
        }
    }
}
