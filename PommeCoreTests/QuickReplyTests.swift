//
//  QuickReplyTests.swift
//  PommeCoreTests
//
//  The acknowledgement that goes out over the air after a radio check, and the
//  defect that put SwiftUI markup on the mesh.
//
//  `Text` resolves `^[…](inflect: true)` when it draws. `String(localized:)`
//  does not — it hands the markup back verbatim. A Quick Reply is not drawn, it
//  is *transmitted*, so a real message arrived on another operator's client
//  reading `Copy, @[Z-max]! ^[3 hop](inflect: true) @ 21:44`. Seen on hardware
//  2026-10-30.
//
//  Rule 18 pushes everything towards `LocalizedStringKey`, and that is right for
//  anything drawn. This file exists because there is a second category — strings
//  that leave the device — where the same habit is the bug, and nothing else in
//  the toolchain can tell the two apart.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
import MeshCoreKit
@testable import PommeCore

final class QuickReplyTests: XCTestCase {

    private func received(hops: UInt8? = 3, snr: Int8? = 24) -> Message {
        Message(
            text: "radio check",
            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
            isOutgoing: false,
            status: .sending,
            snr: snr,
            hops: hops,
            channelIndex: 0,
            senderName: "Z-max"
        )
    }

    private func everyPartOn(location: String = "Ft Pierce, FL") -> QuickReply.Options {
        QuickReply.Options(location: location,
                           includeHops: true,
                           includeLocation: true,
                           includeTime: true,
                           includeSNR: true)
    }

    // MARK: - Nothing transmitted may carry display markup

    /// The bug, stated directly.
    func testReplyNeverCarriesInflectionMarkup() {
        let line = QuickReply.text(replyingTo: received(),
                                   address: "@[Z-max]",
                                   options: everyPartOn())

        XCTAssertFalse(line.contains("^["), "Grammar markup went on the air: \(line)")
        XCTAssertFalse(line.contains("(inflect:"), "Grammar markup went on the air: \(line)")
    }

    /// Across every hop count that changes the wording, including the singular
    /// that the markup was introduced to handle in the first place.
    func testNoHopCountProducesMarkup() {
        for hops in UInt8(0)...8 {
            let line = QuickReply.text(replyingTo: received(hops: hops),
                                       address: "Z-max",
                                       options: everyPartOn())
            XCTAssertFalse(line.contains("^["), "\(hops) hops produced markup: \(line)")
            XCTAssertFalse(line.contains("(inflect:"), "\(hops) hops produced markup: \(line)")
        }
    }

    // MARK: - Hop wording

    func testHopWording() {
        func hopPart(_ hops: UInt8?) -> String {
            QuickReply.text(replyingTo: received(hops: hops),
                            address: "Z-max",
                            options: QuickReply.Options(location: "",
                                                        includeHops: true,
                                                        includeLocation: false,
                                                        includeTime: false,
                                                        includeSNR: false))
        }

        XCTAssertEqual(hopPart(0), "Copy, Z-max! direct",
                       "Zero hops is a direct contact, not '0 hops'")
        XCTAssertEqual(hopPart(1), "Copy, Z-max! 1 hop")
        XCTAssertEqual(hopPart(3), "Copy, Z-max! 3 hops")
    }

    /// A message that arrived by flood has no hop count. The part is simply
    /// never added — there is no leftover punctuation to clean up, which is the
    /// reason the line is assembled rather than substituted into a template.
    func testAbsentHopCountIsOmittedEntirely() {
        let line = QuickReply.text(replyingTo: received(hops: nil),
                                   address: "Z-max",
                                   options: QuickReply.Options(location: "",
                                                               includeHops: true,
                                                               includeLocation: false,
                                                               includeTime: false,
                                                               includeSNR: false))

        XCTAssertEqual(line, "Copy, Z-max!")
    }

    // MARK: - Addressing

    /// On a channel, the bracketed mention form — channel names contain spaces
    /// and emoji, so a bare `@name` cannot say where the name stops.
    func testChannelAddressingUsesTheBracketedMention() {
        XCTAssertEqual(
            QuickReply.address(senderName: "W4KWS 📡 GAT30S", displayName: "ignored", isChannel: true),
            "@[W4KWS 📡 GAT30S]"
        )
    }

    /// In a direct message there is only one person it could be for, so the
    /// plain display name reads better and costs fewer bytes.
    func testDirectAddressingUsesTheDisplayName() {
        XCTAssertEqual(
            QuickReply.address(senderName: "Z-max", displayName: "Max at the lake", isChannel: false),
            "Max at the lake"
        )
    }

    /// A channel message with no sender name falls back rather than emitting
    /// `@[]`, which addresses nobody.
    func testChannelAddressingFallsBackWithoutASenderName() {
        XCTAssertEqual(
            QuickReply.address(senderName: nil, displayName: "Unknown", isChannel: true),
            "Unknown"
        )
        XCTAssertEqual(
            QuickReply.address(senderName: "", displayName: "Unknown", isChannel: true),
            "Unknown"
        )
    }

    // MARK: - The 160-byte ceiling

    func testEveryPartOnStillFits() {
        let line = QuickReply.text(replyingTo: received(),
                                   address: "@[Z-max]",
                                   options: everyPartOn())

        XCTAssertLessThanOrEqual(line.utf8ByteCount, MessageText.maxBytes)
    }

    /// Parts are dropped from the end, not cut mid-word: a hop count is worth
    /// more to the sender than a timestamp they can already see on their own
    /// screen.
    func testPartsAreDroppedFromTheEndRatherThanTruncated() {
        let longLocation = String(repeating: "Lauderdale ", count: 20)
        let line = QuickReply.text(replyingTo: received(),
                                   address: "@[Z-max]",
                                   options: everyPartOn(location: longLocation))

        XCTAssertLessThanOrEqual(line.utf8ByteCount, MessageText.maxBytes)
        XCTAssertTrue(line.hasPrefix("Copy, @[Z-max]!"),
                      "The greeting is never dropped — an acknowledgement must say who it is for")
        XCTAssertTrue(line.contains("3 hops"),
                      "Hop count outranks the later parts and should survive")
    }

    /// Non-ASCII at the boundary. The clamp works on UTF-8 boundaries, so the
    /// result must still be valid text — this is the `MessageText` lesson: the
    /// composer counted Characters and the frame builders counted bytes.
    func testNonASCIILocationIsNeverCutMidCharacter() {
        let line = QuickReply.text(replyingTo: received(),
                                   address: "@[Z-max]",
                                   options: everyPartOn(location: String(repeating: "日本橋", count: 40)))

        XCTAssertLessThanOrEqual(line.utf8ByteCount, MessageText.maxBytes)
        XCTAssertEqual(String(decoding: Array(line.utf8), as: UTF8.self), line,
                       "The reply is not valid UTF-8 — a character was split")
    }

    /// A name long enough to blow the budget on its own falls through to the
    /// clamp, because the greeting is the one part that is never dropped.
    func testAnAbsurdlyLongAddressStillProducesASendableLine() {
        let line = QuickReply.text(replyingTo: received(),
                                   address: String(repeating: "A", count: 400),
                                   options: everyPartOn())

        XCTAssertLessThanOrEqual(line.utf8ByteCount, MessageText.maxBytes)
        XCTAssertFalse(line.isEmpty)
    }

    // MARK: - The parts are opt-in

    func testEachPartCanBeTurnedOff() {
        let line = QuickReply.text(replyingTo: received(),
                                   address: "Z-max",
                                   options: QuickReply.Options(location: "Ft Pierce, FL",
                                                               includeHops: false,
                                                               includeLocation: false,
                                                               includeTime: false,
                                                               includeSNR: false))

        XCTAssertEqual(line, "Copy, Z-max!")
    }

    /// SNR is reported in quarter-dB by the firmware. 24 is 6.0 dB, not 24.
    func testSNRIsConvertedFromQuarterDB() {
        let line = QuickReply.text(replyingTo: received(snr: 24),
                                   address: "Z-max",
                                   options: QuickReply.Options(location: "",
                                                               includeHops: false,
                                                               includeLocation: false,
                                                               includeTime: false,
                                                               includeSNR: true))

        XCTAssertEqual(line, "Copy, Z-max! 6.0 dB")
    }

    /// Nothing here sends anything, and nothing reads the clock: the timestamp
    /// quoted is the one the message arrived with, because the point of the
    /// acknowledgement is to tell the sender how *their* transmission arrived.
    func testTimeComesFromTheMessageNotTheClock() {
        let message = received()
        let options = QuickReply.Options(location: "",
                                         includeHops: false,
                                         includeLocation: false,
                                         includeTime: true,
                                         includeSNR: false)

        let first = QuickReply.text(replyingTo: message, address: "Z-max", options: options)
        let second = QuickReply.text(replyingTo: message, address: "Z-max", options: options)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains(formatMeshTime(message.timestamp)))
    }
}
