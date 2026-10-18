//
//  ContactListView+ContactsUI.swift
//  PommeCore
//
//  Pending contacts, groups section, contacts section header/body
//  split from ContactListView.swift.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

// MARK: - Contacts UI

extension ContactListView {

    /// Contacts not assigned to any group — shown in the main Contacts section.
    /// Contacts shown in the main list: everything not filed in a user group
    /// and not infrastructure, which gets its own collapsed section per type.
    var ungroupedContacts: [Contact] {
        let grouped = Set(contactStore.contactGroups.flatMap(\.memberPubkeys))
        return contactStore.sortedContacts(byLastSeen: sortByLastSeen).filter {
            !grouped.contains($0.publicKey.hexCompact) && !Self.infrastructureTypes.contains($0.type)
        }
    }

    /// The types that get their own collapsed section. A user group still wins:
    /// a repeater the user filed somewhere deliberately stays where they put it.
    static let infrastructureTypes: Set<ContactType> = [.repeater, .sensor, .room]

    func infrastructureContacts(_ type: ContactType) -> [Contact] {
        let grouped = Set(contactStore.contactGroups.flatMap(\.memberPubkeys))
        return contactStore.sortedContacts(byLastSeen: sortByLastSeen).filter {
            $0.type == type && !grouped.contains($0.publicKey.hexCompact)
        }
    }

    @ViewBuilder
    var pendingContactsSection: some View {
        Section {
            ForEach(contactStore.pendingNewContacts) { contact in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(MeshTheme.statusWarn.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: contactIconName(for: contact.type))
                            .foregroundStyle(MeshTheme.statusWarn)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name)
                            .font(.body)
                            .foregroundStyle(MeshTheme.textPrimary)
                        Text("New contact discovered")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.statusWarn)
                    }
                    Spacer()
                    Button {
                        contactStore.acceptPendingContact(contact)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .accessibilityLabel("Accept contact")
                            .foregroundStyle(MeshTheme.connected)
                    }
                    .buttonStyle(.plain)
                    Button {
                        contactStore.rejectPendingContact(contact)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .accessibilityLabel("Reject contact")
                            .foregroundStyle(MeshTheme.disconnected)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            // Amber on purpose: here the colour *is* the signal that something
            // is waiting. It is the only header that asks for a tint.
            SectionHeader("Pending Contacts", tint: MeshTheme.statusWarn)
        }
    }

    @ViewBuilder
    var groupsSection: some View {
        Section {
            groupRows
        } header: {
            SectionHeader("Groups") {
                Spacer()
                groupsHeaderButton
            }
        }
    }

    /// The group rows on their own, so the unified section can show them.
    @ViewBuilder
    var groupRows: some View {
        Group {
            ForEach(contactStore.contactGroups) { group in
                DisclosureGroup {
                    let members = sortedGroupMembers(contactStore.contactsInGroup(group))
                    if members.isEmpty {
                        Text("No contacts in this group")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .listRowBackground(MeshTheme.surface)
                    } else {
                        ForEach(members) { contact in
                            #if os(watchOS)
                            NavigationLink {
                                contactDestination(contact)
                                                } label: {
                                contactRow(contact)
                            }
                            .listRowBackground(MeshTheme.surface)
                            #else
                            NavigationLink(value: SidebarSelection.contact(contact.publicKeyPrefix)) {
                                contactRow(contact)
                            }
                            .listRowBackground(MeshTheme.surface)
                            #endif
                        }
                    }
                } label: {
                    HStack {
                        if !group.emoji.isEmpty {
                            Text(group.emoji)
                        }
                        Text(group.name)
                            .foregroundStyle(MeshTheme.textPrimary)
                        if group.notifyMode == .muted {
                            Image(systemName: "bell.slash")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        } else if group.notifyMode == .priority {
                            Image(systemName: "bell.badge")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.statusWarn)
                        }
                        Spacer()
                        Text("\(group.memberPubkeys.count)")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .listRowBackground(MeshTheme.surface)
                .contextMenu {
                    Button {
                        renameGroupTarget = group
                        renameGroupName = group.name
                        renameGroupEmoji = group.emoji
                        showRenameGroupSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Menu {
                        ForEach(ContactStore.GroupNotifyMode.allCases, id: \.rawValue) { mode in
                            Button {
                                contactStore.setGroupNotifyMode(group, mode: mode)
                            } label: {
                                HStack {
                                    Text(mode.rawValue)
                                    if group.notifyMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Notifications", systemImage: group.notifyMode == .muted ? "bell.slash" : group.notifyMode == .priority ? "bell.badge" : "bell")
                    }

                    Menu {
                        ForEach(ContactStore.GroupSound.allCases, id: \.rawValue) { sound in
                            Button {
                                contactStore.setGroupSound(group, sound: sound)
                            } label: {
                                HStack {
                                    Text(sound.rawValue)
                                    if group.sound == sound {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sound", systemImage: "speaker.wave.2")
                    }

                    Divider()

                    Button {
                        contactStore.setGroupMembersMuted(group, muted: true)
                    } label: {
                        Label("Mute All Members", systemImage: "bell.slash")
                    }

                    Button {
                        contactStore.setGroupMembersMuted(group, muted: false)
                    } label: {
                        Label("Unmute All Members", systemImage: "bell")
                    }

                    Divider()

                    Button(role: .destructive) {
                        contactStore.deleteContactGroup(group)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        contactStore.deleteContactGroup(group)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// The groups section's own button.
    @ViewBuilder
    var groupsHeaderButton: some View {
        Group {
                Button {
                    groupContactForNew = nil
                    showNewGroupSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                        .accessibilityLabel("Add contact")
                        .foregroundStyle(MeshTheme.accent)
                }
                .buttonStyle(.plain)
            }
    }

    // MARK: - The list

    /// The whole list, as one section whose header names what it is showing.
    ///
    /// There used to be a section per type, and their headers had drifted into
    /// three different colours because nothing owned them. Showing one type at
    /// a time removes the question instead of answering it: one header, one
    /// kind of row. The buttons on the right are each type's own, in the place
    /// they already occupied — only the title changed, into the control that
    /// picks what is below it.
    @ViewBuilder
    var unifiedSection: some View {
        Section {
            switch listFilter {
            case .all:
                contactRows(contactStore.sortedContacts(byLastSeen: sortByLastSeen))
                channelRows
            case .contacts, .repeaters, .sensors, .rooms:
                contactRows(contacts(for: listFilter))
            case .channels:
                channelRows
            case .groups:
                groupRows
            }
        } header: {
            HStack {
                typeSelector
                Spacer()
                filterTrailingButtons
            }
        }
    }

    /// The section title, turned into the control that chooses it.
    ///
    /// Styled as a header rather than as a button: it sits where the title sat
    /// and reads as one, with the chevron the only thing saying it can be
    /// changed. Each entry carries its own unread count, and the control
    /// carries the total for every type it is hiding — a filter hides a whole
    /// type, which is stronger than collapsing a section, and the list must
    /// never be the reason a message goes unseen.
    var typeSelector: some View {
        Menu {
            ForEach(ContactListFilter.allCases) { filter in
                Button {
                    listFilter = filter
                } label: {
                    Label(filter.title, systemImage: filter.systemImage)
                    let unread = unreadCount(for: filter)
                    if unread > 0 {
                        Text("\(unread)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Label(listFilter.title, systemImage: listFilter.systemImage)
                    .foregroundStyle(MeshTheme.textSecondary)
                // iOS draws no indicator for a Menu used as a plain label, so
                // it needs one to read as a control. macOS draws its own and
                // ignores `.menuIndicator(.hidden)` under a plain button style,
                // so adding ours there gives the two chevrons side by side that
                // the Mac build shipped with. One each, from whichever source
                // the platform actually provides.
                #if !os(macOS) && !targetEnvironment(macCatalyst)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.accent)
                #endif
                if unreadElsewhere > 0 {
                    Text("\(unreadElsewhere)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(MeshTheme.textOnBubble)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MeshTheme.interactiveGreen))
                }
            }
            .contentShape(Rectangle())
        }
        // Without this macOS renders the menu as a bordered button and tints
        // its icon with the system accent instead of the theme's.
        .buttonStyle(.plain)
        .accessibilityLabel(unreadElsewhere > 0
            ? String(format: String(localized: "Showing %1$@, %2$d unread elsewhere"),
                     listFilter.localizedTitle, unreadElsewhere)
            : String(format: String(localized: "Showing %1$@"), listFilter.localizedTitle))
    }

    /// Each type keeps its own buttons, in the place they already occupied.
    @ViewBuilder
    var filterTrailingButtons: some View {
        switch listFilter {
        case .all, .contacts:
            contactsHeaderButtons
        case .channels:
            // The only filter that lists no contacts, so the only one with no
            // sort and no multi-select.
            channelsHeaderButtons
        case .groups:
            groupsHeaderButton
            sortButton
            editButton
        case .repeaters, .sensors, .rooms:
            let members = contacts(for: listFilter)
            let unread = members.reduce(0) { $0 + messageStoreManager.unreadCount(for: $1) }
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(MeshTheme.accent))
                    .foregroundStyle(MeshTheme.textOnFill)
            }
            Text("\(members.count)")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
            sortButton
            editButton
        }
    }

    /// The contacts a filter shows. `.all` is handled by the caller, which
    /// needs the channels too.
    func contacts(for filter: ContactListFilter) -> [Contact] {
        guard let type = filter.contactType else { return [] }
        return contactStore.sortedContacts(byLastSeen: sortByLastSeen)
            .filter { $0.type == type }
    }

    // MARK: - Type filter

    /// Unread waiting in a type that the current filter is hiding.
    func unreadCount(for filter: ContactListFilter) -> Int {
        switch filter {
        case .all:
            return ContactListFilter.allCases
                .filter { $0 != .all }
                .reduce(0) { $0 + unreadCount(for: $1) }
        case .channels:
            return channelStore.channels.reduce(0) {
                $0 + (messageStoreManager.unreadCounts[Data([$1.index])] ?? 0)
            }
        case .contacts:
            return ungroupedContacts.reduce(0) { $0 + messageStoreManager.unreadCount(for: $1) }
        case .groups:
            let members = Set(contactStore.contactGroups.flatMap(\.memberPubkeys))
            return contactStore.contacts
                .filter { members.contains($0.publicKeyPrefix.hexCompact) }
                .reduce(0) { $0 + messageStoreManager.unreadCount(for: $1) }
        case .repeaters, .sensors, .rooms:
            guard let type = filter.contactType else { return 0 }
            return infrastructureContacts(type).reduce(0) {
                $0 + messageStoreManager.unreadCount(for: $1)
            }
        }
    }

    /// Unread sitting in everything the current filter is *not* showing.
    var unreadElsewhere: Int {
        guard listFilter != .all else { return 0 }
        return ContactListFilter.allCases
            .filter { $0 != .all && $0 != listFilter }
            .reduce(0) { $0 + unreadCount(for: $1) }
    }

    var contactsSectionHeader: some View {
        SectionHeader("Contacts") {
            Spacer()
            contactsHeaderButtons
        }
    }

    /// The contacts section's own buttons: sort, and the add menu.
    @ViewBuilder
    var contactsHeaderButtons: some View {
        Group {
            sortButton
            addContactMenu
            editButton
        }
    }

    /// Sorting applies to any list of contacts, not just the Contacts filter.
    /// It was briefly reachable only from All and Contacts, which lost it for
    /// Repeaters, Sensors, Rooms and Groups — all of which are contact lists.
    var sortButton: some View {
        Button {
            sortByLastSeen.toggle()
        } label: {
            Image(systemName: sortByLastSeen ? "clock" : "textformat.abc")
                .foregroundStyle(MeshTheme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sortByLastSeen ? Text("Sort alphabetically") : Text("Sort by last seen"))
    }

    /// Multi-select is a contact operation, so it travels with the contacts.
    var editButton: some View {
        Button(String(localized: isSelecting ? "Done" : "Edit")) {
            isSelecting.toggle()
            if !isSelecting { selectedContacts.removeAll() }
        }
        .font(.caption)
        .foregroundStyle(MeshTheme.accent)
    }

    /// Adding is the part that is genuinely type-specific.
    var addContactMenu: some View {
        Menu {
            Button { showImportSheet = true } label: {
                Label("Paste Contact Link", systemImage: "doc.on.clipboard")
            }
            Button { connectionManager.sendAdvertise(type: 1) } label: {
                Label("Send Flood Advert", systemImage: "antenna.radiowaves.left.and.right")
            }
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(MeshTheme.accent)
        }
        .accessibilityLabel("Add contact")
        .menuIndicator(.hidden)
    }

    var contactsSection: some View {
        Section(isExpanded: $contactsExpanded) {
            contactRows(ungroupedContacts)
        } header: {
            contactsSectionHeader
        }
    }

    /// The rows for a set of contacts, with everything a contact row carries:
    /// selection mode, the context menu, the swipe actions and the selected-row
    /// highlight.
    ///
    /// Infrastructure contacts used to get a plainer row built separately —
    /// a bare `NavigationLink` with no context menu and no swipe actions. One
    /// builder means a repeater behaves like a contact, because it is one.
    @ViewBuilder
    func contactRows(_ contacts: [Contact]) -> some View {
        Group {
            if contacts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.title)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("No Contacts Yet")
                        .font(.headline)
                    Text("Send an advertisement to announce your presence on the mesh. Other nodes will appear here as they respond.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        connectionManager.sendAdvertise(type: 0)
                    } label: {
                        Label("Send Advertisement", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MeshTheme.interactiveGreen)
                    .foregroundStyle(MeshTheme.textOnBubble)
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
                .listRowBackground(MeshTheme.surface)
            } else {
                ForEach(contacts) { contact in
                    #if os(watchOS)
                    NavigationLink {
                        contactDestination(contact)
                                } label: {
                        contactRow(contact)
                    }
                    .listRowBackground(MeshTheme.surface)
                    #else
                    if isSelecting {
                        Button {
                            toggleSelection(contact)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedContacts.contains(contact.publicKeyPrefix) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedContacts.contains(contact.publicKeyPrefix) ? MeshTheme.accent : MeshTheme.textSecondary)
                                contactRow(contact)
                            }
                        }
                        .buttonStyle(.plain)
                        // The checkmark is the only thing that distinguishes a
                        // selected row, so the trait has to say so out loud.
                        .accessibilityAddTraits(
                            selectedContacts.contains(contact.publicKeyPrefix) ? .isSelected : []
                        )
                    } else {
                    NavigationLink(value: SidebarSelection.contact(contact.publicKeyPrefix)) {
                        contactRow(contact)
                    }
                    .contextMenu {
                        contactContextMenu(for: contact)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            contactToDelete = contact
                            // Defer alert so swipe dismissal animation completes first
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showDeleteConfirm = true
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            contactStore.toggleFavourite(for: contact)
                        } label: {
                            Label(
                                contact.isFavourite ? "Unfavourite" : "Favourite",
                                systemImage: contact.isFavourite ? "star.slash" : "star.fill"
                            )
                        }
                        .tint(MeshTheme.statusCaution)
                    }
                    .listRowBackground(
                        navigationStore.selectedContactKey == contact.publicKeyPrefix
                            && !navigationStore.showPublicChannel
                            ? MeshTheme.surfaceLight
                            : MeshTheme.surface
                    )
                    } // end else (not selecting)
                    #endif
                }
            }

            // Paste Link and Scan QR are in the contacts "+" header menu
            if isSelecting {
                HStack {
                    // Compared as sets, not counts. Equal counts do not mean
                    // equal membership — the list can change under a held
                    // selection when a contact is grouped on another device or
                    // a new one adverts in — and a count match would then show
                    // "Deselect All" over a selection that is not in fact
                    // everything, clearing the user's work instead of
                    // completing it. Union and subtract for the same reason:
                    // they only ever touch the keys this section owns.
                    let visibleKeys = Set(contacts.map(\.publicKeyPrefix))
                    let allVisibleSelected = !visibleKeys.isEmpty
                        && visibleKeys.isSubset(of: selectedContacts)
                    Button(allVisibleSelected ? "Deselect All" : "Select All") {
                        if allVisibleSelected {
                            selectedContacts.subtract(visibleKeys)
                        } else {
                            selectedContacts.formUnion(visibleKeys)
                        }
                    }
                    .font(.caption)
                    Spacer()
                    if !selectedContacts.isEmpty {
                        Button {
                            for key in selectedContacts {
                                if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == key }) {
                                    messageStoreManager.lastExportedURL = nil; connectionManager.exportContact(contact)
                                }
                            }
                        } label: {
                            Text("Export (\(selectedContacts.count))")
                                .font(.caption.weight(.medium))
                        }
                        Button(role: .destructive) {
                            showBulkDeleteConfirm = true
                        } label: {
                            Text("Delete (\(selectedContacts.count))")
                                .font(.caption.weight(.medium))
                        }
                    }
                }
                .listRowBackground(MeshTheme.surface)
            }
        }
        // Delete alerts live in deleteAlertsOverlay (deferred presentation avoids swipe/context menu conflicts).
        .alert("Import from Link", isPresented: $showImportSheet) {
            TextField("meshcore:// URL", text: $importURLText)
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                let url = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    if !channelStore.handleChannelURL(url), url.hasPrefix("meshcore://") {
                        connectionManager.importContact(url: url)
                        contactStore.requestContacts(fullSync: true)
                    }
                }
            }
        } message: {
            Text("Paste a meshcore:// link to import a contact or channel.")
        }
        #if os(iOS)
        .sheet(isPresented: $showQRScanner) {
            NavigationStack {
                QRScannerView { scannedURL in
                    showQRScanner = false
                    if !channelStore.handleChannelURL(scannedURL), scannedURL.hasPrefix("meshcore://") {
                        connectionManager.importContact(url: scannedURL)
                        contactStore.requestContacts(fullSync: true)
                    }
                }
                .navigationTitle("Scan QR Code")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showQRScanner = false }
                    }
                }
            }
            .meshTheme()
        }
        #endif
        .confirmationDialog(
            "Import Channel",
            isPresented: Bindable(channelStore).showChannelImportOptions,
            presenting: channelStore.pendingChannelImport
        ) { data in
            Button("Add Channel") {
                channelStore.importChannelAdd(data, maxChannels: deviceConfig.maxChannels)
                channelStore.pendingChannelImport = nil
            }
            Button("Replace All Channels", role: .destructive) {
                channelStore.importChannelReplaceAll(data)
                channelStore.pendingChannelImport = nil
            }
            Button("Cancel", role: .cancel) {
                channelStore.pendingChannelImport = nil
            }
        } message: { data in
            Text("Add \"\(data.name)\" to your channels, or replace all existing channels?")
        }
        .confirmationDialog(
            "Import \(channelStore.pendingMultiChannelImport?.channels.count ?? 0) Channels",
            isPresented: Bindable(channelStore).showMultiChannelImportOptions,
            presenting: channelStore.pendingMultiChannelImport
        ) { data in
            Button("Add to Existing Channels") {
                channelStore.importMultiChannelsAdd(data, maxChannels: deviceConfig.maxChannels)
                channelStore.pendingMultiChannelImport = nil
            }
            Button("Replace All Channels", role: .destructive) {
                channelStore.importMultiChannelsReplace(data, maxChannels: deviceConfig.maxChannels)
                channelStore.pendingMultiChannelImport = nil
            }
            Button("Cancel", role: .cancel) {
                channelStore.pendingMultiChannelImport = nil
            }
        } message: { data in
            Text("Import \(data.names)?\n\nAdd will keep your existing channels. Replace will remove all current channels first.")
        }
        .confirmationDialog("Send Advertisement", isPresented: $showAdvertOptions) {
            Button("Zero-Hop (nearby only)") {
                lastAdvertFlood = false
                connectionManager.sendAdvertise(type: 0)
                showAdvertSent?.wrappedValue = true
            }
            Button("Flood (entire mesh)") {
                lastAdvertFlood = true
                connectionManager.sendAdvertise(type: 1)
                showAdvertSent?.wrappedValue = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zero-hop reaches nearby nodes only. Flood is relayed by repeaters across the entire mesh network.")
        }
    }
}

// MARK: - Infrastructure Sections

extension ContactListView {

    /// Repeaters, sensors and room servers, each in their own section,
    /// collapsed by default.
    ///
    /// They are split out because they are what multiplies: a busy mesh turns
    /// a contact list into a list of repeaters with the people buried in it.
    /// Collapsed is the default for the same reason — but a collapsed section
    /// must never hide something that wants attention, so the header carries
    /// the unread count. That matters most for rooms, which are a conversation
    /// rather than plumbing and are only here because a per-type split was
    /// asked for.
    @ViewBuilder
    var infrastructureSections: some View {
        // Asking for a type is asking to see it, so a section the filter
        // selects is open whatever its remembered collapsed state says.
        if listFilter == .all || listFilter == .repeaters {
            infrastructureSection(.repeater, title: "Repeaters",
                                  systemImage: "antenna.radiowaves.left.and.right",
                                  isExpanded: expansion(for: .repeaters, remembered: $repeatersExpanded))
        }
        if listFilter == .all || listFilter == .sensors {
            infrastructureSection(.sensor, title: "Sensors",
                                  systemImage: "sensor",
                                  isExpanded: expansion(for: .sensors, remembered: $sensorsExpanded))
        }
        if listFilter == .all || listFilter == .rooms {
            infrastructureSection(.room, title: "Rooms",
                                  systemImage: "bubble.left.and.bubble.right",
                                  isExpanded: expansion(for: .rooms, remembered: $roomsExpanded))
        }
    }

    /// Collapsed state only has meaning in the grouped list. When the filter
    /// has picked this type, the section is the whole screen, so it is open —
    /// and writes still go to the remembered value, so nothing is forgotten.
    func expansion(for filter: ContactListFilter,
                   remembered: Binding<Bool>) -> Binding<Bool> {
        guard listFilter == filter else { return remembered }
        return Binding(get: { true }, set: { remembered.wrappedValue = $0 })
    }

    @ViewBuilder
    func infrastructureSection(_ type: ContactType,
                               title: LocalizedStringKey,
                               systemImage: String,
                               isExpanded: Binding<Bool>) -> some View {
        let members = infrastructureContacts(type)
        if !members.isEmpty {
            let unread = members.reduce(0) { $0 + messageStoreManager.unreadCount(for: $1) }
            Section(isExpanded: isExpanded) {
                ForEach(members) { contact in
                    #if os(watchOS)
                    NavigationLink {
                        contactDestination(contact)
                    } label: {
                        contactRow(contact)
                    }
                    .listRowBackground(MeshTheme.surface)
                    #else
                    NavigationLink(value: SidebarSelection.contact(contact.publicKeyPrefix)) {
                        contactRow(contact)
                    }
                    .listRowBackground(MeshTheme.surface)
                    #endif
                }
            } header: {
                SectionHeader(title, systemImage: systemImage) {
                    Spacer()
                    if unread > 0 {
                        // The whole point of collapsing is that you stop
                        // looking in here, so an unread message has to come out
                        // to the header or it is simply lost.
                        Text("\(unread)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(MeshTheme.accent))
                            .foregroundStyle(MeshTheme.textOnFill)
                    }
                    Text("\(members.count)")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
