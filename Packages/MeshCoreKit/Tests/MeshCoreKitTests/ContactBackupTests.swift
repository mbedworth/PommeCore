//
//  ContactBackupTests.swift
//  MeshCoreKitTests
//
//  A contact backup is the last copy of data that cannot be re-derived: once
//  contacts are removed from the radio, only a snapshot brings them back. So
//  the two things tested hardest here are that an old or odd file still loads,
//  and that restore cannot crash on the values a file might contain.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class ContactBackupTests: XCTestCase {

    // MARK: - Fixtures

    private func contact(
        _ id: UInt8,
        name: String = "node",
        lat: Double = 0,
        lon: Double = 0
    ) -> Contact {
        var key = Data(repeating: id, count: 32)
        key[0] = id
        key[1] = id &+ 100
        return Contact(
            publicKey: key,
            name: name,
            type: .chat,
            lastAdvert: 1_700_000_000,
            latitude: lat,
            longitude: lon
        )
    }

    private func roundTrip(_ backup: ContactBackup) throws -> ContactBackup {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContactBackup.self, from: try encoder.encode(backup))
    }

    private func decode(_ json: String) throws -> ContactBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContactBackup.self, from: Data(json.utf8))
    }

    // MARK: - Round trip

    func testRoundTripPreservesEverything() throws {
        let backup = ContactBackup(
            reason: "deleting 2 contacts",
            radioPublicKeyHex: "abcd",
            contacts: [contact(1, name: "alpha"), contact(2, name: "beta")],
            nicknames: ["aa": "Alpha"],
            notes: ["aa": "a note"],
            mutedContacts: ["bb"],
            groupMembership: ["Family": ["aa", "bb"]]
        )

        let decoded = try roundTrip(backup)

        XCTAssertEqual(decoded.contacts.count, 2)
        XCTAssertEqual(decoded.contacts.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(decoded.reason, "deleting 2 contacts")
        XCTAssertEqual(decoded.radioPublicKeyHex, "abcd")
        XCTAssertEqual(decoded.nicknames, ["aa": "Alpha"])
        XCTAssertEqual(decoded.notes, ["aa": "a note"])
        XCTAssertEqual(decoded.mutedContacts, ["bb"])
        XCTAssertEqual(decoded.groupMembership, ["Family": ["aa", "bb"]])
    }

    // MARK: - Tolerant decoding (critical rule 2)

    /// A file from a build that only stored contacts must still load — losing
    /// the nicknames is an annoyance, failing to decode would lose the
    /// contacts entirely.
    func testDecodesAFileCarryingOnlyContacts() throws {
        let json = """
        {"contacts":[{"publicKey":"\(Data(repeating: 7, count: 32).base64EncodedString())",\
        "name":"solo","type":0,"lastAdvert":1700000000,"flags":0,"outPathLen":-1,\
        "outPath":"","latitude":0,"longitude":0}]}
        """
        let decoded = try decode(json)

        XCTAssertEqual(decoded.contacts.count, 1)
        XCTAssertEqual(decoded.version, 0)
        XCTAssertEqual(decoded.reason, "")
        XCTAssertTrue(decoded.nicknames.isEmpty)
        XCTAssertEqual(decoded.createdAt, .distantPast)
    }

    /// A field this build does not know about must be ignored, not fatal — a
    /// newer build's backup still has to restore after a downgrade.
    func testUnknownFieldsAreIgnored() throws {
        var backup = try roundTrip(ContactBackup(
            reason: "r", radioPublicKeyHex: "aa", contacts: [contact(1)]
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(backup)
        ) as! [String: Any]
        object["somethingFromTheFuture"] = ["nested": 1]
        object["version"] = 99

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        backup = try decoder.decode(ContactBackup.self, from: data)

        XCTAssertEqual(backup.contacts.count, 1)
        XCTAssertEqual(backup.version, 99, "a newer version must load, not be refused")
    }

    /// A wrong type in an optional field must degrade to the default rather
    /// than take the whole file down with it.
    func testWrongTypeInAnOptionalFieldFallsBack() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(ContactBackup(reason: "r", radioPublicKeyHex: "aa",
                                                   contacts: [contact(1)]))
        ) as! [String: Any]
        object["nicknames"] = "not a dictionary"
        object["mutedContacts"] = 42

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ContactBackup.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.contacts.count, 1)
        XCTAssertTrue(decoded.nicknames.isEmpty)
        XCTAssertTrue(decoded.mutedContacts.isEmpty)
    }

    /// Without contacts there is nothing to restore, so this is the one field
    /// whose absence is an error.
    func testMissingContactsIsAnError() {
        XCTAssertThrowsError(try decode(#"{"reason":"r","version":1}"#))
    }

    // MARK: - Radio scoping

    func testBackupBelongsOnlyToItsOwnRadio() {
        let backup = ContactBackup(reason: "r", radioPublicKeyHex: "aabb", contacts: [contact(1)])
        XCTAssertTrue(backup.belongs(toRadio: "aabb"))
        XCTAssertFalse(backup.belongs(toRadio: "ccdd"))
    }

    /// A file written before scoping existed has no radio key. Offer it rather
    /// than hide it: an unrestorable backup is worse than one the user judges.
    func testBackupWithNoRadioKeyIsOfferedToAnyRadio() {
        let backup = ContactBackup(reason: "r", radioPublicKeyHex: "", contacts: [contact(1)])
        XCTAssertTrue(backup.belongs(toRadio: "aabb"))
    }

    // MARK: - Restore frames

    func testRestoreFramesAreOnePerContactInOrder() {
        let backup = ContactBackup(
            reason: "r", radioPublicKeyHex: "aa",
            contacts: [contact(1, name: "one"), contact(2, name: "two"), contact(3, name: "three")]
        )
        let frames = backup.restoreFrames()

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.name), ["one", "two", "three"])
        for entry in frames {
            XCTAssertEqual(entry.frame.first, MeshCoreCommand.addUpdateContact.rawValue)
            XCTAssertEqual(entry.frame.count, 144, "fixed-width ADD_UPDATE_CONTACT frame")
        }
    }

    func testRestoreFrameCarriesTheFullPublicKey() {
        let c = contact(9)
        let frame = ContactBackup(reason: "r", radioPublicKeyHex: "aa", contacts: [c])
            .restoreFrames()[0].frame

        XCTAssertEqual(frame[1..<33], c.publicKey, "the key must survive intact")
    }

    func testRestoreFramesForAnEmptyBackupAreEmpty() {
        XCTAssertTrue(
            ContactBackup(reason: "r", radioPublicKeyHex: "aa", contacts: []).restoreFrames().isEmpty
        )
    }

    // MARK: - Coordinate conversion

    func testCoordinatesConvertToMicroDegrees() {
        XCTAssertEqual(ContactBackup.microDegrees(51.5074), 51_507_400)
        XCTAssertEqual(ContactBackup.microDegrees(-0.1278), -127_800)
        XCTAssertEqual(ContactBackup.microDegrees(0), 0)
    }

    /// The crash that must not happen: restore is the recovery path, so a
    /// nonsense coordinate in a corrupt file has to become "no position", not
    /// a trap.
    func testNonFiniteAndOutOfRangeCoordinatesBecomeZero() {
        XCTAssertEqual(ContactBackup.microDegrees(.nan), 0)
        XCTAssertEqual(ContactBackup.microDegrees(.infinity), 0)
        XCTAssertEqual(ContactBackup.microDegrees(-.infinity), 0)
        XCTAssertEqual(ContactBackup.microDegrees(1e12), 0)
        XCTAssertEqual(ContactBackup.microDegrees(-1e12), 0)
    }

    func testBuildingFramesSurvivesACorruptCoordinate() {
        let backup = ContactBackup(
            reason: "r", radioPublicKeyHex: "aa",
            contacts: [contact(1, lat: .nan, lon: 1e300)]
        )
        let frames = backup.restoreFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frame.count, 144)
    }

    // MARK: - Retention

    func testNothingIsPrunedBelowTheKeepCount() {
        let dates = (0..<ContactBackupRetention.keepCount).map {
            Date(timeIntervalSince1970: Double($0))
        }
        XCTAssertTrue(ContactBackupRetention.filesToPrune(dates, date: { $0 }).isEmpty)
    }

    func testOldestBeyondTheKeepCountArePruned() {
        let total = ContactBackupRetention.keepCount + 3
        let dates = (0..<total).map { Date(timeIntervalSince1970: Double($0)) }

        let doomed = ContactBackupRetention.filesToPrune(dates, date: { $0 })

        XCTAssertEqual(doomed.count, 3)
        XCTAssertEqual(
            Set(doomed),
            Set(dates.prefix(3)),
            "the three oldest go, whatever order they were given in"
        )
    }

    /// Retention must not depend on the caller having sorted them.
    func testPruningIsIndependentOfInputOrder() {
        let total = ContactBackupRetention.keepCount + 2
        let dates = (0..<total).map { Date(timeIntervalSince1970: Double($0)) }

        XCTAssertEqual(
            Set(ContactBackupRetention.filesToPrune(dates.shuffled(), date: { $0 })),
            Set(dates.prefix(2))
        )
    }
}
