import SwiftUI
import MeshCoreKit

struct ContactListView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Binding var showScanner: Bool
    var showDiscover: Binding<Bool>? = nil
    var showSettings: Binding<Bool>? = nil
    var showRemoteManagement: Binding<Bool>? = nil
    var showAdvertSent: Binding<Bool>? = nil

    @State private var contactToDelete: Contact?
    @State private var showDeleteConfirm = false
    @State private var showImportSheet = false
    @State private var importURLText = ""
    @State private var showShareConfirmation = false
    @State private var showResetConfirmation = false
    @State private var detailContact: Contact?
    @State private var showChannelSheet = false
    @State private var showDeviceInfo = false
    @State private var showNicknameSheet = false
    #if os(iOS)
    @State private var showQRScanner = false
    #endif
    @State private var nicknameContact: Contact?
    @State private var nicknameText = ""
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
            contactsSection
            #if !os(watchOS)
            settingsSection
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
            // Mark contact as read when selected
            if case .contact(let key) = selection,
               let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == key }) {
                viewModel.markAsRead(contact)
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
                Button {
                    if viewModel.connectionState == .ready {
                        viewModel.sendAdvertise(type: 0)
                        showAdvertSent?.wrappedValue = true
                    } else {
                        showScanner = true
                    }
                } label: {
                    Image(systemName: viewModel.connectionState == .ready
                          ? "antenna.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Send Advertisement")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showDiscover?.wrappedValue = true
                } label: {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .foregroundStyle(MeshTheme.accent)
                }
                .accessibilityLabel("Discover Nearby Nodes")
                .disabled(viewModel.connectionState != .ready)
            }

            ToolbarItem(placement: .automatic) {
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
                        #else
                        TextField("Nickname", text: $nicknameText)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .textFieldStyle(MeshTextFieldStyle())
                        #endif
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
            }
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
                    if let name = viewModel.connectedDeviceName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
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
                .listRowBackground(
                    viewModel.selectedChannelIndex == channel.index
                        ? MeshTheme.surfaceLight
                        : MeshTheme.surface
                )
                #endif
            }
            #if !os(watchOS)
            Button {
                showChannelSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.bubble")
                        .foregroundStyle(MeshTheme.accent)
                    Text("Join Channel")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
            #endif
        } header: {
            HStack {
                Text("Channels")
                    .foregroundStyle(MeshTheme.textSecondary)
                if viewModel.isSyncingChannels {
                    ProgressView()
                        .controlSize(.mini)
                }
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
        } header: {
            Text("Contacts")
                .foregroundStyle(MeshTheme.textSecondary)
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
        Button {
            detailContact = contact
        } label: {
            Label("Network Details", systemImage: "info.circle")
        }

        Button {
            nicknameContact = contact
            nicknameText = viewModel.nickname(for: contact) ?? ""
            showNicknameSheet = true
        } label: {
            Label(viewModel.nickname(for: contact) != nil ? "Edit Nickname" : "Set Nickname",
                  systemImage: "pencil")
        }

        if viewModel.nickname(for: contact) != nil {
            Button {
                viewModel.setNickname("", for: contact)
            } label: {
                Label("Remove Nickname", systemImage: "pencil.slash")
            }
        }

        Divider()

        Button {
            viewModel.toggleFavourite(for: contact)
        } label: {
            Label(
                contact.isFavourite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: contact.isFavourite ? "star.slash" : "star"
            )
        }

        Button {
            viewModel.shareContact(contact)
            showShareConfirmation = true
        } label: {
            Label("Share on Mesh", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            viewModel.exportContact(contact)
        } label: {
            Label("Export Link", systemImage: "square.and.arrow.up")
        }

        #if !os(watchOS)
        Button {
            shareContact = contact
        } label: {
            Label("Share QR Code", systemImage: "qrcode")
        }
        #endif

        Divider()

        Button {
            viewModel.resetPath(for: contact)
            showResetConfirmation = true
        } label: {
            Label("Reset Path", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button(role: .destructive) {
            contactToDelete = contact
            showDeleteConfirm = true
        } label: {
            Label("Remove Contact", systemImage: "trash")
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
            Circle()
                .fill(MeshTheme.accent.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: contactIconName(for: contact.type))
                .foregroundStyle(MeshTheme.accent)

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
        case .unknown: return "questionmark"
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
            Text("\(contact.outPathLen) hop\(contact.outPathLen == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
        }
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
            } else {
                Text(contact.lastSeen, style: .relative)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
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
