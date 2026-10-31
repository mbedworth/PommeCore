//
//  MessageStatusPhraseTests.swift
//  PommeCoreTests
//
//  Critical Rule 6: a status is a claim about reality.
//
//  The claim is made twice — once as an icon, once as the words VoiceOver
//  speaks — and until 2026-10-30 there were three separate switches making it.
//  One of them ended in `default:` and drew a plain checkmark for every case it
//  had not enumerated, `.failed` among them. So a channel message sent with
//  Bluetooth off was marked failed in the model, exactly as the rule requires,
//  and then displayed a confident tick. The rule was honoured in the data and
//  broken in the view, which is the only place the user can see it.
//
//  These tests pin the words. The icon is pinned by `check_status_switch_exhaustive`
//  in `scripts/check_rules.py`, because a SwiftUI view's rendered symbol is not
//  reachable from a unit test without a view-inspection dependency, and the
//  exhaustive switch is what makes the two unable to disagree.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
import MeshCoreKit
@testable import PommeCore

final class MessageStatusPhraseTests: XCTestCase {

    private func message(_ status: DeliveryStatus,
                         roundTripMs: UInt32? = nil,
                         attempt: UInt8 = 0) -> Message {
        Message(
            text: "test",
            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
            isOutgoing: true,
            status: status,
            roundTripMs: roundTripMs,
            attempt: attempt
        )
    }

    // MARK: - Every case is covered

    /// The test that fails when a status is added and forgotten.
    ///
    /// `DeliveryStatus` is `CaseIterable` for this: the loop grows by itself.
    func testEveryStatusProducesANonEmptyPhrase() {
        for status in DeliveryStatus.allCases {
            let phrase = messageStatusPhrase(message(status))
            XCTAssertFalse(phrase.isEmpty,
                           "\(status) has no phrase — VoiceOver would announce nothing")
        }
    }

    /// Two statuses that read the same are indistinguishable to anyone using
    /// VoiceOver, which is the audible form of the checkmark bug.
    ///
    /// Deliberately language-independent: it compares the phrases to each other
    /// rather than to English literals, so it holds in all twelve languages.
    func testEveryStatusReadsDifferently() {
        var seen: [String: DeliveryStatus] = [:]
        for status in DeliveryStatus.allCases {
            let phrase = messageStatusPhrase(message(status))
            if let clash = seen[phrase] {
                XCTFail("\(status) and \(clash) both read as \"\(phrase)\"")
            }
            seen[phrase] = status
        }
    }

    // MARK: - The specific claims the protocol cannot support

    /// The bug, stated directly. `.failed` must not borrow the vocabulary of
    /// success in any form.
    func testFailedNeverClaimsSuccess() {
        let failed = messageStatusPhrase(message(.failed))
        XCTAssertNotEqual(failed, messageStatusPhrase(message(.sent)))
        XCTAssertNotEqual(failed, messageStatusPhrase(message(.delivered)))
        XCTAssertNotEqual(failed, messageStatusPhrase(message(.repeated)))
        XCTAssertEqual(failed, "Not delivered")
    }

    /// `.repeated` is a weaker claim than `.sent` — a repeater echoed it — and
    /// must stay its own wording. It also must never be overwritten by a later
    /// `.sent`, which is a store concern, not this one.
    func testRepeatedIsDistinctFromSent() {
        XCTAssertEqual(messageStatusPhrase(message(.sent)), "Sent")
        XCTAssertEqual(messageStatusPhrase(message(.repeated)), "Sent, repeated by mesh")
    }

    /// A round trip is only quoted when the radio actually reported one. Zero
    /// is the firmware's "no measurement", not a 0.0-second delivery.
    func testDeliveredQuotesRoundTripOnlyWhenMeasured() {
        XCTAssertEqual(messageStatusPhrase(message(.delivered)), "Delivered")
        XCTAssertEqual(messageStatusPhrase(message(.delivered, roundTripMs: 0)), "Delivered",
                       "A round trip of 0 ms is 'not measured', not an instant delivery")

        let measured = messageStatusPhrase(message(.delivered, roundTripMs: 1_500))
        XCTAssertTrue(measured.contains("1.5"), "Expected the measured round trip, got \"\(measured)\"")
    }

    /// Attempts are shown one-based: the first retry is "attempt 1 of 3", not 0.
    func testRetryingCountsFromOne() {
        XCTAssertEqual(messageStatusPhrase(message(.retrying, attempt: 0)),
                       "Retrying, attempt 1 of 3")
        XCTAssertEqual(messageStatusPhrase(message(.retrying, attempt: 2)),
                       "Retrying, attempt 3 of 3")
    }

    // MARK: - Nothing here is drawn, so nothing may carry display markup

    /// `String(localized:)` hands back automatic-grammar markup verbatim —
    /// only `Text` resolves it. A phrase is spoken by VoiceOver, so markup here
    /// would be read out as punctuation.
    ///
    /// This is the same defect that put `^[3 hop](inflect: true)` on the air in
    /// a Quick Reply; see `QuickReplyTests`.
    func testNoPhraseCarriesInflectionMarkup() {
        for status in DeliveryStatus.allCases {
            let phrase = messageStatusPhrase(message(status, roundTripMs: 1_500, attempt: 1))
            XCTAssertFalse(phrase.contains("^["),
                           "\(status) phrase carries grammar markup: \"\(phrase)\"")
            XCTAssertFalse(phrase.contains("(inflect:"),
                           "\(status) phrase carries grammar markup: \"\(phrase)\"")
        }
    }
}
