//
//  ContactListView.swift
//  MeshCoreApple
//
//  Sidebar contact/channel list, connection status, context menus, and edit mode.
//
//  Created by Michael P. Bedworth on 3/13/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

struct ContactListView: View {
    @Environment(ContactStore.self) private var contactStore
    @Environment(ChannelStore.self) private var channelStore
    @Environment(MessageStoreManager.self) private var messageStoreManager
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(NavigationStore.self) private var navigationStore
    @Binding var showScanner: Bool
    var showDiscover: Binding<Bool>? = nil
    var showSettings: Binding<Bool>? = nil
    var showRemoteManagement: Binding<Bool>? = nil
    var showAdvertSent: Binding<Bool>? = nil

    @State private var showAdvertOptions = false
    @State private var lastAdvertFlood = false
    @State private var contactToDelete: Contact?
    @State private var showDeleteConfirm = false
    @State private var showImportSheet = false
    @State private var importURLText = ""
    @State private var showShareConfirmation = false
    @State private var showResetConfirmation = false
    @State private var detailContact: Contact?
    @State private var channelSheetAction: ChannelAction?
    // showDeviceInfo removed — connection bar now navigates to Settings
    #if !os(watchOS)
    @State private var channelToShareSidebar: MeshChannel?
    @State private var channelToRenameSidebar: MeshChannel?
    @State private var channelRenameText = ""
    @State private var showChannelRemoveConfirm = false
    @State private var channelToRemove: MeshChannel?
    @State private var showShareAllChannels = false
    #endif
    @State private var showNicknameSheet = false
    #if os(iOS)
    @State private var showQRScanner = false
    #endif
    #if !os(watchOS)
    @State private var showMyContactCode = false
    #endif
    @State private var nicknameContact: Contact?
    @State private var nicknameText = ""
    @State private var isSelecting = false
    @State private var selectedContacts: Set<Data> = [] // publicKeyPrefix
    @State private var showBulkDeleteConfirm = false
    @State private var pathEditorContact: Contact?
    @State private var showExportCopied = false
    @State private var isExporting = false
    #if !os(watchOS)
    @State private var shareContact: Contact?
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// Local selection state decoupled from ViewModel to avoid
    /// "Publishing changes from within view updates" when List writes to selection.
    @State private var localSelection: SidebarSelection? = nil

    /// Public Channel virtual contact key (channel 0).
    private let publicChannelKey = Data([0x00 as UInt8])

    #if os(macOS) || targetEnvironment(macCatalyst)
    private var isUSBCLIConnected: Bool {
        connectionManager.isUSBCLIMode && remoteSessionManager.isUSBCLIConnected
    }
    #endif

    var body: some View {
        mainList
        .navigationTitle("MeshCore")
        // navigationDestination is only needed on iOS (not macOS/Catalyst) because on
        // macOS the NavigationSplitView's detail: block drives the detail column exclusively.
        // Leaving navigationDestination active on macOS creates a conflicting navigation
        // stack: once the map NavigationLink pushes via navigationDestination, setting
        // sidebarSelection = .settings has no visible effect (the pushed map view wins).
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .navigationDestination(for: SidebarSelection.self) { selection in
            sidebarDestinationView(for: selection)
        }
        #endif
        // Sync local selection → ViewModel (deferred to avoid publishing during view update)
        .onChange(of: localSelection) { _, newValue in
            guard newValue != navigationStore.sidebarSelection else { return }
            DispatchQueue.main.async {
                navigationStore.sidebarSelection = newValue
            }
        }
        // Sync ViewModel → local selection (for programmatic navigation from other code)
        .onChange(of: navigationStore.sidebarSelection) { _, newValue in
            if localSelection != newValue {
                localSelection = newValue
            }
        }
        #if !os(watchOS)
        .onChange(of: navigationStore.sidebarSelection) { _, selection in
            // Mark contact as read when selected — deferred past view update
            if case .contact(let key) = selection,
               let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == key }) {
                DispatchQueue.main.async {
                    Task { @MainActor in
                        messageStoreManager.markAsRead(contact)
                    }
                }
            }
        }
        #endif
        #if os(watchOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Scan for devices")
            }
        }
        #elseif os(macOS) || targetEnvironment(macCatalyst)
        // macOS toolbar items are added at the NavigationSplitView level in MeshCoreApp.swift
        // to avoid being constrained to the narrow sidebar column.
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        connectionManager.sendAdvertise(type: 1)
                        showAdvertSent?.wrappedValue = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showAdvertSent?.wrappedValue = false
                        }
                    } label: {
                        Image(systemName: showAdvertSent?.wrappedValue == true
                              ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(showAdvertSent?.wrappedValue == true ? .green : MeshTheme.accent)
                    }
                    .accessibilityLabel("Advertise")
                    .disabled(connectionManager.connectionState != .ready)

                    Button {
                        showDiscover?.wrappedValue = true
                    } label: {
                        Image(systemName: "binoculars.fill")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .accessibilityLabel("Discover")
                    .disabled(connectionManager.connectionState != .ready)

                    Button {
                        connectionManager.refreshAll(contactStore: contactStore)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(connectionManager.connectionState != .ready)
                }
            }
        }
        #endif
        .overlay { deleteAlertsOverlay }
        .alert("Contact Shared", isPresented: $showShareConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Contact shared on mesh.")
        }
        .alert("Path Reset", isPresented: $showResetConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Outbound path has been reset. A new path will be discovered on next communication.")
        }
        .sheet(item: $detailContact) { contact in
            ContactDetailSheet(contact: contact)
                .frame(minWidth: 360, minHeight: 400)
        }
        .onChange(of: remoteSessionManager.detailContactForTrace?.id) {
            if let contact = remoteSessionManager.detailContactForTrace {
                detailContact = contact
                remoteSessionManager.detailContactForTrace = nil
            }
        }
        .sheet(item: $pathEditorContact) { contact in
            ManualPathEditor(contact: contact)
        }
        .sheet(item: $channelSheetAction) { action in
            NavigationStack {
                ChannelManagementView(action: action)
                        .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { channelSheetAction = nil }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 400)
        }
        #if !os(watchOS)
        .sheet(item: $channelToShareSidebar) { channel in
            ShareChannelSheet(channel: channel)
                .frame(minWidth: 360, minHeight: 400)
        }
        .sheet(isPresented: $showShareAllChannels) {
            ShareAllChannelsSheet(channels: channelStore.channels)
                .frame(minWidth: 360, minHeight: 400)
        }
        .alert("Rename Channel", isPresented: Binding(
            get: { channelToRenameSidebar != nil },
            set: { if !$0 { channelToRenameSidebar = nil } }
        )) {
            TextField("Channel name", text: $channelRenameText)
            Button("Cancel", role: .cancel) { channelToRenameSidebar = nil }
            Button("Rename") {
                if let ch = channelToRenameSidebar, !channelRenameText.isEmpty {
                    channelStore.setChannel(index: ch.index, name: channelRenameText, secret: ch.secret)
                }
                channelToRenameSidebar = nil
            }
        } message: {
            Text("Enter a new name for this channel.")
        }
        .alert("Remove Channel?", isPresented: $showChannelRemoveConfirm) {
            Button("Cancel", role: .cancel) { channelToRemove = nil }
            Button("Remove", role: .destructive) {
                if let ch = channelToRemove {
                    channelStore.setChannel(index: ch.index, name: "", secret: nil)
                }
                channelToRemove = nil
            }
        } message: {
            if let ch = channelToRemove {
                Text("Remove \"\(ch.name)\" from your channels?")
            }
        }
        .sheet(isPresented: $showMyContactCode) {
            MyContactCodeSheet()
                .frame(minWidth: 360, minHeight: 400)
        }
        .sheet(item: $shareContact) { contact in
            ShareContactSheet(contact: contact)
                .frame(minWidth: 360, minHeight: 400)
        }
        #endif
        .sheet(isPresented: $showNicknameSheet) {
            NavigationStack {
                Form {
                    Section {
                        HStack {
                        #if os(watchOS)
                            TextField("Nickname", text: $nicknameText)
                                .foregroundStyle(MeshTheme.textPrimary)
                                .onChange(of: nicknameText) { _, newValue in
                                    if newValue.count > 32 { nicknameText = String(newValue.prefix(32)) }
                                }
                        #else
                            TextField("Nickname", text: $nicknameText)
                                .foregroundStyle(MeshTheme.textPrimary)
                                .textFieldStyle(MeshTextFieldStyle())
                                .onChange(of: nicknameText) { _, newValue in
                                    if newValue.count > 32 { nicknameText = String(newValue.prefix(32)) }
                                }
                        #endif
                            Text("\(nicknameText.count)/32")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Custom Nickname")
                            .foregroundStyle(MeshTheme.textSecondary)
                    } footer: {
                        Text("This nickname is stored locally on your device. It doesn't change anything on the radio or the mesh network.")
                            .font(.caption2)
                    }

                    if let contact = nicknameContact {
                        Section {
                            HStack {
                                Text("Original Name")
                                    .foregroundStyle(MeshTheme.accent)
                                Spacer()
                                Text(contact.name)
                                    .foregroundStyle(MeshTheme.textPrimary)
                            }
                            HStack {
                                Text("Public Key")
                                    .foregroundStyle(MeshTheme.accent)
                                Spacer()
                                Text(Data(contact.publicKey.prefix(8)).hexCompact)
                                    .foregroundStyle(MeshTheme.textPrimary)
                                    .font(.caption)
                            }
                        } header: {
                            Text("Contact Info")
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }
                }
                .navigationTitle("Set Nickname")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showNicknameSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let contact = nicknameContact {
                                contactStore.setNickname(nicknameText.trimmingCharacters(in: .whitespaces), for: contact)
                            }
                            showNicknameSheet = false
                        }
                    }
                }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 300)
        }
        .onChange(of: messageStoreManager.lastExportedURL) { _, url in
            if let url, !url.isEmpty {
                copyToClipboard(url)
                messageStoreManager.lastExportedURL = nil
                isExporting = false
                showExportCopied = true
            }
        }
        .alert("Link Copied", isPresented: $showExportCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The contact's meshcore:// link has been copied to the clipboard.")
        }
    }

    // MARK: - Settings Navigation

    #if !os(watchOS)
    /// Opens Settings in the most platform-appropriate way:
    /// macOS/iPad (any size or orientation): selects Settings in the NavigationSplitView detail column.
    /// iPhone (compact): opens Settings as a sheet.
    ///
    /// Note: iPad mini landscape reports .compact horizontalSizeClass but is still a split-view
    /// layout. We detect iPad via UIDevice idiom to avoid opening a sheet on any iPad.
    private func openSettings() {
        #if os(macOS) || targetEnvironment(macCatalyst)
        navigationStore.sidebarSelection = .settings
        #elseif os(iOS)
        // All iPad models should use sidebar, regardless of size class.
        // iPad mini reports .pad idiom, but horizontalSizeClass can be .compact
        // in portrait. Use idiom-based detection instead of size class.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad

        if isPad {
            // All iPads (including iPad mini) use sidebar
            navigationStore.sidebarSelection = .settings
        } else {
            // iPhone: use sheet in portrait/compact, sidebar in landscape/regular
            if horizontalSizeClass == .regular {
                navigationStore.sidebarSelection = .settings
            } else {
                showSettings?.wrappedValue = true
            }
        }
        #endif
    }
    #endif

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            Button {
                if connectionManager.connectionState == .ready || connectionManager.connectionState == .connected {
                    #if os(macOS) || targetEnvironment(macCatalyst)
                    if isUSBCLIConnected {
                        navigationStore.sidebarSelection = .usbDevice
                    } else {
                        openSettings()
                    }
                    #elseif !os(watchOS)
                    openSettings()
                    #endif
                } else {
                    showScanner = true
                }
            } label: {
                HStack {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: connectionColor.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                    Text(connectionLabel)
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    if let rawName = {
                        if !deviceConfig.deviceName.isEmpty { return deviceConfig.deviceName }
                        if let name = connectionManager.connectedDeviceName { return name }
                        #if os(macOS) || targetEnvironment(macCatalyst)
                        if let name = remoteSessionManager.usbDeviceContact?.name, isUSBCLIConnected { return "USB: \(name)" }
                        #endif
                        return nil as String?
                    }() {
                        let shortName = rawName
                            .replacingOccurrences(of: "MeshCore-", with: "")
                            .replacingOccurrences(of: "meshcore-", with: "")
                        HStack(spacing: 4) {
                            Text(shortName)
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                            if deviceConfig.batteryPercent() > 0 {
                                Text("\u{2022} \(deviceConfig.batteryPercent())%")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                        }
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            .contextMenu {
                if connectionManager.connectionState == .ready || connectionManager.connectionState == .connected {
                    #if os(macOS) || targetEnvironment(macCatalyst)
                    if isUSBCLIConnected {
                        Button(role: .destructive) { remoteSessionManager.reset(); connectionManager.disconnectUSB() } label: {
                            Label("Disconnect USB", systemImage: "cable.connector.slash")
                        }
                    } else {
                        Button { showMyContactCode = true } label: {
                            Label("My Contact Code", systemImage: "qrcode")
                        }
                        if !deviceConfig.publicKeyHex.isEmpty {
                            Button {
                                copyToClipboard(deviceConfig.publicKeyHex)
                            } label: {
                                Label("Copy Public Key", systemImage: "doc.on.doc")
                            }
                        }
                        Button { connectionManager.verifyRadioConfig() } label: {
                            Label("Verify Radio Config", systemImage: "checkmark.shield")
                        }
                        Divider()
                        if connectionManager.usbManager.isConnected {
                            Button(role: .destructive) { connectionManager.disconnectUSB() } label: {
                                Label("Disconnect USB", systemImage: "cable.connector.slash")
                            }
                        } else {
                            Button(role: .destructive) { connectionManager.disconnect() } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                            }
                        }
                    }
                    #else
                    Button { showMyContactCode = true } label: {
                        Label("My Contact Code", systemImage: "qrcode")
                    }
                    if !deviceConfig.publicKeyHex.isEmpty {
                        Button {
                            copyToClipboard(deviceConfig.publicKeyHex)
                        } label: {
                            Label("Copy Public Key", systemImage: "doc.on.doc")
                        }
                    }
                    Button { connectionManager.verifyRadioConfig() } label: {
                        Label("Verify Radio Config", systemImage: "checkmark.shield")
                    }
                    Divider()
                    Button(role: .destructive) { connectionManager.disconnect() } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    #endif
                }
            }

            if let bleMsg = connectionManager.bleStatusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(bleMsg)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textPrimary)
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            #if !os(watchOS)
            HStack {
                Text("Status")
                    .foregroundStyle(MeshTheme.textSecondary)
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Settings")
                .buttonStyle(.plain)
            }
            #endif
        }
    }

    private var publicChannelRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MeshTheme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(MeshTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Public Channel")
                    .font(.body)
                    .foregroundStyle(MeshTheme.textPrimary)
                channelMessagePreview
            }
            Spacer()
            channelUnreadBadge
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var channelMessagePreview: some View {
        let messages = messageStoreManager.messagesByContact[publicChannelKey] ?? []
        if let last = messages.last {
            Text(last.text)
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .lineLimit(1)
        } else {
            Text("Mesh broadcast channel")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var channelUnreadBadge: some View {
        let count = messageStoreManager.unreadCounts[publicChannelKey] ?? 0
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MeshTheme.interactiveGreen)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var channelsSection: some View {
        Section {
            // Public channel is always the first item
            #if os(watchOS)
            NavigationLink {
                ChannelChatView(channelIndex: 0, channelName: "Public Channel")
            } label: {
                publicChannelRow
            }
            .listRowBackground(MeshTheme.surface)
            #else
            NavigationLink(value: SidebarSelection.publicChannel) {
                publicChannelRow
            }
            .listRowBackground(
                navigationStore.showPublicChannel
                    ? MeshTheme.surfaceLight
                    : MeshTheme.surface
            )
            #endif

            ForEach(channelStore.channels.filter { $0.index != 0 }) { channel in
                #if os(watchOS)
                NavigationLink {
                    ChannelChatView(channelIndex: channel.index, channelName: channel.name)
                } label: {
                    channelRow(channel)
                }
                .listRowBackground(MeshTheme.surface)
                #else
                NavigationLink(value: SidebarSelection.channel(channel.index)) {
                    channelRow(channel)
                }
                .contextMenu {
                    Button {
                        channelToShareSidebar = channel
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        channelToRenameSidebar = channel
                        channelRenameText = channel.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        channelToRemove = channel
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showChannelRemoveConfirm = true
                        }
                    } label: {
                        Label("Remove Channel", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        channelToRemove = channel
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showChannelRemoveConfirm = true
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .listRowBackground(
                    navigationStore.selectedChannelIndex == channel.index
                        ? MeshTheme.surfaceLight
                        : MeshTheme.surface
                )
                #endif
            }
        } header: {
            HStack {
                Text("Channels")
                    .foregroundStyle(MeshTheme.textSecondary)
                if channelStore.isSyncingChannels {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                #if !os(watchOS)
                Menu {
                    Button { channelSheetAction = .createPrivate } label: {
                        Label("Create Private Channel", systemImage: "lock.fill")
                    }
                    Button { channelSheetAction = .hashtag } label: {
                        Label("Join Hashtag Channel", systemImage: "number")
                    }
                    Button { channelSheetAction = .joinPrivate } label: {
                        Label("Join Private Channel", systemImage: "key.fill")
                    }
                    Button { showImportSheet = true } label: {
                        Label("Paste Channel Link", systemImage: "doc.on.clipboard")
                    }
                    if !channelStore.channels.isEmpty {
                        Divider()
                        Button { showShareAllChannels = true } label: {
                            Label("Share All Channels", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Add channel")
                .menuIndicator(.hidden)
                #endif
            }
        }
    }

    private func channelRow(_ channel: MeshChannel) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MeshTheme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: channel.channelType.iconName)
                    .foregroundStyle(MeshTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(channel.channelType.displayPrefix)\(channel.name)")
                    .font(.body)
                    .foregroundStyle(MeshTheme.textPrimary)
                let messages = messageStoreManager.messagesByContact[Data([channel.index])] ?? []
                if let last = messages.last {
                    Text(last.text)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(channel.channelType == .privateChannel ? "Private channel" : "Group channel")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            Spacer()
            let count = messageStoreManager.unreadCounts[Data([channel.index])] ?? 0
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MeshTheme.interactiveGreen)
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var pendingContactsSection: some View {
        Section {
            ForEach(contactStore.pendingNewContacts) { contact in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: contactIconName(for: contact.type))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name)
                            .font(.body)
                            .foregroundStyle(MeshTheme.textPrimary)
                        Text("New contact discovered")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        contactStore.acceptPendingContact(contact)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeshTheme.connected)
                    }
                    .buttonStyle(.plain)
                    Button {
                        contactStore.rejectPendingContact(contact)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MeshTheme.disconnected)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            Text("Pending Contacts")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var groupsSection: some View {
        Section {
            ForEach(contactStore.contactGroups) { group in
                DisclosureGroup {
                    let members = contactStore.contactsInGroup(group)
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
                        Spacer()
                        Text("\(group.memberPubkeys.count)")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            Text("Groups")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    private var contactsSectionHeader: some View {
        HStack {
            Text("Contacts")
                .foregroundStyle(MeshTheme.textSecondary)
            Spacer()
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
            Button(isSelecting ? "Done" : "Edit") {
                isSelecting.toggle()
                if !isSelecting { selectedContacts.removeAll() }
            }
            .font(.caption)
            .foregroundStyle(MeshTheme.accent)
        }
    }

    private var contactsSection: some View {
        Section {
            if contactStore.sortedContacts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 32))
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
                    .foregroundStyle(.black)
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
                .listRowBackground(MeshTheme.surface)
            } else {
                ForEach(contactStore.sortedContacts) { contact in
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
                        .tint(.yellow)
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
                    Button(selectedContacts.count == contactStore.sortedContacts.count ? "Deselect All" : "Select All") {
                        if selectedContacts.count == contactStore.sortedContacts.count {
                            selectedContacts.removeAll()
                        } else {
                            selectedContacts = Set(contactStore.sortedContacts.map(\.publicKeyPrefix))
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
        } header: {
            contactsSectionHeader
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


    @ViewBuilder
    private func contactContextMenu(for contact: Contact) -> some View {
        // Nickname — always first, most used
        Button {
            nicknameContact = contact
            nicknameText = contactStore.nickname(for: contact) ?? ""
            showNicknameSheet = true
        } label: {
            Label(contactStore.nickname(for: contact) != nil ? "Edit Nickname" : "Set Nickname",
                  systemImage: "pencil")
        }

        // Type-specific actions
        if contact.type == .repeater || contact.type == .room {
            Button {
                navigationStore.sidebarSelection = .contact(contact.publicKeyPrefix)
            } label: {
                Label("Remote Management", systemImage: "gearshape.2")
            }
        }

        if contact.type != .chat {
            Button {
                remoteSessionManager.requestStatus(for: contact)
            } label: {
                Label("Request Status", systemImage: "antenna.radiowaves.left.and.right")
            }
        }

        Button {
            remoteSessionManager.requestTelemetry(for: contact)
        } label: {
            Label("Request Telemetry", systemImage: "gauge.with.dots.needle.bottom.50percent")
        }

        if contact.type == .chat {
            Button {
                isExporting = true
                messageStoreManager.lastExportedURL = nil; connectionManager.exportContact(contact)
            } label: {
                Label("Share Contact", systemImage: "square.and.arrow.up")
            }
        }

        Button {
            pathEditorContact = contact
        } label: {
            Label("Edit Route", systemImage: "arrow.triangle.branch")
        }

        if contact.outPathLen > 0 && !contact.outPath.isEmpty {
            Button {
                remoteSessionManager.traceRoute(to: contact)
            } label: {
                Label("Trace Route", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }

        Button {
            contactStore.toggleFavourite(for: contact)
        } label: {
            Label(
                contact.isFavourite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: contact.isFavourite ? "star.slash" : "star"
            )
        }

        if !contactStore.contactGroups.isEmpty && contact.type == .chat {
            Menu {
                ForEach(contactStore.contactGroups) { group in
                    Button {
                        contactStore.addContactToGroup(contact, group: group)
                    } label: {
                        Label("\(group.emoji) \(group.name)", systemImage: "plus.circle")
                    }
                }
            } label: {
                Label("Add to Group", systemImage: "folder.badge.plus")
            }
        }

        Button {
            detailContact = contact
        } label: {
            Label("Network Details", systemImage: "info.circle")
        }

        Button {
            contactStore.resetPath(for: contact)
            showResetConfirmation = true
        } label: {
            Label("Reset Path", systemImage: "arrow.counterclockwise")
        }

        Divider()

        Button(role: .destructive) {
            contactToDelete = contact
            // Defer alert so context menu dismissal completes first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showDeleteConfirm = true
            }
        } label: {
            Label("Delete Contact", systemImage: "trash")
        }
    }

    private func toggleSelection(_ contact: Contact) {
        if selectedContacts.contains(contact.publicKeyPrefix) {
            selectedContacts.remove(contact.publicKeyPrefix)
        } else {
            selectedContacts.insert(contact.publicKeyPrefix)
        }
    }

    private func contactRow(_ contact: Contact) -> some View {
        ContactRowView(contact: contact)
    }

    /// Returns the appropriate detail view for a contact based on its type.
    @ViewBuilder
    private func contactDestination(_ contact: Contact) -> some View {
        switch contact.type {
        case .room:
            RoomChatView(
                contact: contact,
                session: remoteSessionManager.remoteSession(for: contact)
            )
        case .repeater:
            RepeaterLoginView(
                contact: contact,
                session: remoteSessionManager.remoteSession(for: contact)
            )
        default:
            ChatView(contact: contact)
                .onAppear { messageStoreManager.markAsRead(contact) }
        }
    }

    #if !os(watchOS)
    /// Resolves a SidebarSelection to the appropriate detail view (used by navigationDestination on compact).
    @ViewBuilder
    private func sidebarDestinationView(for selection: SidebarSelection) -> some View {
        switch selection {
        case .publicChannel:
            ChannelChatView(channelIndex: 0, channelName: "Public Channel")
        case .channel(let index):
            if let channel = channelStore.channels.first(where: { $0.index == index }) {
                ChannelChatView(channelIndex: channel.index, channelName: channel.name)
            } else {
                ChannelChatView(channelIndex: index, channelName: "Channel \(index)")
            }
        case .contact(let key):
            if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == key }) {
                contactDestination(contact)
                } else {
                Text("Contact not found")
            }
        case .settings:
            SettingsView()
        case .map:
            if #available(iOS 17.0, macOS 14.0, *) {
                MeshMapView()
            } else {
                Text("Map requires iOS 17+ or macOS 14+")
            }
        #if os(macOS) || targetEnvironment(macCatalyst)
        case .usbTerminal:
            USBTerminalView()
        case .usbDevice:
            if let contact = remoteSessionManager.usbDeviceContact, let session = remoteSessionManager.usbDeviceSession {
                RemoteManagementView(contact: contact, session: session)
                } else {
                Text("USB device not connected")
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        #endif
        }
    }
    #endif

    private func contactIconName(for type: ContactType) -> String {
        switch type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "server.rack"
        case .sensor: return "sensor.fill"
        case .unknown: return "person.fill"
        }
    }

    private var connectionColor: Color {
        switch connectionManager.connectionState {
        case .ready: MeshTheme.connected
        case .connected, .connecting: MeshTheme.connecting
        case .scanning: MeshTheme.scanning
        case .disconnected: MeshTheme.disconnected
        }
    }

    private var connectionLabel: String {
        switch connectionManager.connectionState {
        case .ready: "Connected"
        case .connected: "Discovering services..."
        case .connecting: "Connecting..."
        case .scanning: "Scanning..."
        case .disconnected: "Disconnected"
        }
    }

}

// MARK: - Main List (extracted to break type-checker chain)
private extension ContactListView {
    var mainList: some View {
        List(selection: $localSelection) {
            connectionSection
            channelsSection
            if !contactStore.pendingNewContacts.isEmpty {
                pendingContactsSection
            }
            if !contactStore.contactGroups.isEmpty {
                groupsSection
            }
            contactsSection
            #if !os(watchOS)
            Section {
                NavigationLink(value: SidebarSelection.map) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(MeshTheme.accent.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "map.fill")
                                .foregroundStyle(MeshTheme.accent)
                        }
                        Text("Mesh Map")
                            .font(.body)
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .listRowBackground(
                    navigationStore.sidebarSelection == .map
                        ? MeshTheme.surfaceLight
                        : MeshTheme.surface
                )
            }
            #endif
            #if os(macOS) || targetEnvironment(macCatalyst)
            if isUSBCLIConnected {
                Section {
                    NavigationLink(value: SidebarSelection.usbDevice) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(MeshTheme.connected.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "cable.connector")
                                    .foregroundStyle(MeshTheme.connected)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(remoteSessionManager.usbDeviceContact?.name ?? "USB Device")
                                    .font(.body)
                                    .foregroundStyle(MeshTheme.textPrimary)
                                Text("USB Serial \u{2022} Admin")
                                    .font(.caption)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(MeshTheme.surface)

                    NavigationLink(value: SidebarSelection.usbTerminal) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(MeshTheme.accent.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "terminal")
                                    .foregroundStyle(MeshTheme.accent)
                            }
                            Text("USB Terminal")
                                .font(.body)
                                .foregroundStyle(MeshTheme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(MeshTheme.surface)

                    Button(role: .destructive) {
                        remoteSessionManager.reset()
                        connectionManager.disconnectUSB()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(MeshTheme.disconnected.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "cable.connector.slash")
                                    .foregroundStyle(MeshTheme.disconnected)
                            }
                            Text("Disconnect USB")
                                .font(.body)
                                .foregroundStyle(MeshTheme.disconnected)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(MeshTheme.surface)
                } header: {
                    Text("USB Device")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            } else if connectionManager.usbManager.isConnected && connectionManager.usbManager.detectedMode == .cli {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(MeshTheme.accent)
                        Text("Connecting to USB device...")
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            }
            #endif
        }
        .meshListStyle()
        .refreshable {
            guard connectionManager.connectionState == .ready else { return }
            connectionManager.refreshAll(contactStore: contactStore)
        }
    }
}

// MARK: - Delete Alerts (extracted to break type-checker chain)
private extension ContactListView {
    @ViewBuilder
    var deleteAlertsOverlay: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Remove Contact?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) { contactToDelete = nil }
                Button("Remove", role: .destructive) {
                    if let contact = contactToDelete {
                        contactStore.removeContact(contact)
                    }
                    contactToDelete = nil
                }
            } message: {
                if let contact = contactToDelete {
                    Text("Are you sure you want to remove \(contactStore.displayName(for: contact))? This will delete all messages with this contact.")
                }
            }
            .confirmationDialog("Delete \(selectedContacts.count) Contact\(selectedContacts.count == 1 ? "" : "s")?", isPresented: $showBulkDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    for key in selectedContacts {
                        if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == key }) {
                            contactStore.removeContact(contact)
                        }
                    }
                    selectedContacts.removeAll()
                    isSelecting = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the selected contacts from the device. This cannot be undone.")
            }
    }
}
