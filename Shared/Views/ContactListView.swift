import SwiftUI
import MeshCoreKit

struct ContactListView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Binding var showScanner: Bool

    /// Public Channel virtual contact key (channel 0).
    private let publicChannelKey = Data([0x00 as UInt8])

    var body: some View {
        List {
            connectionSection
            publicChannelSection
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

    @ViewBuilder
    private var publicChannelSection: some View {
        Section {
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
    private var contactsSection: some View {
        Section {
            if viewModel.contacts.isEmpty {
                HStack {
                    Image(systemName: "person.2.slash")
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("No contacts yet")
                        .foregroundStyle(MeshTheme.textSecondary)
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
                        viewModel.selectedContact = contact
                        viewModel.markAsRead(contact)
                    } label: {
                        contactRow(contact)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        viewModel.selectedContact?.publicKeyPrefix == contact.publicKeyPrefix
                            && !viewModel.showPublicChannel
                            ? MeshTheme.surfaceLight
                            : MeshTheme.surface
                    )
                    #endif
                }
            }
        } header: {
            Text("Contacts")
                .foregroundStyle(MeshTheme.textSecondary)
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
        if contact.type == .repeater || contact.type == .room {
            RemoteManagementView(
                contact: contact,
                session: viewModel.remoteSession(for: contact)
            )
        } else {
            ChatView(contact: contact)
                .onAppear { viewModel.markAsRead(contact) }
        }
    }

    @ViewBuilder
    private func contactIcon(for contact: Contact) -> some View {
        ZStack {
            Circle()
                .fill(MeshTheme.accentFallback.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: contactIconName(for: contact.type))
                .foregroundStyle(MeshTheme.accentFallback)
        }
    }

    private func contactIconName(for type: ContactType) -> String {
        switch type {
        case .chat: return "person.fill"
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "building.2"
        case .unknown: return "questionmark"
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
}
