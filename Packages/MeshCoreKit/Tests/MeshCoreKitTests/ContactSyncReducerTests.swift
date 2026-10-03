//
//  ContactSyncReducerTests.swift
//  MeshCoreKitTests
//
//  Regression tests for the contact-sync decision that shipped a data-loss
//  bug. A bulk delete requested a full sync before the firmware had finished
//  committing its removals, the responses interleaved, and the sync delivered
//  fewer contacts than it had announced. The shortfall was accepted as the
//  whole truth, so the list collapsed and a cleanup pass then permanently
//  deleted the messages, nicknames, notes, trails and telemetry of every
//  contact "missing" from it.
//
//  testTruncatedFullSyncIsRejected is that bug.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class ContactSyncReducerTests: XCTestCase {

    // MARK: - Fixtures

    /// A contact whose public key is distinct per `id`, so prefixes differ.
    private func contact(_ id: UInt8, name: String? = nil, lastAdvert: UInt32 = 1_700_000_000) -> Contact {
        var key = Data(repeating: id, count: 32)
        key[0] = id
        key[1] = id &+ 100
        return Contact(
            publicKey: key,
            name: name ?? "node-\(id)",
            type: .chat,
            lastAdvert: lastAdvert
        )
    }

    private func prefixes(_ contacts: [Contact]) -> [Data] {
        contacts.map(\.publicKeyPrefix)
    }

    // MARK: - The regression

    /// The data-loss bug: fewer contacts than announced must never be treated
    /// as the authoritative list.
    func testTruncatedFullSyncIsRejected() {
        let existing = (1...10).map { contact($0) }
        let incoming = (1...4).map { contact($0) }   // stream cut short

        let outcome = ContactSyncReducer.reduce(
            existing: existing, incoming: incoming, announced: 10, isIncremental: false
        )

        XCTAssertEqual(outcome, .rejectTruncated(received: 4, announced: 10))
    }

    /// The specific shape seen in the field: a bulk delete leaves a smaller
    /// real list, but the sync must still deliver all of what it announces.
    func testFullSyncMissingASingleContactIsRejected() {
        let existing = (1...73).map { contact($0) }
        let incoming = (1...72).map { contact($0) }

        XCTAssertEqual(
            ContactSyncReducer.reduce(existing: existing, incoming: incoming,
                                      announced: 73, isIncremental: false),
            .rejectTruncated(received: 72, announced: 73)
        )
    }

    // MARK: - Full sync, accepted

    func testCompleteFullSyncReplacesTheList() {
        let existing = (1...10).map { contact($0) }
        let incoming = (20...25).map { contact($0) }

        guard case .replace(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: incoming, announced: 6, isIncremental: false
        ) else {
            return XCTFail("a complete full sync must replace the list")
        }
        XCTAssertEqual(prefixes(result), prefixes(incoming))
    }

    /// A legitimate bulk delete: the radio announces the smaller count and
    /// delivers it, so the shrunk list is correct and must be accepted.
    func testFullSyncAfterADeletionAcceptsTheSmallerList() {
        let existing = (1...10).map { contact($0) }
        let incoming = (1...7).map { contact($0) }

        guard case .replace(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: incoming, announced: 7, isIncremental: false
        ) else {
            return XCTFail("a deletion the radio confirms must be accepted")
        }
        XCTAssertEqual(result.count, 7)
    }

    /// More than promised is odd but not dangerous — nothing is lost by
    /// believing it.
    func testFullSyncDeliveringMoreThanAnnouncedIsAccepted() {
        let incoming = (1...5).map { contact($0) }
        guard case .replace(let result) = ContactSyncReducer.reduce(
            existing: [], incoming: incoming, announced: 3, isIncremental: false
        ) else {
            return XCTFail("a surplus must not be rejected")
        }
        XCTAssertEqual(result.count, 5)
    }

    func testFullSyncAnnouncingZeroAndDeliveringZeroClearsAnEmptyList() {
        XCTAssertEqual(
            ContactSyncReducer.reduce(existing: [], incoming: [], announced: 0, isIncremental: false),
            .replace([])
        )
    }

    /// Without an announced count there is nothing to verify against, so
    /// emptying a populated list is refused: a stale list self-corrects, a
    /// wrongly emptied one used to cascade into permanent data loss.
    func testFullSyncWouldEmptyAPopulatedListWithoutAnAnnouncedCount() {
        let existing = (1...5).map { contact($0) }
        XCTAssertEqual(
            ContactSyncReducer.reduce(existing: existing, incoming: [], announced: 0, isIncremental: false),
            .rejectUnverifiable
        )
    }

    /// A radio that genuinely has no contacts announces zero, which is
    /// checkable, so the list does clear.
    func testRadioThatAnnouncesZeroIsNotTreatedAsTruncated() {
        let existing = (1...5).map { contact($0) }
        let outcome = ContactSyncReducer.reduce(
            existing: existing, incoming: [], announced: 0, isIncremental: false
        )
        XCTAssertNotEqual(outcome, .rejectTruncated(received: 0, announced: 0))
    }

    // MARK: - Incremental sync

    func testIncrementalSyncWithNothingIncomingChangesNothing() {
        let existing = (1...5).map { contact($0) }
        XCTAssertEqual(
            ContactSyncReducer.reduce(existing: existing, incoming: [], announced: 0, isIncremental: true),
            .noChange
        )
    }

    /// An incremental sync must never shrink the list, however few arrive —
    /// it only reports what changed.
    func testIncrementalSyncNeverShrinksTheList() {
        let existing = (1...20).map { contact($0) }
        let incoming = [contact(3)]

        guard case .merge(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: incoming, announced: 1, isIncremental: true
        ) else {
            return XCTFail("an incremental sync must merge")
        }
        XCTAssertEqual(result.count, 20, "a one-contact update must not drop the other 19")
    }

    func testIncrementalSyncUpdatesInPlaceAndPreservesOrder() {
        let existing = (1...4).map { contact($0) }
        let updated = contact(2, name: "renamed", lastAdvert: 1_800_000_000)

        guard case .merge(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: [updated], announced: 1, isIncremental: true
        ) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(prefixes(result), prefixes(existing), "order must be preserved")
        XCTAssertEqual(result[1].name, "renamed")
        XCTAssertEqual(result[1].lastAdvert, 1_800_000_000)
    }

    func testIncrementalSyncAppendsNewContactsAfterExistingOnes() {
        let existing = (1...3).map { contact($0) }
        let arrival = contact(9)

        guard case .merge(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: [arrival], announced: 1, isIncremental: true
        ) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.last?.publicKeyPrefix, arrival.publicKeyPrefix)
    }

    func testIncrementalMergeHandlesUpdatesAndArrivalsTogether() {
        let existing = (1...3).map { contact($0) }
        let incoming = [contact(2, name: "changed"), contact(7), contact(8)]

        guard case .merge(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: incoming, announced: 3, isIncremental: true
        ) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[1].name, "changed")
    }

    /// The same contact twice in one stream must not be appended twice.
    func testDuplicateIncomingContactIsNotDuplicated() {
        let existing = [contact(1)]
        let incoming = [contact(5), contact(5, name: "second")]

        guard case .merge(let result) = ContactSyncReducer.reduce(
            existing: existing, incoming: incoming, announced: 2, isIncremental: true
        ) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.name, "second", "the later copy wins")
    }

    func testMergeIntoAnEmptyListKeepsEveryArrival() {
        let incoming = (1...3).map { contact($0) }
        guard case .merge(let result) = ContactSyncReducer.reduce(
            existing: [], incoming: incoming, announced: 3, isIncremental: true
        ) else {
            return XCTFail("expected a merge")
        }
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - Authority

    /// Only a verified-complete full sync may be treated as authoritative by
    /// anything that deletes data keyed by contact. This encodes that rule so
    /// a future change cannot quietly widen it.
    func testOnlyReplaceIsAuthoritative() {
        let existing = (1...5).map { contact($0) }

        let nonAuthoritative: [ContactSyncReducer.Outcome] = [
            ContactSyncReducer.reduce(existing: existing, incoming: (1...2).map { contact($0) },
                                      announced: 5, isIncremental: false),
            ContactSyncReducer.reduce(existing: existing, incoming: [contact(1)],
                                      announced: 1, isIncremental: true),
            ContactSyncReducer.reduce(existing: existing, incoming: [],
                                      announced: 0, isIncremental: true),
            ContactSyncReducer.reduce(existing: existing, incoming: [],
                                      announced: 0, isIncremental: false)
        ]

        for outcome in nonAuthoritative {
            if case .replace = outcome {
                XCTFail("\(outcome) must not be authoritative")
            }
        }
    }
}
