//
//  FirmwareVersionTests.swift
//  MeshCoreKitTests
//
//  FirmwareVersion gates UI on features that cannot be probed, so a parse that
//  silently produces 0.0.0 would hide a working control, and one that is too
//  generous would offer a command the radio rejects. Both failures are invisible
//  without the radio in front of you, which is what these tests stand in for.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class FirmwareVersionTests: XCTestCase {

    // MARK: - Parsing the shapes firmware actually reports

    func testParsesTheShapesDevicesReport() {
        // Every one of these has been seen from a radio, a release tag, or `get ver`.
        XCTAssertEqual(FirmwareVersion("1.17.1")?.description, "1.17.1")
        XCTAssertEqual(FirmwareVersion("v1.17.1")?.description, "1.17.1")
        XCTAssertEqual(FirmwareVersion("v1.17.1-d929643")?.description, "1.17.1")
        XCTAssertEqual(FirmwareVersion("vcompanion-v1.14.1")?.description, "1.14.1")
        XCTAssertEqual(FirmwareVersion("v1.16")?.description, "1.16.0")
    }

    func testRejectsStringsWithNoVersion() {
        // A device that did not understand `get ver` must not read as "very old",
        // because a gate would then hide a control that in fact works.
        XCTAssertNil(FirmwareVersion("??: ver"))
        XCTAssertNil(FirmwareVersion("Error: unsupported"))
        XCTAssertNil(FirmwareVersion(""))
        XCTAssertNil(FirmwareVersion("v1"))
    }

    // MARK: - Ordering

    func testOrdersByComponentNotLexically() {
        // "1.9.0" > "1.17.0" is the classic string-compare bug this type exists to avoid.
        XCTAssertTrue(FirmwareVersion("1.17.0")! > FirmwareVersion("1.9.0")!)
        XCTAssertTrue(FirmwareVersion("1.17.1")! > FirmwareVersion("1.17.0")!)
        XCTAssertTrue(FirmwareVersion("2.0.0")! > FirmwareVersion("1.99.99")!)
        XCTAssertEqual(FirmwareVersion("1.17.0")!, FirmwareVersion("v1.17.0-abc")!)
    }

    func testMissingPatchComparesAsZero() {
        XCTAssertEqual(FirmwareVersion("1.17")!, FirmwareVersion("1.17.0")!)
        XCTAssertTrue(FirmwareVersion("1.17.1")! > FirmwareVersion("1.17")!)
    }

    // MARK: - The gate as the UI uses it

    @MainActor
    func testFirmwareAtLeastGatesOnTheReportedVersion() {
        let session = RemoteDeviceSession(contact: Self.roomContact)

        // No version fetched yet: the control stays hidden rather than offering a
        // command the device may not have.
        XCTAssertFalse(session.firmwareAtLeast(1, 17))

        session.settings["ver"] = "v1.16.0-abc1234"
        XCTAssertFalse(session.firmwareAtLeast(1, 17))

        session.settings["ver"] = "v1.17.1-d929643"
        XCTAssertTrue(session.firmwareAtLeast(1, 17))
        XCTAssertTrue(session.firmwareAtLeast(1, 17, 1))
        XCTAssertFalse(session.firmwareAtLeast(1, 18))

        // An unsupported reply is not a version, and must not pass the gate.
        session.settings["ver"] = "??: ver"
        XCTAssertFalse(session.firmwareAtLeast(1, 17))
        XCTAssertNil(session.firmwareVersion)
    }

    private static var roomContact: Contact {
        Contact(publicKey: Data(repeating: 0xAB, count: 32),
                name: "Test Room",
                type: .room,
                flags: 0,
                outPathLen: -1,
                outPath: Data(),
                lastAdvert: 0,
                latitude: 0,
                longitude: 0)
    }
}
