//
//  ContactBackup.swift
//  MeshCoreKit
//
//  A restorable snapshot of the contact list and the data keyed to it.
//
//  Written because a bulk delete was unrecoverable. Contacts live on the
//  radio, so deleting them there is final: there was no undo, no backup, and
//  the configuration export (.meshprofile) carries radio settings and channels
//  but not contacts. Roughly seventy contacts went in one confirmed tap, and
//  nothing in the app could bring them back — only waiting for each node to
//  advert again.
//
//  Created by Michael P. Bedworth on 10/03/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// A snapshot of the contact list plus the per-contact data the app keeps
/// alongside it, taken before a destructive operation.
///
/// Contacts can genuinely be restored to a radio: `CMD_ADD_UPDATE_CONTACT`
/// takes the same fields a `Contact` holds, so a snapshot is enough to put
/// them back — unlike `CMD_IMPORT_CONTACT`, which needs the signed advert
/// packet the app does not retain.
public struct ContactBackup: Codable, Sendable, Identifiable {

    /// Bumped when the shape changes. The decoder below tolerates older and
    /// newer files, so this is for diagnostics rather than gating.
    public static let currentVersion = 1

    public var id: Date { createdAt }

    public let version: Int
    public let createdAt: Date

    /// Why it was taken, for the restore list — "Before deleting 71 contacts".
    public let reason: String

    /// The radio this came from, so a backup is never offered to a different
    /// one. Contact keys are meaningful per mesh, and restoring one radio's
    /// contacts onto another would be silently wrong.
    public let radioPublicKeyHex: String

    public let contacts: [Contact]

    // Per-contact data, keyed by full public key hex — the same keys the
    // stores use. Included because restoring bare contacts would leave the
    // user renaming and re-grouping everything by hand.
    public let nicknames: [String: String]
    public let notes: [String: String]
    public let mutedContacts: [String]
    /// Group name to the member public keys it held.
    public let groupMembership: [String: [String]]

    public init(
        createdAt: Date = Date(),
        reason: String,
        radioPublicKeyHex: String,
        contacts: [Contact],
        nicknames: [String: String] = [:],
        notes: [String: String] = [:],
        mutedContacts: [String] = [],
        groupMembership: [String: [String]] = [:]
    ) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.reason = reason
        self.radioPublicKeyHex = radioPublicKeyHex
        self.contacts = contacts
        self.nicknames = nicknames
        self.notes = notes
        self.mutedContacts = mutedContacts
        self.groupMembership = groupMembership
    }

    /// Tolerant decoder, per critical rule 2.
    ///
    /// A backup is the last copy of data that cannot be re-derived, so a file
    /// written by a different build must never fail to load over a field this
    /// app does not recognise or has since added. Only `contacts` is required
    /// — without it there is nothing to restore.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contacts = try c.decode([Contact].self, forKey: .contacts)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        radioPublicKeyHex = (try? c.decode(String.self, forKey: .radioPublicKeyHex)) ?? ""
        nicknames = (try? c.decode([String: String].self, forKey: .nicknames)) ?? [:]
        notes = (try? c.decode([String: String].self, forKey: .notes)) ?? [:]
        mutedContacts = (try? c.decode([String].self, forKey: .mutedContacts)) ?? []
        groupMembership = (try? c.decode([String: [String]].self, forKey: .groupMembership)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case version, createdAt, reason, radioPublicKeyHex
        case contacts, nicknames, notes, mutedContacts, groupMembership
    }

    /// Whether this backup belongs to the given radio.
    ///
    /// An empty stored key means a file from before scoping existed; treat it
    /// as matching rather than hiding it, since an unrestorable backup is
    /// worse than one the user must judge.
    public func belongs(toRadio radioKeyHex: String) -> Bool {
        radioPublicKeyHex.isEmpty || radioPublicKeyHex == radioKeyHex
    }

    /// Frames that put these contacts back on the radio.
    ///
    /// Returned rather than sent so the caller controls pacing: adding
    /// seventy contacts in a burst risks the same dropped writes as deleting
    /// them did.
    public func restoreFrames() -> [(frame: Data, name: String)] {
        contacts.map { contact in
            (
                MeshCoreProtocol.buildAddUpdateContact(
                    publicKey: contact.publicKey,
                    type: contact.type.rawValue,
                    flags: contact.flags,
                    outPathLen: contact.outPathLen,
                    outPath: contact.outPath,
                    advName: contact.name,
                    lastAdvert: contact.lastAdvert,
                    latitude: Self.microDegrees(contact.latitude),
                    longitude: Self.microDegrees(contact.longitude)
                ),
                contact.name
            )
        }
    }

    /// Degrees to the protocol's micro-degree `Int32`, safely.
    ///
    /// A plain `Int32(degrees * 1_000_000)` traps on NaN, infinity, or any
    /// value beyond `Int32`. That is a crash on the one path whose whole
    /// purpose is recovering from a mistake, reachable from a corrupt or
    /// hand-edited backup file, so a nonsense coordinate becomes zero (the
    /// protocol's "no position") instead.
    static func microDegrees(_ degrees: Double) -> Int32 {
        guard degrees.isFinite else { return 0 }
        let scaled = (degrees * 1_000_000).rounded()
        guard scaled >= Double(Int32.min), scaled <= Double(Int32.max) else { return 0 }
        return Int32(scaled)
    }
}

/// Decides which backup files to keep.
public enum ContactBackupRetention {

    /// How many to keep. Each is a few kilobytes, and the useful one is almost
    /// always the most recent — but not always, since a user may notice the
    /// loss only after another delete, so a few generations are kept.
    public static let keepCount = 10

    /// The files to delete, given all of them, newest first.
    ///
    /// Pure so the policy is testable without touching the filesystem.
    public static func filesToPrune<T>(_ backups: [T], date: (T) -> Date) -> [T] {
        guard backups.count > keepCount else { return [] }
        return Array(backups.sorted { date($0) > date($1) }.dropFirst(keepCount))
    }
}
