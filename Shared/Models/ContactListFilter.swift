//
//  ContactListFilter.swift
//  PommeCore
//
//  Which kind of thing the main list is showing.
//
//  The list grew a section per type — contacts, repeaters, sensors, rooms,
//  channels, plus groups and pending — and the headers had drifted into three
//  different colours because nothing owned them. Showing one type at a time
//  removes the question rather than answering it: one header, one kind of row.
//
//  `all` is the default and keeps the grouped list exactly as it was, so
//  nothing is lost by shipping this and the filtered view can be judged
//  against the thing it replaces.
//
//  **A filter hides more than a collapsed section does.** The infrastructure
//  sections already pull their unread count out to the header, because a
//  collapsed section must never hide something that wants attention. Hiding a
//  whole type is stronger, and on an off-grid app a missed message is the
//  failure that matters — so every case here can report its own unread count,
//  and the picker shows the counts for the types it is hiding.
//
//  Created by Michael P. Bedworth on 10/17/26.
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import SwiftUI
import MeshCoreKit

enum ContactListFilter: String, CaseIterable, Identifiable {
    case all
    case contacts
    case repeaters
    case sensors
    case rooms
    case channels
    case groups

    var id: String { rawValue }

    /// The catalog key. Kept as a plain `String` so the two resolutions below
    /// cannot drift apart.
    private var titleKey: String {
        switch self {
        case .all:       "All"
        case .contacts:  "Contacts"
        case .repeaters: "Repeaters"
        case .sensors:   "Sensors"
        case .rooms:     "Rooms"
        case .channels:  "Channels"
        case .groups:    "Groups"
        }
    }

    var title: LocalizedStringKey { LocalizedStringKey(titleKey) }

    /// For the places that need a `String` rather than a `Text` — an
    /// accessibility phrase built with `String(format:)`.
    ///
    /// `String(localized:)` only accepts a *literal*, and the key here is
    /// chosen at runtime, so it has to go through the bundle. Same reason
    /// `HelpText` does it.
    var localizedTitle: String {
        Bundle.main.localizedString(forKey: titleKey, value: nil, table: nil)
    }

    var systemImage: String {
        switch self {
        case .all:       "square.stack.3d.up"
        case .contacts:  "person.fill"
        case .repeaters: "antenna.radiowaves.left.and.right"
        case .sensors:   "sensor"
        case .rooms:     "bubble.left.and.bubble.right"
        case .channels:  "number"
        case .groups:    "folder"
        }
    }

    /// The contact type this filter shows, or `nil` for the cases that are not
    /// a contact type at all.
    var contactType: ContactType? {
        switch self {
        case .contacts:  .chat
        case .repeaters: .repeater
        case .sensors:   .sensor
        case .rooms:     .room
        case .all, .channels, .groups: nil
        }
    }
}
