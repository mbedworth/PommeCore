//
//  SetChannelFrameTests.swift
//  MeshCoreKitTests
//
//  CMD_SET_CHANNEL carries a 32-byte null-padded name and a 16-byte PSK —
//  critical rule 8, and the usual mistake is assuming the key is 32 bytes
//  because the name field is. These tests pin the field widths and the
//  clamping that keeps an over-long name or key from corrupting the frame,
//  since channel data can arrive from an untrusted link or a scanned QR code.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class SetChannelFrameTests: XCTestCase {

    /// code(1) + index(1) + name(32) + secret(16)
    private let expectedFrameLength = 50

    func testFieldWidthsMatchTheProtocol() {
        XCTAssertEqual(MeshCoreProtocol.channelSecretLength, 16, "rule 8: the PSK is 16 bytes, not 32")
        XCTAssertEqual(MeshCoreProtocol.channelNameMaxBytes, 31, "32-byte field less the null terminator")

        let frame = MeshCoreProtocol.buildSetChannel(index: 1, name: "Public", secret: Data(repeating: 0xAB, count: 16))
        XCTAssertEqual(frame.count, expectedFrameLength)
        XCTAssertEqual(frame[1], 1, "index must follow the command byte")
    }

    func testNameIsNullPaddedAndNotTruncatedWhenItFits() {
        let frame = MeshCoreProtocol.buildSetChannel(index: 2, name: "Ops", secret: nil)
        let nameField = frame[2..<34]
        XCTAssertEqual(String(decoding: nameField), "Ops")
        XCTAssertTrue(nameField.dropFirst(3).allSatisfy { $0 == 0 }, "remainder must be null padding")
    }

    func testOverLongNameIsClampedAndStillLeavesATerminator() {
        let frame = MeshCoreProtocol.buildSetChannel(index: 1, name: String(repeating: "A", count: 200), secret: nil)
        XCTAssertEqual(frame.count, expectedFrameLength, "an over-long name must not grow the frame")
        let nameField = frame[2..<34]
        XCTAssertEqual(nameField.prefix(31).count, 31)
        XCTAssertEqual(nameField.last, 0, "the 32nd byte must stay a null terminator")
    }

    func testOverLongSecretIsClampedToSixteenBytes() {
        let frame = MeshCoreProtocol.buildSetChannel(index: 1, name: "X", secret: Data(repeating: 0xFF, count: 64))
        XCTAssertEqual(frame.count, expectedFrameLength, "an over-long key must not grow the frame")
        XCTAssertTrue(frame[34..<50].allSatisfy { $0 == 0xFF })
    }

    /// A short key is zero-padded rather than rejected at this layer, which is
    /// why callers must validate length before building the frame — a padded
    /// key is a different key, and the channel silently fails to decrypt.
    func testShortSecretIsZeroPaddedNotRejected() {
        let frame = MeshCoreProtocol.buildSetChannel(index: 1, name: "X", secret: Data([0x01, 0x02]))
        XCTAssertEqual(Array(frame[34..<36]), [0x01, 0x02])
        XCTAssertTrue(frame[36..<50].allSatisfy { $0 == 0 }, "the rest is padding, so this is not the shared key")
    }

    func testNoSecretYieldsAnAllZeroKeyField() {
        let frame = MeshCoreProtocol.buildSetChannel(index: 3, name: "Open", secret: nil)
        XCTAssertTrue(frame[34..<50].allSatisfy { $0 == 0 })
    }

    /// Multi-byte names must be clamped on a byte boundary, not a character
    /// count, or the frame overruns its field.
    func testMultiByteNameIsClampedByBytes() {
        let frame = MeshCoreProtocol.buildSetChannel(index: 1, name: String(repeating: "🦊", count: 20), secret: nil)
        XCTAssertEqual(frame.count, expectedFrameLength)
    }
}

private extension String {
    init(decoding bytes: Data.SubSequence) {
        self = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
