//
//  BinaryFramingTests.swift
//  MeshCoreKitTests
//
//  The USB and WiFi transports previously each carried their own copy of this
//  scanning loop, and neither was tested. These cover the cases that matter
//  for a byte stream from a radio: split frames, noise, and corrupt lengths.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class BinaryFramingTests: XCTestCase {

    private func framed(_ payload: [UInt8]) -> Data {
        var d = Data([BinaryFraming.startMarker])
        let len = UInt16(payload.count).littleEndian
        withUnsafeBytes(of: len) { d.append(contentsOf: $0) }
        d.append(contentsOf: payload)
        return d
    }

    func testExtractsASingleFrame() {
        var buffer = framed([0x01, 0x02, 0x03])
        let frames = BinaryFraming.extractFrames(from: &buffer)
        XCTAssertEqual(frames, [Data([0x01, 0x02, 0x03])])
        XCTAssertTrue(buffer.isEmpty, "a consumed frame must leave nothing behind")
    }

    func testExtractsBackToBackFrames() {
        var buffer = framed([0xAA]) + framed([0xBB, 0xCC]) + framed([0xDD])
        let frames = BinaryFraming.extractFrames(from: &buffer)
        XCTAssertEqual(frames, [Data([0xAA]), Data([0xBB, 0xCC]), Data([0xDD])])
        XCTAssertTrue(buffer.isEmpty)
    }

    /// A stream read can split a frame anywhere; the remainder must be kept.
    func testPartialFrameIsRetainedUntilComplete() {
        let whole = framed([0x10, 0x20, 0x30, 0x40])
        var buffer = whole.prefix(5)  // header + 2 of 4 payload bytes

        XCTAssertTrue(BinaryFraming.extractFrames(from: &buffer).isEmpty)
        XCTAssertEqual(buffer.count, 5, "the partial frame must be kept, not dropped")

        buffer.append(contentsOf: whole.suffix(2))
        XCTAssertEqual(BinaryFraming.extractFrames(from: &buffer), [Data([0x10, 0x20, 0x30, 0x40])])
    }

    func testHeaderSplitAcrossReadsIsRetained() {
        var buffer = Data([BinaryFraming.startMarker, 0x02])  // marker + half the length
        XCTAssertTrue(BinaryFraming.extractFrames(from: &buffer).isEmpty)
        XCTAssertEqual(buffer.count, 2)

        buffer.append(contentsOf: [0x00, 0xEE, 0xFF])
        XCTAssertEqual(BinaryFraming.extractFrames(from: &buffer), [Data([0xEE, 0xFF])])
    }

    func testLeadingNoiseIsSkipped() {
        var buffer = Data([0x00, 0xFF, 0x7E]) + framed([0x42])
        XCTAssertEqual(BinaryFraming.extractFrames(from: &buffer), [Data([0x42])])
    }

    func testBufferWithNoMarkerIsDiscarded() {
        var buffer = Data(repeating: 0x5A, count: 64)
        XCTAssertTrue(BinaryFraming.extractFrames(from: &buffer).isEmpty)
        XCTAssertTrue(buffer.isEmpty, "unusable bytes must not accumulate")
    }

    /// The regression this extraction was for: a corrupt length claiming more
    /// than any real frame must not make the scanner wait for — and then
    /// discard — tens of kilobytes of genuine frames queued behind it.
    func testCorruptLengthDoesNotSwallowFollowingFrames() {
        var buffer = Data([BinaryFraming.startMarker, 0xFF, 0xFF])  // claims 65535
        buffer.append(framed([0x99]))

        let frames = BinaryFraming.extractFrames(from: &buffer)
        XCTAssertEqual(frames, [Data([0x99])], "the real frame behind the bogus header must survive")
    }

    func testLengthAtTheCapIsStillAccepted() {
        let payload = [UInt8](repeating: 0x11, count: BinaryFraming.maxPayloadLength)
        var buffer = framed(payload)
        let frames = BinaryFraming.extractFrames(from: &buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.count, BinaryFraming.maxPayloadLength)
    }

    func testZeroLengthFrameIsConsumedNotStalled() {
        var buffer = framed([]) + framed([0x07])
        XCTAssertEqual(BinaryFraming.extractFrames(from: &buffer), [Data(), Data([0x07])])
        XCTAssertTrue(buffer.isEmpty, "a zero-length frame must not loop forever")
    }

    /// Data keeps absolute indices after removeFirst, so a buffer that has
    /// already been consumed from must still scan correctly.
    func testWorksOnABufferWithANonZeroStartIndex() {
        var buffer = framed([0x01]) + framed([0x02])
        _ = BinaryFraming.extractFrames(from: &buffer)   // advances startIndex
        buffer.append(framed([0x03]))
        XCTAssertEqual(BinaryFraming.extractFrames(from: &buffer), [Data([0x03])])
    }

    func testPayloadContainingTheMarkerByteIsNotMisparsed() {
        var buffer = framed([BinaryFraming.startMarker, BinaryFraming.startMarker]) + framed([0x55])
        XCTAssertEqual(
            BinaryFraming.extractFrames(from: &buffer),
            [Data([BinaryFraming.startMarker, BinaryFraming.startMarker]), Data([0x55])]
        )
    }
}
