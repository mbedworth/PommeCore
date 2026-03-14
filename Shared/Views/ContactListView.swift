import SwiftUI
import MeshCoreKit

struct ContactListView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Binding var showScanner: Bool

    @State private var contactToDelete: Contact?
    @State private var showDeleteConfirm = false
    @State private var showImportSheet = false
    @State private var importURLText = ""
    @State private var showShareConfirmation = false
    @State private var showResetConfirmation = false
    @State private var detailContact: Contact?
    @State private var showChannelSheet = false

    /// Public Channel virtual contact key (channel 0).
    private let publicChannelKey = Data([0x00 as UInt8])

    var body: some View {
        List {
            connectionSection
            channelsSection
            if !viewModel.pendingNewContacts.isEmpty {
                pendingContactsSection
            }
            contactsSection
        }
        .meshListStyle()
        .navigationTitle("MeshCore")
        #if os(watchOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accentFallback)
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
                showScanner = true
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
        }
    }

    private var publicChannelRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MeshTheme.accentFallback.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(MeshTheme.accentFallback)
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
                .foregroundStyle(MeshTheme.textOnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MeshTheme.accentFallback)
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
            Button {
                viewModel.selectedContact = nil
                viewModel.selectedChannelIndex = nil
                viewModel.showPublicChannel = true
            } label: {
                publicChannelRow
            }
            .buttonStyle(.plain)
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
                Button {
                    viewModel.selectedContact = nil
                    viewModel.showPublicChannel = false
                    viewModel.selectedChannelIndex = channel.index
                } label: {
                    channelRow(channel)
                }
                .buttonStyle(.plain)
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
                        .foregroundStyle(MeshTheme.accentFallback)
                    Text("Join Channel")
                        .foregroundStyle(MeshTheme.accentFallback)
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
                    .fill(MeshTheme.accentFallback.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: channel.channelType.iconName)
                    .foregroundStyle(MeshTheme.accentFallback)
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
                    .foregroundStyle(MeshTheme.textOnAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MeshTheme.accentFallback)
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
            if viewModel.contacts.isEmpty {
                HStack {
                    Image(systemName: "person.2.slash")
                        .foregroundStyle(MeshTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No contacts yet")
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("Send an advertisement to discover nearby devices")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary.opacity(0.7))
                    }
                }
                .listRowBackground(MeshTheme.surface)
            } else {
                ForEach(viewModel.contacts) { contact in
                    #if os(watchOS)
                    NavigationLink {
                        contactDestination(contact)
                            .environmentObject(viewModel)
                    } label: {
                        contactRow(contact)
                    }
                    .listRowBackground(MeshTheme.surface)
                    #else
                    Button {
                        viewModel.showPublicChannel = false
                        viewModel.selectedChannelIndex = nil
                        viewModel.selectedContact = contact
                        viewModel.markAsRead(contact)
                    } label: {
                        contactRow(contact)
                    }
                    .buttonStyle(.plain)
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
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Text("Import Contact")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
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
        .alert("Import Contact", isPresented: $showImportSheet) {
            TextField("meshcore:// URL", text: $importURLText)
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                let url = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    viewModel.importContact(url: url)
                }
            }
        } message: {
            Text("Paste a meshcore:// link to add a contact.")
        }
    }

    @ViewBuilder
    private func contactContextMenu(for contact: Contact) -> some View {
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

        Button {
            viewModel.resetPath(for: contact)
            showResetConfirmation = true
        } label: {
            Label("Reset Path", systemImage: "arrow.triangle.2.circlepath")
        }

        Button {
            detailContact = contact
        } label: {
            Label("Network Details", systemImage: "info.circle")
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
                    Text(contact.name)
                        .font(.body)
                        .foregroundStyle(MeshTheme.textPrimary)
                    loginBadge(for: contact)
                    pathIndicator(for: contact)
                }
                lastMessagePreview(for: contact)
            }
            Spacer()
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
                .fill(MeshTheme.accentFallback.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: contactIconName(for: contact.type))
                .foregroundStyle(MeshTheme.accentFallback)

            // Lock overlay for repeaters/room servers when not logged in
            if isManaged && !loggedIn {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(MeshTheme.textSecondary)
                    .offset(x: 14, y: 14)
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
                    .foregroundStyle(MeshTheme.textOnAccent)
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
                .foregroundStyle(MeshTheme.textOnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MeshTheme.accentFallback)
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
        case .admin: return MeshTheme.connected
        }
    }
}
