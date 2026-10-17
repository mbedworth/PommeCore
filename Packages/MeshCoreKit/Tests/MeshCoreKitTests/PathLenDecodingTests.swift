//
//  PathLenDecodingTests.swift
//  MeshCoreKitTests
//
//  The protocol's `path_len` byte is two fields in one, and reading it whole
//  put "70 hops" on screen for a message that had travelled six — 0x46 is six
//  hops carrying two-byte hashes. Nothing caught it because nothing asserted
//  that a hop count must fit in six bits.
//
//  The firmware's accessors in Packet.h are the definition these test against:
//
//      getPathHashCount() { return path_len & 63; }
//      getPathHashSize()  { return (path_len >> 6) + 1; }
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class PathLenDecodingTests: XCTestCase {

    private func message(pathLen: UInt8?) -> Message {
        Message(
            senderKeyHash: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
            contactKeyHash: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
            text: "test",
            timestamp: Date(),
            isOutgoing: false,
            status: .delivered,
            hops: pathLen
        )
    }

    // MARK: - The reported defect

    /// The exact byte from the radio that rendered as "70 hops".
    func testTheByteThatRenderedAsSeventyIsSixHops() {
        XCTAssertEqual(message(pathLen: 0x46).hopCount, 6)
    }

    // MARK: - Field separation

    func testHopCountIgnoresTheHashSizeBits() {
        // Same six hops at each of the four hash sizes.
        for mode in UInt8(0)...UInt8(3) {
            let pathLen = (mode << 6) | 6
            XCTAssertEqual(message(pathLen: pathLen).hopCount, 6,
                           "hash mode \(mode) leaked into the hop count")
        }
    }

    func testDirectStaysDirectAtEveryHashSize() {
        // The auto-reset path check compares against 0. Before the fix a direct
        // message on a 2-byte-hash mesh arrived as 0x40 and never matched, so
        // a stale route was never reset.
        for mode in UInt8(0)...UInt8(3) {
            let pathLen = mode << 6
            XCTAssertEqual(message(pathLen: pathLen).hopCount, 0,
                           "hash mode \(mode) hid a direct message")
        }
    }

    // MARK: - Bounds

    func testHopCountNeverExceedsSixBits() {
        // The property under test: no byte can produce a count above 63, which
        // is the assertion whose absence let 70 reach the screen.
        for raw in UInt8.min...UInt8.max {
            guard let count = message(pathLen: raw).hopCount else { continue }
            XCTAssertLessThanOrEqual(count, 63, "path_len \(raw) decoded to \(count)")
            XCTAssertGreaterThanOrEqual(count, 0)
        }
    }

    func testMaximumRepresentableHopCount() {
        XCTAssertEqual(message(pathLen: 0x3F).hopCount, 63)
    }

    // MARK: - Sentinel

    func testUnknownPathIsNilRatherThanSixtyThree() {
        // 0xFF must be tested before masking: read as a count it would decode
        // to a plausible-looking 63 hops.
        XCTAssertNil(message(pathLen: Message.pathLenUnknown).hopCount)
        XCTAssertEqual(Message.pathLenUnknown & 0x3F, 63,
                       "the sentinel still collides with a real count, so the "
                       + "early return in hopCount is load-bearing")
    }

    func testAbsentPathLenIsNil() {
        XCTAssertNil(message(pathLen: nil).hopCount)
    }

    // MARK: - Persistence

    func testRawByteSurvivesACodableRoundTrip() throws {
        // hopCount decodes on read precisely so that messages already on disk
        // are repaired. That only works while the raw byte is what is stored.
        let original = message(pathLen: 0x46)
        let decoded = try JSONDecoder().decode(
            Message.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.hops, 0x46, "stored value must stay raw")
        XCTAssertEqual(decoded.hopCount, 6, "and still decode on read")
    }
}
