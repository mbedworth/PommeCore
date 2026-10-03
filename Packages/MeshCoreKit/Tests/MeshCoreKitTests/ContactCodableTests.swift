//
//  ContactCodableTests.swift
//  MeshCoreKitTests
//
//  Contacts are decoded as an array, so one record the decoder refuses takes
//  the whole list with it. That is the failure mode critical rule 2 exists to
//  prevent, and the reason a contact backup — the only recovery from a
//  mistaken bulk delete — could otherwise fail to load entirely.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class ContactCodableTests: XCTestCase {

    private func decodeContact(_ json: String) throws -> Contact {
        try JSONDecoder().decode(Contact.self, from: Data(json.utf8))
    }

    private var key: Data { Data(repeating: 0x5A, count: 32) }
    private var keyBase64: String { key.base64EncodedString() }

    // MARK: - Round trip

    func testRoundTripPreservesEveryField() throws {
        let original = Contact(
            publicKey: key,
            name: "repeater-01",
            type: .repeater,
            flags: 0x07,
            outPathLen: 3,
            outPath: Data([1, 2, 3]),
            lastAdvert: 1_700_000_000,
            latitude: 51.5074,
            longitude: -0.1278,
            lastmod: 1_700_000_001
        )

        let decoded = try JSONDecoder().decode(
            Contact.self, from: try JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.publicKey, original.publicKey)
        XCTAssertEqual(decoded.name, "repeater-01")
        XCTAssertEqual(decoded.type, .repeater)
        XCTAssertEqual(decoded.flags, 0x07)
        XCTAssertEqual(decoded.outPathLen, 3)
        XCTAssertEqual(decoded.outPath, Data([1, 2, 3]))
        XCTAssertEqual(decoded.lastAdvert, 1_700_000_000)
        XCTAssertEqual(decoded.latitude, 51.5074, accuracy: 0.000001)
        XCTAssertEqual(decoded.longitude, -0.1278, accuracy: 0.000001)
        XCTAssertEqual(decoded.lastmod, 1_700_000_001)
    }

    // MARK: - Tolerant decoding

    /// A record carrying only the key must decode: the alternative is losing
    /// the contact rather than one of its fields.
    func testDecodesARecordCarryingOnlyThePublicKey() throws {
        let contact = try decodeContact(#"{"publicKey":"\#(keyBase64)"}"#)

        XCTAssertEqual(contact.publicKey, key)
        XCTAssertEqual(contact.name, "")
        XCTAssertEqual(contact.type, .unknown)
        XCTAssertEqual(contact.flags, 0)
        XCTAssertEqual(contact.lastAdvert, 0)
        XCTAssertEqual(contact.latitude, 0)
        XCTAssertEqual(contact.longitude, 0)
        XCTAssertEqual(contact.lastmod, 0)
    }

    /// Unrecorded routing must mean "no path known", not "direct". A wrong
    /// path sends messages into a dead end; no path floods and rediscovers.
    func testAMissingPathLengthMeansNoPathKnown() throws {
        let contact = try decodeContact(#"{"publicKey":"\#(keyBase64)"}"#)
        XCTAssertEqual(contact.outPathLen, -1)
        XCTAssertTrue(contact.outPath.isEmpty)
    }

    /// A field a newer build added must be ignored by an older one.
    func testUnknownFieldsAreIgnored() throws {
        let contact = try decodeContact(
            #"{"publicKey":"\#(keyBase64)","name":"n","fieldFromTheFuture":{"a":1}}"#
        )
        XCTAssertEqual(contact.name, "n")
    }

    /// A field of the wrong type degrades to its default instead of taking
    /// the record down.
    func testWrongTypesFallBackInsteadOfThrowing() throws {
        let contact = try decodeContact(
            #"{"publicKey":"\#(keyBase64)","name":42,"lastAdvert":"soon","latitude":"north"}"#
        )
        XCTAssertEqual(contact.name, "")
        XCTAssertEqual(contact.lastAdvert, 0)
        XCTAssertEqual(contact.latitude, 0)
    }

    /// An unrecognised contact type becomes `.unknown` rather than failing —
    /// firmware may introduce types this build has never heard of.
    func testUnrecognisedContactTypeBecomesUnknown() throws {
        let contact = try decodeContact(#"{"publicKey":"\#(keyBase64)","type":99}"#)
        XCTAssertEqual(contact.type, .unknown)
    }

    /// Without a key there is no identity and nothing is keyed to it, so this
    /// is the one field whose absence is an error.
    func testMissingPublicKeyIsAnError() {
        XCTAssertThrowsError(try decodeContact(#"{"name":"nameless"}"#))
    }

    // MARK: - Arrays

    /// The failure that mattered: a short record must not discard its
    /// neighbours.
    func testOneSparseRecordDoesNotTakeTheWholeArrayWithIt() throws {
        let other = Data(repeating: 0x11, count: 32).base64EncodedString()
        let json = """
        [{"publicKey":"\(keyBase64)","name":"full","type":1,"flags":0,"outPathLen":0,\
        "outPath":"","lastAdvert":1700000000,"latitude":1,"longitude":2,"lastmod":3},\
        {"publicKey":"\(other)"}]
        """

        let contacts = try JSONDecoder().decode([Contact].self, from: Data(json.utf8))

        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].name, "full")
        XCTAssertEqual(contacts[1].name, "")
    }
}
