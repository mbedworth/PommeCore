//
//  MessageTextTests.swift
//  MeshCoreKitTests
//
//  The composer counted Characters and the frame builders counted bytes. For
//  English those agree, so a 160-character Japanese message showed "160/160",
//  was accepted, and left the radio as 160 bytes — about a third of what was
//  typed, cut mid-character so the tail was not valid UTF-8.
//
//  These pin the two halves of the fix: truncation never splits a character,
//  and no builder can emit a frame whose text fails to decode.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class MessageTextTests: XCTestCase {

    /// 5 characters, 15 bytes — the shape that made this invisible in testing.
    private let hello = "こんにちは"

    func testASCIIIsUnchangedWhenItFits() {
        let s = String(repeating: "a", count: 160)
        XCTAssertEqual(s.truncated(toUTF8Bytes: 160), s)
        XCTAssertEqual(s.utf8ByteCount, 160)
    }

    func testCharactersAndBytesDisagreeForNonLatinText() {
        let s = String(repeating: hello, count: 32)   // 160 characters
        XCTAssertEqual(s.count, 160)
        XCTAssertEqual(s.utf8ByteCount, 480)          // what the radio sees
    }

    func testTruncationNeverSplitsACharacter() {
        // 160 is not a multiple of 3, so a byte-wise cut lands mid-character.
        let s = String(repeating: hello, count: 32)
        let cut = s.truncated(toUTF8Bytes: 160)
        XCTAssertLessThanOrEqual(cut.utf8ByteCount, 160)
        XCTAssertEqual(cut.utf8ByteCount, 159)        // 53 characters × 3 bytes
        XCTAssertEqual(cut, String(repeating: hello, count: 10) + "こんに")
        // The old `Data.prefix(160)` produced bytes that did not decode at all.
        XCTAssertNotNil(String(data: Data(cut.utf8), encoding: .utf8))
    }

    func testTruncationHandlesCombiningCharactersAndEmoji() {
        let flag = "🇯🇵"                               // one Character, 8 bytes
        let s = String(repeating: flag, count: 30)
        let cut = s.truncated(toUTF8Bytes: 20)
        XCTAssertEqual(cut, String(repeating: flag, count: 2))  // 16 bytes, not 20
        XCTAssertNotNil(String(data: Data(cut.utf8), encoding: .utf8))
    }

    func testEmptyAndShortStringsAreLeftAlone() {
        XCTAssertEqual("".truncated(toUTF8Bytes: 160), "")
        XCTAssertEqual("hi".truncated(toUTF8Bytes: 160), "hi")
        XCTAssertEqual(hello.truncated(toUTF8Bytes: 15), hello)
    }

    func testZeroLimitYieldsEmptyRatherThanLooping() {
        XCTAssertEqual(hello.truncated(toUTF8Bytes: 0), "")
    }

    // MARK: - The frames themselves

    /// Text begins after code(1) + txt_type(1) + attempt(1) + timestamp(4) + prefix(6).
    private func directMessageText(_ frame: Data) -> String? {
        String(data: frame.dropFirst(13), encoding: .utf8)
    }

    /// Text begins after code(1) + txt_type(1) + channel(1) + timestamp(4).
    private func channelMessageText(_ frame: Data) -> String? {
        String(data: frame.dropFirst(7), encoding: .utf8)
    }

    func testDirectMessageFrameAlwaysDecodes() {
        let frame = MeshCoreProtocol.buildSendTextMessage(
            text: String(repeating: hello, count: 32),
            recipientKeyHash: Data(repeating: 0xAB, count: 6))
        XCTAssertNotNil(directMessageText(frame),
                        "a frame cut mid-character carries text the recipient cannot decode")
        XCTAssertLessThanOrEqual(frame.count - 13, MessageText.maxBytes)
    }

    func testChannelMessageFrameAlwaysDecodes() {
        let frame = MeshCoreProtocol.buildSendChannelMessage(
            text: String(repeating: hello, count: 32), channelIndex: 0)
        XCTAssertNotNil(channelMessageText(frame))
        XCTAssertLessThanOrEqual(frame.count - 7, MessageText.maxBytes)
    }

    /// 165 is the radio-side channel limit; 166–167 pass the firmware's frame
    /// check and then fail permanently with ERR_CODE_TABLE_FULL. Staying at 160
    /// keeps that unreachable — see docs/FIRMWARE_COMPAT.md.
    func testLimitStaysBelowTheFirmwareTrap() {
        XCTAssertLessThan(MessageText.maxBytes, 166)
    }
}
