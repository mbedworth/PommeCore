//
//  TelemetryParsingTests.swift
//  MeshCoreKit
//
//  Cayenne LPP telemetry parsing (PUSH_CODE_TELEMETRY_RESPONSE, 0x8B).
//
//  Created by Michael P. Bedworth on 08/24/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class TelemetryParsingTests: XCTestCase {

    /// Build a 0x8B push frame: code(1) reserved(1) pub_key_prefix(6) lpp(...)
    private func telemetryFrame(_ lpp: [UInt8]) -> Data {
        Data([0x8B, 0x00] + Array(repeating: UInt8(0xAA), count: 6) + lpp)
    }

    private func readings(_ lpp: [UInt8]) -> [TelemetryReading] {
        guard case .telemetryResponse(_, let readings) = FrameParser.parse(telemetryFrame(lpp)) else {
            XCTFail("Expected a telemetry response")
            return []
        }
        return readings
    }

    /// Firmware 1.17.0 adds MCU temperature on the self channel, so a node with an
    /// external temperature sensor now reports two temperatures in one response.
    func testDuplicateTemperaturesStayDistinct() {
        let lpp: [UInt8] = [
            0x01, 0x74, 0x01, 0x8A,  // ch1 voltage 3.94 V
            0x02, 0x67, 0x00, 0xDC,  // ch2 temperature 22.0 C (external sensor)
            0x01, 0x67, 0x01, 0x36,  // ch1 temperature 31.0 C (MCU)
        ]
        let parsed = readings(lpp)
        XCTAssertEqual(parsed.count, 3)

        let temps = parsed.filter { $0.name == "Temperature" }
        XCTAssertEqual(temps.count, 2)
        XCTAssertEqual(Set(temps.map(\.key)).count, 2, "Duplicate types must not share a history key")
        XCTAssertEqual(temps.first(where: { $0.channel == 2 })?.value ?? 0, 22.0, accuracy: 0.01)
        XCTAssertEqual(temps.first(where: { $0.channel == 1 })?.value ?? 0, 31.0, accuracy: 0.01)

        // A type appearing once keeps its plain label; ambiguous ones are channel-qualified.
        XCTAssertEqual(parsed.first(where: { $0.name == "Battery" })?.label, "Battery")
        XCTAssertTrue(temps.allSatisfy { $0.label.contains("Ch") })
    }

    /// Two readings of the same type on the same channel (ambient + MCU on channel 1).
    func testSameChannelDuplicatesGetIndexedKeys() {
        let lpp: [UInt8] = [
            0x01, 0x67, 0x00, 0xDC,
            0x01, 0x67, 0x01, 0x36,
        ]
        let parsed = readings(lpp)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(Set(parsed.map(\.key)).count, 2)
    }

    /// Negative temperatures are signed big-endian.
    func testNegativeTemperature() {
        let lpp: [UInt8] = [0x01, 0x67, 0xFF, 0x38]  // -20.0 C
        XCTAssertEqual(readings(lpp).first?.value ?? 0, -20.0, accuracy: 0.01)
    }

    /// Altitude (0x79) sits between two readings — an unparsed type used to desync
    /// everything after it, turning the remaining bytes into bogus readings.
    func testKnownTypeDoesNotDesyncLaterReadings() {
        let lpp: [UInt8] = [
            0x02, 0x79, 0x00, 0x64,  // ch2 altitude 100 m
            0x02, 0x68, 0x64,        // ch2 humidity 50 %
        ]
        let parsed = readings(lpp)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].name, "Altitude")
        XCTAssertEqual(parsed[1].name, "Humidity")
        XCTAssertEqual(parsed[1].value, 50.0, accuracy: 0.01)
    }

    /// An unknown type has an unknown length, so parsing must stop rather than guess.
    func testUnknownTypeStopsParsing() {
        let lpp: [UInt8] = [
            0x01, 0x74, 0x01, 0x8A,  // ch1 voltage — kept
            0x01, 0xF0, 0x01, 0x02,  // unknown type
            0x01, 0x67, 0x00, 0xDC,  // would be misread if parsing continued
        ]
        let parsed = readings(lpp)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "Battery")
    }

    /// A truncated trailing entry must not produce a zero-filled reading.
    func testTruncatedPayloadIsDropped() {
        let lpp: [UInt8] = [
            0x01, 0x74, 0x01, 0x8A,
            0x02, 0x67, 0x00,  // temperature missing its second byte
        ]
        let parsed = readings(lpp)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "Battery")
    }

    /// GPS expands into three readings and shares the channel of its entry.
    func testGPSExpandsToLatLonAltitude() {
        let lpp: [UInt8] = [
            0x01, 0x88,
            0x07, 0x5B, 0xCD,  // lat
            0xFF, 0x8A, 0x33,  // lon (negative)
            0x00, 0x27, 0x10,  // alt 100.00 m
        ]
        let parsed = readings(lpp)
        XCTAssertEqual(parsed.map(\.name), ["GPS Lat", "GPS Lon", "Altitude"])
        XCTAssertTrue(parsed.allSatisfy { $0.channel == 1 })
        XCTAssertEqual(parsed[2].value, 100.0, accuracy: 0.01)
        XCTAssertLessThan(parsed[1].value, 0)
    }
}
