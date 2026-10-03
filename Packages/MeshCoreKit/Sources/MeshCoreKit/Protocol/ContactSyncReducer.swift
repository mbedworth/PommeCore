//
//  ContactSyncReducer.swift
//  MeshCoreKit
//
//  Decides what a finished contact sync means for the stored contact list.
//
//  This logic used to live inline in ContactStore, in the app target, where no
//  test could reach it — and it shipped a data-loss bug: a full sync that
//  delivered fewer contacts than it announced was accepted as the whole truth,
//  so the list collapsed and a downstream cleanup pass then deleted the
//  per-contact data of everything "missing". Pulled out here as a pure
//  function so the decision can be tested directly, without a radio, a store
//  or a view.
//
//  Created by Michael P. Bedworth on 10/02/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// Reduces a completed contact sync to a decision about the stored list.
public enum ContactSyncReducer {

    /// What the caller should do with the result of a sync.
    public enum Outcome: Equatable {
        /// A verified-complete full sync: this is the authoritative list.
        ///
        /// Only this outcome may be treated as authoritative by anything that
        /// deletes data keyed by contact.
        case replace([Contact])

        /// An incremental sync merged into the existing list.
        case merge([Contact])

        /// Nothing arrived in an incremental sync, so nothing changes.
        case noChange

        /// A full sync delivered fewer contacts than it announced. The
        /// existing list must be kept: the shortfall means the stream was
        /// truncated or interleaved with other traffic, not that the radio
        /// forgot those contacts.
        case rejectTruncated(received: Int, announced: Int)

        /// A full sync would have emptied a non-empty list without announcing
        /// a count, so completeness cannot be checked.
        ///
        /// Kept separate from `rejectTruncated` because the reasoning differs:
        /// here there is nothing to compare against. A stale list is a
        /// visible, self-correcting annoyance; a wrongly emptied one used to
        /// cascade into permanent loss of messages and notes. Given that
        /// asymmetry this refuses, and a genuinely cleared radio resolves on
        /// the next sync that announces zero.
        case rejectUnverifiable
    }

    /// Decide the outcome of a finished sync.
    ///
    /// - Parameters:
    ///   - existing: the currently stored contacts.
    ///   - incoming: contacts received during this sync.
    ///   - announced: the count from `RESP_CODE_CONTACTS_START`, or 0 if none
    ///     was seen.
    ///   - isIncremental: whether this sync asked only for changes since the
    ///     last one.
    public static func reduce(
        existing: [Contact],
        incoming: [Contact],
        announced: Int,
        isIncremental: Bool
    ) -> Outcome {
        if isIncremental {
            guard !incoming.isEmpty else { return .noChange }
            return .merge(merged(existing: existing, incoming: incoming))
        }

        // A full sync replaces the list wholesale, so it has to be known
        // complete before it is believed.
        if announced > 0 {
            guard incoming.count >= announced else {
                return .rejectTruncated(received: incoming.count, announced: announced)
            }
            return .replace(incoming)
        }

        // No announced count to check against.
        if incoming.isEmpty && !existing.isEmpty {
            return .rejectUnverifiable
        }
        return .replace(incoming)
    }

    /// Merge incoming contacts over the existing list, keyed by public key
    /// prefix, preserving the existing order and appending new arrivals.
    ///
    /// Dictionary-indexed so this stays O(n+m) rather than scanning the list
    /// for every incoming contact.
    private static func merged(existing: [Contact], incoming: [Contact]) -> [Contact] {
        var indexByPrefix: [Data: Int] = [:]
        indexByPrefix.reserveCapacity(existing.count)
        for (index, contact) in existing.enumerated() {
            indexByPrefix[contact.publicKeyPrefix] = index
        }

        var result = existing
        for contact in incoming {
            if let index = indexByPrefix[contact.publicKeyPrefix] {
                result[index] = contact
            } else {
                indexByPrefix[contact.publicKeyPrefix] = result.count
                result.append(contact)
            }
        }
        return result
    }
}
