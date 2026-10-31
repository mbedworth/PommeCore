//
//  RemoteDeviceSessionTests.swift
//  MeshCoreKitTests
//
//  What a device says when it does not support a command, and the fact that
//  saying so is not a value.
//
//  Three refusal forms reach the app. The serial CLI answers an unknown command
//  with `??: <command>`; a getter for hardware the board lacks replies
//  `Error: unsupported`; and the companion CLI added in firmware 1.18.0 appends
//  the literal string `Unknown command`. All three are stored like any other
//  response, so `settings[key] ?? "—"` renders a refusal as the setting's value —
//  the `??` never fires, because the key exists and holds the refusal.
//
//  That shipped, and the screens it affects are the repeater, room-server and
//  sensor ones reached over BLE admin or USB CLI. A board without a given
//  capability answers `Error: unsupported`, and that refusal was rendered as the
//  setting's value.
//
//  **Not a companion-radio symptom.** It was found on 2026-10-30 by typing
//  `clock` into the Radio Terminal on an iPhone and getting `Unknown command`,
//  which prompted an audit — but the terminal was right to print that, and
//  `companionDeviceSession` is never surfaced by any view, so a companion has no
//  settings screen to get this wrong on. An earlier version of this comment
//  claimed the Device Clock row read "Unknown command" on an iPhone; that was
//  inferred from the code and never observed.
//
//  There were ~45 direct `settings[...]` reads in the views and two uses of
//  `supportedValue(for:)`. The mechanism was understood and documented; the call
//  sites never adopted it. These tests cover the accessors the views now go
//  through, which is also why the logic was moved out of the view bodies — a
//  `settings[...]` read inside a SwiftUI body is unreachable from any test.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

@MainActor
final class RemoteDeviceSessionTests: XCTestCase {

    /// Every way a device can decline, including casing and surrounding space,
    /// because the refusal is matched case-insensitively on a trimmed string.
    private static let refusals = [
        "Unknown command",          // companion CLI, firmware 1.18.0+
        "unknown command",
        "UNKNOWN COMMAND",
        "  Unknown command  ",
        "??: get role",             // serial CLI
        "??",
        "Error: unsupported",       // getter for absent hardware
        "error: unsupported",
        "Unsupported",
        "",                         // stored but empty
        "   "
    ]

    private func session(_ settings: [String: String]) -> RemoteDeviceSession {
        let s = RemoteDeviceSession(contact: Contact(publicKey: Data(repeating: 0x11, count: 32),
                                                     name: "MPB-CB",
                                                     type: .repeater))
        for (k, v) in settings { s.settings[k] = v }
        return s
    }

    // MARK: - supportedValue

    func testEveryRefusalFormReadsAsUnsupported() {
        for refusal in Self.refusals {
            let s = session(["role": refusal])
            XCTAssertNil(s.supportedValue(for: "role"),
                         "\"\(refusal)\" should not read as a value")
            XCTAssertFalse(s.isSupported("role"))
        }
    }

    func testAGenuineValueIsReturnedAndTrimmed() {
        XCTAssertEqual(session(["role": "Repeater"]).supportedValue(for: "role"), "Repeater")
        XCTAssertEqual(session(["role": "  Repeater  "]).supportedValue(for: "role"), "Repeater")
    }

    func testAnUnfetchedKeyIsUnsupported() {
        XCTAssertNil(session([:]).supportedValue(for: "role"))
    }

    /// A value that merely *contains* a refusal word must still be a value.
    /// `hasPrefix("error")` is deliberately a prefix test, not a substring one.
    func testAValueMentioningAnErrorIsStillAValue() {
        XCTAssertEqual(session(["owner.info": "Report errors to me"]).supportedValue(for: "owner.info"),
                       "Report errors to me")
    }

    // MARK: - displayValue — the row that showed "Unknown command"

    func testDisplayValueFallsBackToThePlaceholderOnARefusal() {
        for refusal in Self.refusals {
            XCTAssertEqual(session(["tx": refusal]).displayValue(for: "tx"), "\u{2014}",
                           "\"\(refusal)\" reached the screen")
        }
    }

    func testDisplayValuePassesAGenuineValueThrough() {
        XCTAssertEqual(session(["tx": "22"]).displayValue(for: "tx"), "22")
    }

    /// The bug in its original shape, kept as a regression guard: this is what
    /// the call sites used to do, and it is what must never come back.
    func testTheOldPatternWouldHaveShownTheRefusal() {
        let s = session(["role": "Unknown command"])
        XCTAssertEqual(s.settings["role"] ?? "\u{2014}", "Unknown command",
                       "Precondition: the raw read does surface the refusal")
        XCTAssertEqual(s.displayValue(for: "role"), "\u{2014}",
                       "The accessor must not")
    }

    // MARK: - A renamed setting

    /// `dutycycle` replaced `af` in 1.15.0 and the app fetches both, so the
    /// reading is "whichever answered". `settings["dutycycle"] ?? settings["af"]`
    /// gets this backwards on a device that has only the old name: the newer key
    /// holds a refusal, which is not nil, so `??` never reaches `af`.
    func testAnyPrefersWhicheverKeyActuallyAnswered() {
        let oldFirmware = session(["dutycycle": "Unknown command", "af": "1.5"])
        XCTAssertEqual(oldFirmware.supportedValue(forAny: ["dutycycle", "af"]), "1.5")
        XCTAssertEqual(oldFirmware.settings["dutycycle"] ?? oldFirmware.settings["af"], "Unknown command",
                       "Precondition: the old `??` chain picks the refusal")

        let newFirmware = session(["dutycycle": "2.0", "af": "1.5"])
        XCTAssertEqual(newFirmware.supportedValue(forAny: ["dutycycle", "af"]), "2.0",
                       "When both answer, the first key wins")

        let neither = session(["dutycycle": "Unknown command", "af": "??: get af"])
        XCTAssertNil(neither.supportedValue(forAny: ["dutycycle", "af"]))
        XCTAssertEqual(neither.displayValue(forAny: ["dutycycle", "af"]), "\u{2014}")
    }

    // MARK: - get radio

    func testRadioParametersParse() {
        let p = session(["radio": "910.525,250,10,5"]).radioParameters
        XCTAssertEqual(p?.freqKHz ?? 0, 910_525, accuracy: 0.001)
        XCTAssertEqual(p?.bw ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(p?.sf, 10)
        XCTAssertEqual(p?.cr, 5)
    }

    func testRadioParametersTolerateSpaces() {
        XCTAssertEqual(session(["radio": "910.525, 250, 10, 5"]).radioParameters?.sf, 10)
    }

    /// The old code returned `(0, 0, 0, 0)` here — a radio apparently tuned to
    /// 0 MHz, fed straight into preset detection and indistinguishable from a
    /// genuine parse failure. `nil` is the honest answer.
    func testRadioParametersAreNilWhenUnsupported() {
        XCTAssertNil(session(["radio": "Unknown command"]).radioParameters)
        XCTAssertNil(session(["radio": "Error: unsupported"]).radioParameters)
        XCTAssertNil(session([:]).radioParameters)
    }

    func testRadioParametersAreNilWhenMalformed() {
        XCTAssertNil(session(["radio": "910.525,250"]).radioParameters)
        XCTAssertNil(session(["radio": "not,a,radio,line"]).radioParameters)
    }

    // MARK: - clock

    func testClockDisplayFormatsAnEpoch() {
        let s = session(["clock": "1760000000"])
        XCTAssertEqual(s.clockDisplay(formatter: { String(Int($0.timeIntervalSince1970)) }), "1760000000")
    }

    func testClockDisplayPassesAHumanReadableReplyThrough() {
        XCTAssertEqual(session(["clock": "21:44 - 30/10/2026"]).clockDisplay(), "21:44 - 30/10/2026")
    }

    /// The companion radio case: no `clock` command at all, because its time is
    /// set over the binary link rather than the CLI.
    func testClockDisplayIsThePlaceholderWhenUnsupported() {
        XCTAssertEqual(session(["clock": "Unknown command"]).clockDisplay(), "\u{2014}")
        XCTAssertEqual(session([:]).clockDisplay(), "\u{2014}")
    }

    /// `now` is built from components rather than an epoch literal. The first
    /// version of this test used `1_760_000_000` with the comment "2026"; that
    /// is October **2025**, so a device clock reading 2026 was correctly judged
    /// a year out and the test failed. A magic number with a reassuring comment
    /// beside it is not a fixture, it is an assumption.
    private func date(year: Int, month: Int = 10, day: Int = 30) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 21, minute: 44))!
    }

    func testClockStalenessByYear() {
        let now = date(year: 2026)
        XCTAssertFalse(session(["clock": "21:44 - 30/10/2026"]).isClockStale(now: now))
        XCTAssertTrue(session(["clock": "21:44 - 30/10/2024"]).isClockStale(now: now))
    }

    func testClockStalenessByEpoch() {
        let now = date(year: 2026)
        let epoch = now.timeIntervalSince1970
        XCTAssertFalse(session(["clock": String(Int(epoch + 30))]).isClockStale(now: now),
                       "30s is within tolerance")
        XCTAssertTrue(session(["clock": String(Int(epoch - 400_000))]).isClockStale(now: now))
    }

    /// An unsupported clock must not read as stale. Offering to fix a clock the
    /// device does not expose is a prompt the user can never satisfy.
    func testAnUnsupportedClockIsNotStale() {
        XCTAssertFalse(session(["clock": "Unknown command"]).isClockStale())
        XCTAssertFalse(session([:]).isClockStale())
    }

    // MARK: - role

    func testRoleFallsBackWhenUnsupported() {
        XCTAssertEqual(session(["role": "Unknown command"]).roleLabel(fallback: "Repeater"), "Repeater")
        XCTAssertEqual(session([:]).roleLabel(fallback: "Repeater"), "Repeater")
    }

    func testRoleUsesTheDeviceAnswerWhenItHasOne() {
        XCTAssertEqual(session(["role": "Room Server"]).roleLabel(fallback: "Repeater"), "Room Server")
    }

    // MARK: - section population

    /// `hasCachedSettings` asks whether a reply was ever stored, and a refusal is
    /// a stored reply — so a section of entirely unsupported commands reports as
    /// populated. `hasSupportedSettings` asks the question a view wants.
    func testASectionOfRefusalsIsNotPopulated() {
        let s = session(["loop.detect": "Unknown command",
                         "path.hash.mode": "Unknown command",
                         "region default": "Unknown command"])
        XCTAssertTrue(s.hasCachedSettings(for: "routing"),
                      "Precondition: replies were stored")
        XCTAssertFalse(s.hasSupportedSettings(for: "routing"),
                       "But none of them is a value")
    }

    func testASectionWithOneRealValueIsPopulated() {
        let s = session(["loop.detect": "moderate", "path.hash.mode": "Unknown command"])
        XCTAssertTrue(s.hasSupportedSettings(for: "routing"))
    }

    func testAnUnknownSectionIsNotPopulated() {
        XCTAssertFalse(session([:]).hasSupportedSettings(for: "no-such-section"))
    }

    // MARK: - firmware gating still works through the same filter

    func testFirmwareVersionIsNilOnARefusal() {
        XCTAssertNil(session(["ver": "Unknown command"]).firmwareVersion)
        XCTAssertFalse(session(["ver": "Unknown command"]).firmwareAtLeast(1, 17))
    }

    func testFirmwareVersionParsesARealReply() {
        let s = session(["ver": "v1.18.0-81dbae5"])
        XCTAssertNotNil(s.firmwareVersion)
        XCTAssertTrue(s.firmwareAtLeast(1, 18))
        XCTAssertFalse(s.firmwareAtLeast(1, 19))
    }
}
