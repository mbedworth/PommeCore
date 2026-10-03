//
//  BatteryCalibrationTests.swift
//  MeshCoreKitTests
//
//  BatteryCalibration is persisted to iCloud key-value storage and read back
//  with `try?`, so a decode failure is silent: the calibration is discarded
//  and the battery gauge reverts to uncorrected readings with no error shown.
//  These tests pin the tolerant decoder that critical rule 2 requires.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class BatteryCalibrationTests: XCTestCase {

    private func decode(_ json: String) throws -> BatteryCalibration {
        try JSONDecoder().decode(BatteryCalibration.self, from: Data(json.utf8))
    }

    func testDecodesCompleteRecord() throws {
        let cal = try decode("""
        {"chemistry":"lifepo4","measuredMaxVoltage":3.55,"correctionFactor":1.028}
        """)
        XCTAssertEqual(cal.chemistry, "lifepo4")
        XCTAssertEqual(cal.measuredMaxVoltage, 3.55, accuracy: 0.0001)
        XCTAssertEqual(cal.correctionFactor, 1.028, accuracy: 0.0001)
    }

    /// The case rule 2 is about: a record written by an older build, missing a
    /// field a newer build added. It must survive with a usable default rather
    /// than throwing and being silently dropped.
    func testMissingFieldsFallBackToDefaults() throws {
        let cal = try decode(#"{"chemistry":"lipo"}"#)
        XCTAssertEqual(cal.chemistry, "lipo")
        XCTAssertEqual(cal.measuredMaxVoltage, 0)
        XCTAssertEqual(cal.correctionFactor, 1.0, "an absent factor must not scale readings")
    }

    func testEmptyObjectDecodesToAnIdentityCalibration() throws {
        let cal = try decode("{}")
        XCTAssertEqual(cal.chemistry, BatteryChemistry.lipo.rawValue)
        XCTAssertEqual(cal.correctionFactor, 1.0)
        XCTAssertEqual(cal.correctedMillivolts(3700), 3700, "identity factor must pass readings through")
    }

    /// Unknown future keys must not break an older build reading the record.
    func testUnknownKeysAreIgnored() throws {
        let cal = try decode("""
        {"chemistry":"li18650","correctionFactor":1.05,"cycleCount":42,"nested":{"a":1}}
        """)
        XCTAssertEqual(cal.chemistry, "li18650")
        XCTAssertEqual(cal.correctionFactor, 1.05, accuracy: 0.0001)
    }

    /// A wrong-typed field should degrade to the default, not throw.
    func testWrongTypeFallsBackInsteadOfThrowing() throws {
        let cal = try decode(#"{"chemistry":"lipo","correctionFactor":"1.1"}"#)
        XCTAssertEqual(cal.correctionFactor, 1.0)
    }

    func testRoundTripPreservesValues() throws {
        var original = BatteryCalibration(chemistry: BatteryChemistry.lipo.rawValue)
        original.updateWithReading(4.05, theoreticalMax: 4.20)
        let restored = try JSONDecoder().decode(
            BatteryCalibration.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored.measuredMaxVoltage, original.measuredMaxVoltage, accuracy: 0.0001)
        XCTAssertEqual(restored.correctionFactor, original.correctionFactor, accuracy: 0.0001)
    }
}
