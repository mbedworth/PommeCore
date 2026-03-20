import SwiftUI
import MeshCoreKit

struct ContactListView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
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
    @State private var showChannelSheet = false
    @State private var showDeviceInfo = false
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

    /// Public Channel virtual contact key (channel 0).
    private let publicChannelKey = Data([0x00 as UInt8])

    var body: some View {
        List(selection: $viewModel.sidebarSelection) {
            connectionSection
            channelsSection
            if !viewModel.pendingNewContacts.isEmpty {
                pendingContactsSection
            }
            if !viewModel.contactGroups.isEmpty {
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
                    viewModel.sidebarSelection == .map
                        ? MeshTheme.surfaceLight
                        : MeshTheme.surface
                )
            }
            settingsSection
            #endif
            #if os(macOS)
            if viewModel.usbManager.isConnected && viewModel.usbManager.detectedMode == .cli {
                Section {
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
                }
            }
            #endif
        }
        .meshListStyle()
        .refreshable {
            guard viewModel.connectionState == .ready else { return }
            viewModel.refreshAll()
        }
        .navigationTitle("MeshCore")
        #if !os(watchOS)
        .navigationDestination(for: SidebarSelection.self) { selection in
            sidebarDestinationView(for: selection)
        }
        .onChange(of: viewModel.sidebarSelection) { selection in
            // Mark contact as read when selected (dispatch to avoid publishing during view update)
            if case .contact(let key) = selection,
               let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == key }) {
                DispatchQueue.main.async {
                    viewModel.markAsRead(contact)
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
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        viewModel.sendAdvertise(type: 1)
                        showAdvertSent?.wrappedValue = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showAdvertSent?.wrappedValue = false
                        }
                    } label: {
                        Image(systemName: showAdvertSent?.wrappedValue == true
                              ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(showAdvertSent?.wrappedValue == true ? .green : MeshTheme.accent)
                    }
                    .disabled(viewModel.connectionState != .ready)

                    Button {
                        showDiscover?.wrappedValue = true
                    } label: {
                        Image(systemName: "binoculars.fill")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .disabled(viewModel.connectionState != .ready)

                    Button {
                        viewModel.refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Refresh")
                .disabled(viewModel.connectionState != .ready)
                }
            }
        }
        #endif
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
                .environmentObject(viewModel)
                .frame(minWidth: 360, minHeight: 400)
        }
        .onChange(of: viewModel.detailContactForTrace?.id) { _ in
            if let contact = viewModel.detailContactForTrace {
                detailContact = contact
                viewModel.detailContactForTrace = nil
            }
        }
        .sheet(item: $pathEditorContact) { contact in
            ManualPathEditor(contact: contact)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showChannelSheet) {
            NavigationStack {
                ChannelManagementView()
                    .environmentObject(viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showChannelSheet = false }
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
            ShareAllChannelsSheet(channels: viewModel.channels)
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
                    viewModel.setChannel(index: ch.index, name: channelRenameText, secret: ch.secret)
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
                    viewModel.setChannel(index: ch.index, name: "", secret: nil)
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
                .environmentObject(viewModel)
                .frame(minWidth: 360, minHeight: 400)
        }
        .sheet(item: $shareContact) { contact in
            ShareContactSheet(contact: contact)
                .environmentObject(viewModel)
                .frame(minWidth: 360, minHeight: 400)
        }
        #endif
        .sheet(isPresented: $showNicknameSheet) {
            NavigationStack {
                Form {
                    Section {
                        #if os(watchOS)
                        TextField("Nickname", text: $nicknameText)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .onChange(of: nicknameText) { newValue in
                                if newValue.count > 32 { nicknameText = String(newValue.prefix(32)) }
                            }
                        #else
                        TextField("Nickname", text: $nicknameText)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .textFieldStyle(MeshTextFieldStyle())
                            .onChange(of: nicknameText) { newValue in
                                if newValue.count > 32 { nicknameText = String(newValue.prefix(32)) }
                            }
                        #endif
                        HStack {
                            Spacer()
                            Text("\(nicknameText.count)/32")
                                .font(.caption2)
                                .foregroundStyle(nicknameText.count > 28 ? .orange : MeshTheme.textSecondary)
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
                                Text(contact.publicKey.prefix(8).map { String(format: "%02x", $0) }.joined())
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
                                viewModel.setNickname(nicknameText.trimmingCharacters(in: .whitespaces), for: contact)
                            }
                            showNicknameSheet = false
                        }
                    }
                }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 300)
        }
        .onChange(of: viewModel.lastExportedURL) { url in
            if let url, !url.isEmpty {
                #if os(iOS)
                UIPasteboard.general.string = url
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                #endif
                viewModel.lastExportedURL = nil
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

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            Button {
                if viewModel.connectionState == .ready || viewModel.connectionState == .connected {
                    showDeviceInfo = true
                } else {
                    showScanner = true
                }
            } label: {
                HStack {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: connectionColor.opacity(0.6), radius: 4)
                    Text(connectionLabel)
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    if let rawName = !viewModel.deviceConfig.deviceName.isEmpty ? viewModel.deviceConfig.deviceName : viewModel.connectedDeviceName {
                        let shortName = rawName
                            .replacingOccurrences(of: "MeshCore-", with: "")
                            .replacingOccurrences(of: "meshcore-", with: "")
                        HStack(spacing: 4) {
                            Text(shortName)
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                            if viewModel.deviceConfig.batteryPercent() > 0 {
                                Text("\u{2022} \(viewModel.deviceConfig.batteryPercent())%")
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
                if viewModel.connectionState == .ready || viewModel.connectionState == .connected {
                    Button { showMyContactCode = true } label: {
                        Label("My Contact Code", systemImage: "qrcode")
                    }
                    Button { viewModel.verifyRadioConfig() } label: {
                        Label("Verify Radio Config", systemImage: "checkmark.shield")
                    }
                    Divider()
                    Button(role: .destructive) { viewModel.disconnect() } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }

            if let bleMsg = viewModel.bleStatusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(bleMsg)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textPrimary)
                }
                .listRowBackground(MeshTheme.surface)
            }
        }
        .sheet(isPresented: $showDeviceInfo) {
            NavigationStack {
                DeviceInfoPopover()
                    .environmentObject(viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDeviceInfo = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 300)
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
        let messages = viewModel.messagesByContact[publicChannelKey] ?? []
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
        let count = viewModel.unreadCounts[publicChannelKey] ?? 0
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
                viewModel.showPublicChannel
                    ? MeshTheme.surfaceLight
                    : MeshTheme.surface
            )
            #endif

            ForEach(viewModel.channels.filter { $0.index != 0 }) { channel in
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
                        showChannelRemoveConfirm = true
                    } label: {
                        Label("Remove Channel", systemImage: "trash")
                    }
                }
                .listRowBackground(
                    viewModel.selectedChannelIndex == channel.index
                        ? MeshTheme.surfaceLight
                        : MeshTheme.surface
                )
                #endif
            }
        } header: {
            HStack {
                Text("Channels")
                    .foregroundStyle(MeshTheme.textSecondary)
                if viewModel.isSyncingChannels {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                #if !os(watchOS)
                Menu {
                    Button { showChannelSheet = true } label: {
                        Label("Create Private Channel", systemImage: "lock.fill")
                    }
                    Button { showChannelSheet = true } label: {
                        Label("Join Hashtag Channel", systemImage: "number")
                    }
                    Button { showChannelSheet = true } label: {
                        Label("Join Private Channel", systemImage: "key.fill")
                    }
                    Button { showImportSheet = true } label: {
                        Label("Paste Channel Link", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(MeshTheme.accent)
                }
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
                let messages = viewModel.messagesByContact[Data([channel.index])] ?? []
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
            let count = viewModel.unreadCounts[Data([channel.index])] ?? 0
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
            ForEach(viewModel.pendingNewContacts) { contact in
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
                        viewModel.acceptPendingContact(contact)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeshTheme.connected)
                    }
                    .buttonStyle(.plain)
                    Button {
                        viewModel.rejectPendingContact(contact)
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
            ForEach(viewModel.contactGroups) { group in
                DisclosureGroup {
                    let members = viewModel.contactsInGroup(group)
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
                                    .environmentObject(viewModel)
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

    private var contactsSection: some View {
        Section {
            if viewModel.sortedContacts.isEmpty {
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
                        viewModel.sendAdvertise(type: 0)
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
                ForEach(viewModel.sortedContacts) { contact in
                    #if os(watchOS)
                    NavigationLink {
                        contactDestination(contact)
                            .environmentObject(viewModel)
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
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            viewModel.toggleFavourite(for: contact)
                        } label: {
                            Label(
                                contact.isFavourite ? "Unfavourite" : "Favourite",
                                systemImage: contact.isFavourite ? "star.slash" : "star.fill"
                            )
                        }
                        .tint(.yellow)
                    }
                    .listRowBackground(
                        viewModel.selectedContact?.publicKeyPrefix == contact.publicKeyPrefix
                            && !viewModel.showPublicChannel
                            ? MeshTheme.surfaceLight
                            : MeshTheme.surface
                    )
                    } // end else (not selecting)
                    #endif
                }
            }

            #if !os(watchOS)
            Button {
                importURLText = ""
                showImportSheet = true
            } label: {
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(MeshTheme.accent)
                    Text("Paste Link")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            #if os(iOS)
            Button {
                showQRScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(MeshTheme.accent)
                    Text("Scan QR Code")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            #endif
            #endif
            if isSelecting {
                HStack {
                    Button(selectedContacts.count == viewModel.sortedContacts.count ? "Deselect All" : "Select All") {
                        if selectedContacts.count == viewModel.sortedContacts.count {
                            selectedContacts.removeAll()
                        } else {
                            selectedContacts = Set(viewModel.sortedContacts.map(\.publicKeyPrefix))
                        }
                    }
                    .font(.caption)
                    Spacer()
                    if !selectedContacts.isEmpty {
                        Button {
                            for key in selectedContacts {
                                if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == key }) {
                                    viewModel.exportContact(contact)
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
            HStack {
                Text("Contacts")
                    .foregroundStyle(MeshTheme.textSecondary)
                Spacer()
                Menu {
                    Button { showImportSheet = true } label: {
                        Label("Paste Contact Link", systemImage: "doc.on.clipboard")
                    }
                    Button { viewModel.sendAdvertise(type: 1) } label: {
                        Label("Send Flood Advert", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(MeshTheme.accent)
                }
                Button(isSelecting ? "Done" : "Edit") {
                    isSelecting.toggle()
                    if !isSelecting { selectedContacts.removeAll() }
                }
                .font(.caption)
                .foregroundStyle(MeshTheme.accent)
            }
        }
        .confirmationDialog("Delete \(selectedContacts.count) Contact\(selectedContacts.count == 1 ? "" : "s")?", isPresented: $showBulkDeleteConfirm) {
            Button("Delete", role: .destructive) {
                for key in selectedContacts {
                    if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == key }) {
                        viewModel.removeContact(contact)
                    }
                }
                selectedContacts.removeAll()
                isSelecting = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the selected contacts from the device. This cannot be undone.")
        }
        .alert("Remove Contact?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { contactToDelete = nil }
            Button("Remove", role: .destructive) {
                if let contact = contactToDelete {
                    viewModel.removeContact(contact)
                }
                contactToDelete = nil
            }
        } message: {
            if let contact = contactToDelete {
                Text("Are you sure you want to remove \(contact.name)? This will delete all messages with this contact.")
            }
        }
        .alert("Import from Link", isPresented: $showImportSheet) {
            TextField("meshcore:// URL", text: $importURLText)
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                let url = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    viewModel.handleMeshCoreURL(url)
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
                    viewModel.handleMeshCoreURL(scannedURL)
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
            isPresented: $viewModel.showChannelImportOptions,
            presenting: viewModel.pendingChannelImport
        ) { data in
            Button("Add Channel") {
                viewModel.importChannelAdd(data)
                viewModel.pendingChannelImport = nil
            }
            Button("Replace All Channels", role: .destructive) {
                viewModel.importChannelReplaceAll(data)
                viewModel.pendingChannelImport = nil
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingChannelImport = nil
            }
        } message: { data in
            Text("Add \"\(data.name)\" to your channels, or replace all existing channels?")
        }
        .confirmationDialog(
            "Import \(viewModel.pendingMultiChannelImport?.channels.count ?? 0) Channels",
            isPresented: $viewModel.showMultiChannelImportOptions,
            presenting: viewModel.pendingMultiChannelImport
        ) { data in
            Button("Add to Existing Channels") {
                viewModel.importMultiChannelsAdd(data)
                viewModel.pendingMultiChannelImport = nil
            }
            Button("Replace All Channels", role: .destructive) {
                viewModel.importMultiChannelsReplace(data)
                viewModel.pendingMultiChannelImport = nil
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingMultiChannelImport = nil
            }
        } message: { data in
            Text("Import \(data.names)?\n\nAdd will keep your existing channels. Replace will remove all current channels first.")
        }
        .confirmationDialog("Send Advertisement", isPresented: $showAdvertOptions) {
            Button("Zero-Hop (nearby only)") {
                lastAdvertFlood = false
                viewModel.sendAdvertise(type: 0)
                showAdvertSent?.wrappedValue = true
            }
            Button("Flood (entire mesh)") {
                lastAdvertFlood = true
                viewModel.sendAdvertise(type: 1)
                showAdvertSent?.wrappedValue = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zero-hop reaches nearby nodes only. Flood is relayed by repeaters across the entire mesh network.")
        }
    }

    #if !os(watchOS)
    @ViewBuilder
    private var settingsSection: some View {
        Section {
            NavigationLink(value: SidebarSelection.settings) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(MeshTheme.accent.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    Text("Device Settings")
                        .font(.body)
                        .foregroundStyle(MeshTheme.accent)
                }
                .contentShape(Rectangle())
            }
            .listRowBackground(
                viewModel.sidebarSelection == .settings
                    ? MeshTheme.surfaceLight
                    : MeshTheme.surface
            )
        }
    }
    #endif

    @ViewBuilder
    private func contactContextMenu(for contact: Contact) -> some View {
        // Nickname — always first, most used
        Button {
            nicknameContact = contact
            nicknameText = viewModel.nickname(for: contact) ?? ""
            showNicknameSheet = true
        } label: {
            Label(viewModel.nickname(for: contact) != nil ? "Edit Nickname" : "Set Nickname",
                  systemImage: "pencil")
        }

        // Type-specific actions
        if contact.type == .repeater || contact.type == .room {
            Button {
                viewModel.sidebarSelection = .contact(contact.publicKeyPrefix)
            } label: {
                Label("Remote Management", systemImage: "gearshape.2")
            }
        }

        if contact.type != .chat {
            Button {
                viewModel.requestStatus(for: contact)
            } label: {
                Label("Request Status", systemImage: "antenna.radiowaves.left.and.right")
            }
        }

        Button {
            viewModel.requestTelemetry(for: contact)
        } label: {
            Label("Request Telemetry", systemImage: "gauge.with.dots.needle.bottom.50percent")
        }

        if contact.type == .chat {
            Button {
                isExporting = true
                viewModel.exportContact(contact)
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
                viewModel.traceRoute(to: contact)
            } label: {
                Label("Trace Route", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }

        Button {
            viewModel.toggleFavourite(for: contact)
        } label: {
            Label(
                contact.isFavourite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: contact.isFavourite ? "star.slash" : "star"
            )
        }

        if !viewModel.contactGroups.isEmpty && contact.type == .chat {
            Menu {
                ForEach(viewModel.contactGroups) { group in
                    Button {
                        viewModel.addContactToGroup(contact, group: group)
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
            viewModel.resetPath(for: contact)
            showResetConfirmation = true
        } label: {
            Label("Reset Path", systemImage: "arrow.counterclockwise")
        }

        Divider()

        Button(role: .destructive) {
            contactToDelete = contact
            showDeleteConfirm = true
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
        HStack(spacing: 12) {
            contactIcon(for: contact)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(viewModel.displayName(for: contact))
                        .font(.body)
                        .foregroundStyle(MeshTheme.textPrimary)
                    loginBadge(for: contact)
                    pathIndicator(for: contact)
                }
                if viewModel.nickname(for: contact) != nil {
                    Text(contact.name)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                lastMessagePreview(for: contact)
            }
            Spacer()
            if viewModel.hasDraft(for: contact.publicKeyPrefix) {
                Text("Draft")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if viewModel.hasNote(for: contact) {
                Image(systemName: "note.text")
                    .foregroundStyle(MeshTheme.textSecondary)
                    .font(.caption)
            }
            if contact.isFavourite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            unreadBadge(for: contact)
        }
        .contentShape(Rectangle())
    }

    /// Returns the appropriate detail view for a contact based on its type.
    @ViewBuilder
    private func contactDestination(_ contact: Contact) -> some View {
        switch contact.type {
        case .room:
            RoomChatView(
                contact: contact,
                session: viewModel.remoteSession(for: contact)
            )
        case .repeater:
            RepeaterLoginView(
                contact: contact,
                session: viewModel.remoteSession(for: contact)
            )
        default:
            ChatView(contact: contact)
                .onAppear { viewModel.markAsRead(contact) }
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
            if let channel = viewModel.channels.first(where: { $0.index == index }) {
                ChannelChatView(channelIndex: channel.index, channelName: channel.name)
            } else {
                ChannelChatView(channelIndex: index, channelName: "Channel \(index)")
            }
        case .contact(let key):
            if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == key }) {
                contactDestination(contact)
                    .environmentObject(viewModel)
            } else {
                Text("Contact not found")
            }
        case .settings:
            SettingsView()
                .environmentObject(viewModel)
        case .map:
            if #available(iOS 17.0, macOS 14.0, *) {
                MeshMapView()
            } else {
                Text("Map requires iOS 17+ or macOS 14+")
            }
        #if os(macOS)
        case .usbTerminal:
            USBTerminalView()
        #endif
        }
    }
    #endif

    @ViewBuilder
    private func contactIcon(for contact: Contact) -> some View {
        let isManaged = contact.type == .repeater || contact.type == .room
        let session = isManaged ? viewModel.remoteSession(for: contact) : nil
        let loggedIn: Bool = {
            guard let s = session else { return false }
            if case .loggedIn = s.loginState { return true }
            return false
        }()

        ZStack {
            let statusColor = viewModel.contactStatusColor(for: contact)
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: contactIconName(for: contact.type))
                .foregroundStyle(statusColor)

            // Status overlay for repeaters/room servers
            if isManaged {
                if loggedIn {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MeshTheme.connected)
                        .offset(x: 14, y: 14)
                } else if KeychainManager.hasPassword(forDevice: contact.publicKey) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MeshTheme.textSecondary)
                        .offset(x: 14, y: 14)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MeshTheme.textSecondary)
                        .offset(x: 14, y: 14)
                }
            }
        }
    }

    private func contactIconName(for type: ContactType) -> String {
        switch type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "server.rack"
        case .sensor: return "sensor.fill"
        case .unknown: return "person.fill"
        }
    }

    @ViewBuilder
    private func loginBadge(for contact: Contact) -> some View {
        if contact.type == .repeater || contact.type == .room {
            let session = viewModel.remoteSession(for: contact)
            switch session.loginState {
            case .loggedIn(let permission):
                Text(permission.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(permissionBadgeColor(permission).opacity(0.8))
                    .clipShape(Capsule())
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func pathIndicator(for contact: Contact) -> some View {
        if contact.outPathLen == 0 {
            Text("direct")
                .font(.caption2)
                .foregroundStyle(MeshTheme.connected)
        } else if contact.outPathLen > 0 {
            let pathStr = formatPathHashes(contact.outPath, hopCount: Int(contact.outPathLen))
            if pathStr.isEmpty {
                Text("\(contact.outPathLen) hop\(contact.outPathLen == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)
            } else {
                Text(pathStr)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(MeshTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Format path hashes from outPath data. Each hop uses 1-3 bytes depending on path hash mode.
    private func formatPathHashes(_ pathData: Data, hopCount: Int) -> String {
        guard !pathData.isEmpty, hopCount > 0 else { return "" }
        let bytesPerHop = pathData.count / hopCount
        guard bytesPerHop >= 1 && bytesPerHop <= 3 else { return "" }
        var hops: [String] = []
        for i in 0..<hopCount {
            let start = i * bytesPerHop
            let end = min(start + bytesPerHop, pathData.count)
            guard end <= pathData.count else { break }
            let hash = pathData[start..<end]
            let hexStr = hash.map { String(format: "%02X", $0) }.joined()
            // Try to resolve to a known repeater name
            if let name = viewModel.contactNameForHash(hexStr) {
                hops.append(name)
            } else {
                hops.append(hexStr)
            }
        }
        return hops.joined(separator: " \u{2192} ")
    }

    @ViewBuilder
    private func lastMessagePreview(for contact: Contact) -> some View {
        if (contact.type == .repeater || contact.type == .room),
           case .loggedIn(let permission) = viewModel.remoteSession(for: contact).loginState {
            let session = viewModel.remoteSession(for: contact)
            if let ver = session.settings["ver"], !ver.isEmpty {
                Text("Connected \u{2014} \(permission.displayName) \u{00B7} \(ver)")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.connected)
                    .lineLimit(1)
            } else {
                Text("Connected \u{2014} \(permission.displayName)")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.connected)
            }
        } else {
            let messages = viewModel.messages(for: contact)
            if let last = messages.last {
                Text(last.text)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .lineLimit(1)
            } else if let seenText = lastSeenText(for: contact) {
                Text(seenText)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            } else {
                Text("Never seen")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
    }

    /// Returns a "Seen X ago" string for valid, recent timestamps, or nil.
    private func lastSeenText(for contact: Contact) -> String? {
        guard contact.lastAdvert > 1_000_000_000 else { return nil }

        let date = Date(timeIntervalSince1970: TimeInterval(contact.lastAdvert))
        let now = Date()

        // If more than 1 year ago, likely stale
        if now.timeIntervalSince(date) > 365 * 24 * 60 * 60 {
            return nil
        }

        // If in the future (clock skew), allow 5 min tolerance
        if date > now.addingTimeInterval(300) {
            return nil
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Seen \(formatter.localizedString(for: date, relativeTo: now))"
    }

    @ViewBuilder
    private func unreadBadge(for contact: Contact) -> some View {
        let count = viewModel.unreadCount(for: contact)
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

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .ready: MeshTheme.connected
        case .connected, .connecting: MeshTheme.connecting
        case .scanning: MeshTheme.scanning
        case .disconnected: MeshTheme.disconnected
        }
    }

    private var connectionLabel: String {
        switch viewModel.connectionState {
        case .ready: "Connected"
        case .connected: "Discovering services..."
        case .connecting: "Connecting..."
        case .scanning: "Scanning..."
        case .disconnected: "Disconnected"
        }
    }

    private func permissionBadgeColor(_ permission: RemotePermission) -> Color {
        switch permission {
        case .guest: return MeshTheme.textSecondary
        case .readOnly: return .yellow
        case .readWrite: return .blue
        case .admin: return MeshTheme.interactiveGreen
        }
    }
}
