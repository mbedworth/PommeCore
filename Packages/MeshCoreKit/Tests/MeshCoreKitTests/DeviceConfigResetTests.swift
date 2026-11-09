//
//  DeviceConfigResetTests.swift
//  MeshCoreKitTests
//
//  `reset()` runs on every disconnect. It used to restore `radioFrequency` to
//  906000 — a real, legal, plausible frequency — while seven call sites across
//  the app test `== 0` / `> 0` to mean "we have not heard from a radio yet".
//  So the radio editor's guard never fired: after a reconnect it loaded 906.000
//  as though the radio had reported it, and Apply wrote that back, rebooting
//  the user's radio onto 906 MHz. Reported in a 2★ App Store review on
//  2026-05-11 ("after a few Bluetooth disconnects it resets back to 906"),
//  root-caused 2026-11-08.
//
//  A sentinel that is indistinguishable from a real value is not a sentinel.
//  These tests pin the sentinel, not the number 906.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class DeviceConfigResetTests: XCTestCase {

    /// A fresh config has never heard from a radio, so it has no frequency.
    func testFreshConfigReportsUnknownFrequency() {
        let config = DeviceConfig()
        XCTAssertEqual(config.radioFrequency, 0,
                       "A DeviceConfig that has never seen a SELF_INFO must report 0, "
                       + "the value every caller tests for, not a plausible default.")
    }

    /// The disconnect path is the one that bit: a real frequency arrives, the
    /// link drops, and whatever `reset()` leaves behind is what the radio
    /// editor loads.
    func testResetClearsFrequencyRatherThanRestoringADefault() {
        let config = DeviceConfig()
        config.radioFrequency = 910_525      // what a US radio actually reports
        config.reset()

        XCTAssertEqual(config.radioFrequency, 0,
                       "reset() must leave the frequency unknown. Restoring any real "
                       + "frequency here is what reprogrammed radios to 906 MHz.")
    }

    /// The property the whole fix rests on: "unknown" has to be distinguishable
    /// from "legal frequency". 906 MHz is inside the US 902–928 MHz band, which
    /// is exactly why nothing looked wrong.
    func testUnknownIsNotMistakableForALegalFrequency() {
        let config = DeviceConfig()
        config.reset()

        let freqMHz = Double(config.radioFrequency) / 1000.0
        XCTAssertFalse((902.0...928.0).contains(freqMHz),
                       "The unknown sentinel must not fall inside a legal band, or "
                       + "every `> 0` check in the app silently accepts it as real.")
    }

    /// `frequencyMHz` is what the UI formats. It must agree that nothing is known.
    func testFrequencyMHzIsZeroWhenUnknown() {
        let config = DeviceConfig()
        config.reset()
        XCTAssertEqual(config.frequencyMHz, 0, accuracy: 0.0001,
                       "A derived display value must not invent a frequency either.")
    }
}
