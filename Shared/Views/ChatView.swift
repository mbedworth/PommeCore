import SwiftUI
import MeshCoreKit
#if !os(watchOS)
import CoreLocation
#endif

extension Notification.Name {
    static let insertMention = Notification.Name("insertMention")
}

struct ChatView: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(MessageStoreManager.self) private var messageStoreManager
    @State private var messageText = ""
    @State private var showNotes = false
    @State private var showContactDetail = false
    @State private var showNicknameSheet = false
    @State private var nicknameText = ""
    @State private var unreadDividerIndex: Int?
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var showPathEditor = false

    /// Live contact from ViewModel (picks up optimistic path updates).
    private var liveContact: Contact {
        contactStore.contacts.first(where: { $0.publicKey == contact.publicKey }) ?? contact
    }
    @State private var exportURL: URL?
    @State private var showExportSheet = false

    private let maxMessageLength = 160

    private var messages: [Message] {
        messageStoreManager.messages(for: contact)
    }

    private var lastSeenText: String? {
        let c = liveContact
        guard c.lastAdvert > 1_000_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(c.lastAdvert))
        guard Date().timeIntervalSince(date) < 365 * 24 * 60 * 60 else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private var toolbarName: (text: String, font: Font) {
        let fullName = contactStore.displayName(for: contact)
        if fullName.count <= 14 { return (fullName, .headline) }
        if fullName.count <= 18 { return (fullName, .subheadline) }
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        if firstName.count <= 14 { return (firstName, .subheadline) }
        return (firstName, .caption)
    }

    private var routeLabel: String {
        let c = liveContact
        if c.outPathLen == 0 { return "Direct" }
        if c.outPathLen < 0 { return c.outPath.isEmpty ? "Auto" : "Flood" }
        // Lower 6 bits = hop count (upper 2 bits = hash_mode)
        let hops = Int(c.outPathLen) & 0x3F
        return "\(hops) hop\(hops == 1 ? "" : "s")"
    }

    private var routeColor: Color {
        let c = liveContact
        if c.outPathLen == 0 { return MeshTheme.connected }
        if c.outPathLen < 0 { return c.outPath.isEmpty ? MeshTheme.textSecondary : .orange }
        return MeshTheme.accent
    }

    private var displayedMessages: [Message] {
        if searchText.isEmpty { return messages }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MeshTheme.textSecondary)
            TextField("Search messages...", text: $searchText)
                .foregroundStyle(MeshTheme.textPrimary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(MeshTheme.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                searchBar
            }
            messageList
            Divider()
                .overlay(MeshTheme.surfaceLight)
            messageInput
        }
        .background(MeshTheme.background)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle(toolbarName.text)
        .navigationSubtitle(routeLabel)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(toolbarName.text)
                        .font(toolbarName.font)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(routeLabel)
                            .font(.caption2)
                            .foregroundStyle(routeColor)
                        if let lastSeen = lastSeenText {
                            Text("\u{2022}").font(.caption2).foregroundStyle(MeshTheme.textSecondary)
                            Text(lastSeen)
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        nicknameText = contactStore.nickname(for: contact) ?? ""
                        showNicknameSheet = true
                    } label: {
                        Label(contactStore.nickname(for: contact) != nil ? "Edit Nickname" : "Set Nickname", systemImage: "pencil")
                    }
                    Button { showPathEditor = true } label: {
                        Label("Edit Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    Button { showContactDetail = true } label: {
                        Label("Contact Details", systemImage: "info.circle")
                    }
                }
            }
            #endif
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    #if os(macOS)
                    Button {
                        showPathEditor = true
                    } label: {
                        Text(routeLabel)
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                    #endif
                    Button {
                        withAnimation { isSearching.toggle() }
                        if !isSearching { searchText = "" }
                    } label: {
                        Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    #if !os(watchOS)
                    Button {
                        sendLocationAsDM()
                    } label: {
                        Image(systemName: "location.fill")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    #endif
                    Button {
                        showNotes = true
                    } label: {
                        Image(systemName: contactStore.hasNote(for: contact) ? "note.text" : "note.text.badge.plus")
                            .foregroundStyle(MeshTheme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showNotes) {
            ContactNotesSheet(contact: contact)
        }
        .alert("Set Nickname", isPresented: $showNicknameSheet) {
            TextField("Nickname", text: $nicknameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                contactStore.setNickname(nicknameText.trimmingCharacters(in: .whitespaces), for: contact)
            }
        } message: {
            Text("Set a local nickname for \(contact.name.isEmpty ? "this contact" : contact.name). This is only visible to you.")
        }
        .sheet(isPresented: $showContactDetail) {
            ContactDetailSheet(contact: liveContact)
                .frame(minWidth: 360, minHeight: 400)
        }
        .sheet(isPresented: $showPathEditor) {
            ManualPathEditor(contact: liveContact)
        }
        .sheet(isPresented: $showExportSheet) {
            if let url = exportURL {
                #if os(iOS)
                ShareSheetView(activityItems: [url])
                #elseif os(macOS)
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(MeshTheme.connected)
                    Text("Chat exported")
                        .font(.headline)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Copy File Path") {
                        copyToClipboard(url.path)
                        showExportSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Done") { showExportSheet = false }
                }
                .padding(32)
                .frame(minWidth: 300)
                #endif
            } else {
                VStack(spacing: 12) {
                    Text("Export failed")
                        .font(.headline)
                    Button("Done") { showExportSheet = false }
                }
                .padding(24)
            }
        }
        .onAppear {
            if messageText.isEmpty {
                messageText = messageStoreManager.loadDraft(for: contact.publicKeyPrefix)
            }
            DispatchQueue.main.async {
                messageStoreManager.markAsRead(contact)
            }
        }
        .onDisappear {
            messageStoreManager.saveDraft(messageText, for: contact.publicKeyPrefix)
        }
    }


    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    VStack(spacing: 12) {
                        Spacer(minLength: 60)
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 36))
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("No messages yet")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("Send a message to start the conversation.")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LazyVStack(spacing: 4) {
                    if !searchText.isEmpty {
                        Text("\(displayedMessages.count) result\(displayedMessages.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                        if searchText.isEmpty && (index == 0 || isDifferentDay(displayedMessages[index - 1].timestamp, message.timestamp)) {
                            DateSeparator(date: message.timestamp)
                        }
                        if searchText.isEmpty && index == unreadDividerIndex {
                            UnreadDivider()
                        }
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            #if !os(watchOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // User is viewing the chat — new messages are read immediately
                withAnimation { unreadDividerIndex = nil }
                DispatchQueue.main.async {
                    messageStoreManager.markAsRead(contactKey: contact.publicKeyPrefix)
                }
            }
            .onAppear {
                unreadDividerIndex = messageStoreManager.firstUnreadIndex(in: messages, for: contact.publicKeyPrefix)
                // Delay scroll to let LazyVStack lay out content
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let idx = unreadDividerIndex, idx < messages.count {
                        proxy.scrollTo(messages[idx].id, anchor: .center)
                    } else if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // Clear the divider after user has had time to see it
                if unreadDividerIndex != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation { unreadDividerIndex = nil }
                    }
                }
            }
        }
    }

    private var messageInput: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                TextField("Type a message...", text: $messageText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(MeshTheme.surfaceLight)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(MeshTheme.textPrimary)
                    .onChange(of: messageText) { _, newValue in
                        if newValue.count > maxMessageLength {
                            messageText = String(newValue.prefix(maxMessageLength))
                        }
                    }
                    #if !os(watchOS)
                    .onSubmit { send() }
                    #endif

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? MeshTheme.textSecondary
                                : MeshTheme.accent
                        )
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)

            if !messageText.isEmpty {
                HStack {
                    Spacer()
                    Text("\(messageText.count)/\(maxMessageLength)")
                        .font(.caption2)
                        .foregroundStyle(
                            messageText.count > maxMessageLength - 10
                                ? Color.orange
                                : MeshTheme.textSecondary
                        )
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(MeshTheme.surface)
    }

    private func send() {
        messageStoreManager.sendTextMessage(messageText, to: contact)
        messageStoreManager.playHapticFeedback()
        messageText = ""
        messageStoreManager.saveDraft("", for: contact.publicKeyPrefix)
    }

    #if !os(watchOS)
    private func sendLocationAsDM() {
        let locManager = CLLocationManager()
        guard let location = locManager.location else {
            DebugLogger.shared.log("LOCATION: unavailable for send", level: .warning)
            return
        }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let (fLat, fLon) = MeshCoreViewModel.fudgeLocation(lat: lat, lon: lon)
        let text = "\u{1F4CD} \(String(format: "%.6f", fLat)), \(String(format: "%.6f", fLon))"
        messageStoreManager.sendTextMessage(text, to: contact)
        messageStoreManager.playHapticFeedback()
        DebugLogger.shared.log("LOCATION: sent to \(contact.name)", level: .tx)
    }
    #endif
}

// MARK: - Channel Chat View

struct ChannelChatView: View {
    let channelIndex: UInt8
    let channelName: String
    @Environment(ContactStore.self) private var contactStore
    @Environment(ChannelStore.self) private var channelStore
    @Environment(MessageStoreManager.self) private var messageStoreManager
    @State private var messageText = ""
    @State private var unreadDividerIndex: Int?
    @State private var mentionQuery: String?
    @State private var notifyMode: String = "all"
    @State private var showChannelDetail = false

    private let maxMessageLength = 160

    private var channelKey: Data { Data([channelIndex]) }

    private var messages: [Message] {
        messageStoreManager.messagesByContact[channelKey] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
                .overlay(MeshTheme.surfaceLight)
            messageInput
        }
        .background(MeshTheme.background)
        .navigationTitle(channelName)
        #if !os(watchOS)
        .sheet(isPresented: $showChannelDetail) {
            ChannelDetailSheet(channelIndex: channelIndex, channelName: channelName, notifyMode: $notifyMode)
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                Button { showChannelDetail = true } label: {
                    Text(channelName)
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
            #endif
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        sendLocationToChannel()
                    } label: {
                        Image(systemName: "location.fill")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    Button {
                        // Cycle notification mode: all → mentions → muted → all
                        let next: String
                        switch notifyMode {
                        case "all": next = "mentions"
                        case "mentions": next = "muted"
                        default: next = "all"
                        }
                        notifyMode = next
                        if let mode = ChannelStore.ChannelNotifyMode(rawValue: next) {
                            channelStore.setChannelNotifyMode(mode, for: channelName)
                        }
                    } label: {
                        Image(systemName: notifyMode == "muted" ? "bell.slash" : notifyMode == "mentions" ? "at" : "bell.fill")
                            .foregroundStyle(MeshTheme.accent)
                    }
                }
            }
        }
        #endif
        .onAppear {
            notifyMode = channelStore.channelNotifyMode(for: channelName).rawValue
            if messageText.isEmpty {
                messageText = messageStoreManager.loadDraft(for: channelKey)
            }
            DispatchQueue.main.async {
                messageStoreManager.markAsRead(contactKey: channelKey)
            }
        }
        .onDisappear {
            messageStoreManager.saveDraft(messageText, for: channelKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertMention)) { notification in
            if let sender = notification.object as? String {
                messageText += "@\(sender) "
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    VStack(spacing: 12) {
                        Spacer(minLength: 60)
                        Image(systemName: "number.square")
                            .font(.system(size: 36))
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("No messages yet")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("Messages sent to this channel will appear here.")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LazyVStack(spacing: 4) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || isDifferentDay(messages[index - 1].timestamp, message.timestamp) {
                            DateSeparator(date: message.timestamp)
                        }
                        if index == unreadDividerIndex {
                            UnreadDivider()
                        }
                        ChannelMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            #if !os(watchOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // User is viewing the chat — new messages are read immediately
                withAnimation { unreadDividerIndex = nil }
                DispatchQueue.main.async {
                    messageStoreManager.markAsRead(contactKey: channelKey)
                }
            }
            .onAppear {
                unreadDividerIndex = messageStoreManager.firstUnreadIndex(in: messages, for: channelKey)
                // Delay scroll to let LazyVStack lay out content
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let idx = unreadDividerIndex, idx < messages.count {
                        proxy.scrollTo(messages[idx].id, anchor: .center)
                    } else if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // Clear the divider after user has had time to see it
                if unreadDividerIndex != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation { unreadDividerIndex = nil }
                    }
                }
            }
        }
    }

    private var mentionCandidates: [Contact] {
        let chatContacts = contactStore.contacts.filter { $0.type == .chat }
        guard let query = mentionQuery, !query.isEmpty else { return chatContacts }
        return chatContacts.filter {
            contactStore.displayName(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private var messageInput: some View {
        VStack(spacing: 0) {
            if mentionQuery != nil && !mentionCandidates.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(mentionCandidates.prefix(5)) { contact in
                            Button {
                                insertMention(contact)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.fill")
                                        .foregroundStyle(MeshTheme.accent)
                                        .font(.caption)
                                    Text(contactStore.displayName(for: contact))
                                        .foregroundStyle(MeshTheme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(MeshTheme.surface)
            }

            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    TextField("Type a message...", text: $messageText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(MeshTheme.textPrimary)
                        .onChange(of: messageText) { _, newValue in
                            if newValue.count > maxMessageLength {
                                messageText = String(newValue.prefix(maxMessageLength))
                            }
                            mentionQuery = detectMentionQuery(in: newValue)
                        }
                        #if !os(watchOS)
                        .onSubmit { send() }
                        #endif

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(
                                messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? MeshTheme.textSecondary
                                    : MeshTheme.accent
                            )
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12)

                if !messageText.isEmpty {
                    HStack {
                        Spacer()
                        Text("\(messageText.count)/\(maxMessageLength)")
                            .font(.caption2)
                            .foregroundStyle(
                                messageText.count > maxMessageLength - 10
                                    ? Color.orange
                                    : MeshTheme.textSecondary
                            )
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
            .background(MeshTheme.surface)
        }
    }

    /// Detect an in-progress @mention at end of text.
    private func detectMentionQuery(in text: String) -> String? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        let query = String(text[text.index(after: atIndex)...])
        // Don't trigger if there's a space after @ (completed mention)
        if query.contains(" ") { return nil }
        return query
    }

    /// Insert the selected contact's name at the current @ position.
    private func insertMention(_ contact: Contact) {
        guard let atIndex = messageText.lastIndex(of: "@") else { return }
        let name = contactStore.displayName(for: contact)
        messageText = String(messageText[messageText.startIndex...atIndex]) + name + " "
        mentionQuery = nil
    }

    private func send() {
        messageStoreManager.sendChannelMessage(messageText, channelIndex: channelIndex)
        messageStoreManager.playHapticFeedback()
        messageText = ""
        mentionQuery = nil
        messageStoreManager.saveDraft("", for: channelKey)
    }

    private func sendLocationToChannel() {
        let locManager = CLLocationManager()
        guard let location = locManager.location else {
            DebugLogger.shared.log("LOCATION: unavailable for channel send", level: .warning)
            return
        }
        let (fLat, fLon) = MeshCoreViewModel.fudgeLocation(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        let text = "\u{1F4CD} \(String(format: "%.6f", fLat)), \(String(format: "%.6f", fLon))"
        messageStoreManager.sendChannelMessage(text, channelIndex: channelIndex)
        messageStoreManager.playHapticFeedback()
        DebugLogger.shared.log("LOCATION: sent to channel \(channelIndex)", level: .tx)
    }
}

// MARK: - Room Chat View

/// Chat view for room servers — requires login, shows room messages, has gear icon for management.
struct RoomChatView: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(MessageStoreManager.self) private var messageStoreManager
    @ObservedObject var session: RemoteDeviceSession
    @State private var messageText = ""
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var showManagement = false

    private let maxMessageLength = 160

    /// Accent for remote management icon.
    private var remoteAccent: Color { MeshTheme.remoteRoom }

    private var messages: [Message] {
        messageStoreManager.messages(for: contact)
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var permission: RemotePermission {
        if case .loggedIn(let p) = session.loginState { return p }
        return .guest
    }

    private var loginStatusText: String {
        switch session.loginState {
        case .loggedIn(let permission): permission.displayName
        case .loggingIn: "Logging in..."
        case .loginFailed: "Login failed"
        case .notLoggedIn: "Not logged in"
        }
    }

    private var statusBarColor: Color {
        switch permission {
        case .guest: return MeshTheme.textSecondary
        case .readOnly: return .yellow
        case .readWrite: return .blue
        case .admin: return MeshTheme.connected
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoggedIn {
                // Status bar with logout button
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(statusBarColor)
                    Text(loginStatusText)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Spacer()
                    Button {
                        showManagement = false
                        remoteSessionManager.logoutFromRemoteDevice(contact)
                        password = ""
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.caption2)
                            Text("Logout")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(MeshTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(MeshTheme.surface)

                messageList
                Divider()
                    .overlay(MeshTheme.surfaceLight)
                if permission.canPost {
                    roomMessageInput
                } else {
                    readOnlyInputBar
                }
            } else {
                roomLoginPrompt
            }
        }
        .background(MeshTheme.background)
        .navigationTitle(contactStore.displayName(for: contact))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isLoggedIn, permission.canRead {
                    #if os(watchOS)
                    NavigationLink {
                        RemoteManagementView(
                            contact: contact,
                            session: session
                        )
                        .environmentObject(viewModel)
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(remoteAccent)
                    }
                    #else
                    Button {
                        showManagement = true
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(remoteAccent)
                    }
                    .help("Remote Management — \(contactStore.displayName(for: contact))")
                    #endif
                }
            }
        }
        #if !os(watchOS)
        .sheet(isPresented: $showManagement) {
            NavigationStack {
                RemoteManagementView(
                    contact: contact,
                    session: session
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showManagement = false }
                    }
                }
            }
            .meshTheme()
            .frame(minWidth: 400, minHeight: 500)
        }
        #endif
        .onAppear {
            messageStoreManager.markAsRead(contact)
        }
        // Dismiss management sheet if logged out while it's open
        .onChange(of: isLoggedIn) { _, loggedIn in
            if !loggedIn {
                showManagement = false
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || isDifferentDay(messages[index - 1].timestamp, message.timestamp) {
                            DateSeparator(date: message.timestamp)
                        }
                        RoomMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            #if !os(watchOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var roomMessageInput: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                TextField("Type a message...", text: $messageText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(MeshTheme.surfaceLight)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(MeshTheme.textPrimary)
                    .onChange(of: messageText) { _, newValue in
                        if newValue.count > maxMessageLength {
                            messageText = String(newValue.prefix(maxMessageLength))
                        }
                    }
                    #if !os(watchOS)
                    .onSubmit { sendRoomMessage() }
                    #endif

                Button(action: sendRoomMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? MeshTheme.textSecondary
                                : MeshTheme.accent
                        )
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)

            if !messageText.isEmpty {
                HStack {
                    Spacer()
                    Text("\(messageText.count)/\(maxMessageLength)")
                        .font(.caption2)
                        .foregroundStyle(
                            messageText.count > maxMessageLength - 10
                                ? Color.orange
                                : MeshTheme.textSecondary
                        )
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(MeshTheme.surface)
    }

    private var readOnlyInputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(MeshTheme.textSecondary)
            Text("Read-only access \u{2014} posting not available")
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(MeshTheme.surface)
    }

    private var roomLoginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundStyle(MeshTheme.textSecondary)
                Text("Login Required")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MeshTheme.textPrimary)
                Text("Enter the room server password to view and post messages.")
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "lock")
                        .foregroundStyle(MeshTheme.accent)
                        .frame(width: 24)
                    #if os(watchOS)
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(MeshTextFieldStyle())
                        .onSubmit { login() }
                    #endif
                }
                .padding(.horizontal, 32)

                Text("Passwords are case-sensitive, max 15 characters.")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)

                #if !os(watchOS)
                Toggle("Remember Password", isOn: $rememberPassword)
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .padding(.horizontal, 32)
                #endif

                if isLoggingIn {
                    HStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(MeshTheme.textSecondary)
                        Text("Logging in...")
                            .foregroundStyle(MeshTheme.textSecondary)
                        Button("Cancel") {
                            remoteSessionManager.cancelLogin(for: contact)
                        }
                        .foregroundStyle(.red)
                    }
                } else {
                    Button(action: login) {
                        HStack {
                            Image(systemName: "arrow.right.circle")
                            Text("Login")
                        }
                        .frame(maxWidth: 200)
                        .padding(.vertical, 10)
                        .background(password.isEmpty ? MeshTheme.surfaceLight : MeshTheme.interactiveGreen)
                        .foregroundStyle(password.isEmpty ? MeshTheme.textSecondary : MeshTheme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(password.isEmpty)
                }

                if case .loginFailed(let msg) = session.loginState {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if KeychainManager.hasPassword(forDevice: contact.publicKey) {
                    Button(role: .destructive) {
                        KeychainManager.deleteAllPasswords(forDevice: contact.publicKey)
                        password = ""
                    } label: {
                        Label("Forget Saved Password", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .onAppear {
            // Auto-fill saved password
            if let saved = KeychainManager.getSavedPassword(forDevice: contact.publicKey) {
                password = saved
            }
        }
    }

    private var isLoggingIn: Bool {
        if case .loggingIn = session.loginState { return true }
        return false
    }

    private func login() {
        guard !password.isEmpty else { return }
        remoteSessionManager.loginToRemoteDevice(contact, password: password, remember: rememberPassword)
    }

    private func sendRoomMessage() {
        messageStoreManager.sendRoomMessage(messageText, to: contact)
        messageStoreManager.playHapticFeedback()
        messageText = ""
    }
}

/// Message bubble for room chat — shows sender name for incoming messages.
struct RoomMessageBubble: View {
    let message: Message
    @Environment(ContactStore.self) private var contactStore
    @Environment(MessageStoreManager.self) private var messageStoreManager

    /// Try to extract sender name from room server message prefix.
    /// Room servers often prefix messages with "SenderName: actual message"
    private var senderAndText: (sender: String?, text: String) {
        if !message.isOutgoing {
            let text = message.text
            // Look for "Name: message" pattern (common room server format)
            if let colonRange = text.range(of: ": ") {
                let potentialName = String(text[text.startIndex..<colonRange.lowerBound])
                // Reasonable name: 1-30 chars, no newlines
                if potentialName.count >= 1 && potentialName.count <= 30
                    && !potentialName.contains("\n") {
                    let remainder = String(text[colonRange.upperBound...])
                    return (potentialName, remainder)
                }
            }
            // Also check senderName field from protocol
            if let name = message.senderName, !name.isEmpty {
                return (name, text)
            }
        }
        return (nil, message.text)
    }

    var body: some View {
        let parsed = senderAndText
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing, let rawSender = parsed.sender {
                    let sender = contactStore.channelSenderDisplayName(rawSender)
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MeshTheme.accent)
                        .padding(.horizontal, 4)
                }

                linkifyMeshcoreURLs(parsed.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(MeshTheme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    if message.isOutgoing {
                        switch message.status {
                        case .failed:
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.disconnected)
                                Text("Not delivered")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.disconnected)
                            }
                        case .retrying:
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("Retrying (attempt \(message.attempt + 1))...")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        case .flooding:
                            HStack(spacing: 2) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("Flooding...")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        case .delivered:
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.accent)
                            }
                        default:
                            Image(systemName: message.status == .sending ? "clock" : "checkmark")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }

                    if !message.isOutgoing {
                        if let hops = message.hops {
                            Text("\u{2022}")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            if hops == 0 || hops == 0xFF {
                                Text("direct")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            } else {
                                Text("\(hops) hop\(hops == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                        }
                        if let snr = message.snr {
                            Text("\u{2022}")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            Text(String(format: "%.1f dB", Double(snr) / 4.0))
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 4)

                if message.status == .failed {
                    Button {
                        messageStoreManager.retryMessage(message)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Tap to retry")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MeshTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    copyToClipboard(parsed.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) {
                    messageStoreManager.deleteMessage(message, in: message.contactKeyHash)
                } label: {
                    Label("Delete Message", systemImage: "trash")
                }
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }
}

// MARK: - Repeater Login View

/// Login gate for repeaters — shows management screen after login.
struct RepeaterLoginView: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @ObservedObject var session: RemoteDeviceSession
    @State private var password = ""
    @State private var rememberPassword = true

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var isLoggingIn: Bool {
        if case .loggingIn = session.loginState { return true }
        return false
    }

    var body: some View {
        if isLoggedIn {
            RemoteManagementView(
                contact: contact,
                session: session
            )
        } else {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("Repeater Login")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(MeshTheme.textPrimary)
                    Text("Enter the admin password to manage this repeater.")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "lock")
                            .foregroundStyle(MeshTheme.accent)
                            .frame(width: 24)
                        #if os(watchOS)
                        SecureField("Password", text: $password)
                            .foregroundStyle(MeshTheme.textPrimary)
                        #else
                        SecureField("Password", text: $password)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .textFieldStyle(MeshTextFieldStyle())
                            .onSubmit { login() }
                        #endif
                    }
                    .padding(.horizontal, 32)

                    Text("Passwords are case-sensitive, max 15 characters.")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    #if !os(watchOS)
                    Toggle("Remember Password", isOn: $rememberPassword)
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .padding(.horizontal, 32)
                    #endif

                    if isLoggingIn {
                        HStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(MeshTheme.textSecondary)
                            Text("Logging in...")
                                .foregroundStyle(MeshTheme.textSecondary)
                            Button("Cancel") {
                                remoteSessionManager.cancelLogin(for: contact)
                            }
                            .foregroundStyle(.red)
                        }
                    } else {
                        Button(action: login) {
                            HStack {
                                Image(systemName: "arrow.right.circle")
                                Text("Login")
                            }
                            .frame(maxWidth: 200)
                            .padding(.vertical, 10)
                            .background(password.isEmpty ? MeshTheme.surfaceLight : MeshTheme.interactiveGreen)
                            .foregroundStyle(password.isEmpty ? MeshTheme.textSecondary : MeshTheme.textOnAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(password.isEmpty)
                    }

                    if case .loginFailed(let msg) = session.loginState {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if KeychainManager.hasPassword(forDevice: contact.publicKey) {
                        Button(role: .destructive) {
                            KeychainManager.deleteAllPasswords(forDevice: contact.publicKey)
                            password = ""
                        } label: {
                            Label("Forget Saved Password", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .background(MeshTheme.background)
            .navigationTitle(contactStore.displayName(for: contact))
            .onAppear {
                if let saved = KeychainManager.getSavedPassword(forDevice: contact.publicKey) {
                    password = saved
                }
            }
        }
    }

    private func login() {
        guard !password.isEmpty else { return }
        remoteSessionManager.loginToRemoteDevice(contact, password: password, remember: rememberPassword)
    }
}

// MARK: - Message Bubbles

struct MessageBubble: View {
    let message: Message
    @Environment(MessageStoreManager.self) private var messageStoreManager

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                linkifyMeshcoreURLs(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(MeshTheme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    if message.isOutgoing {
                        deliveryIndicator
                    }

                    if !message.isOutgoing {
                        if let hops = message.hops {
                            Text("\u{2022}")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            if hops == 0 || hops == 0xFF {
                                Text("direct")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            } else {
                                Text("\(hops) hop\(hops == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                        }
                        if let snr = message.snr {
                            Text("\u{2022}")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            Text(String(format: "%.1f dB", Double(snr) / 4.0))
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }

                    if message.isSigned {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption2)
                            Text("Verified")
                                .font(.caption2)
                        }
                        .foregroundStyle(MeshTheme.connected)
                    }
                }
                .padding(.horizontal, 4)

                if message.status == .failed {
                    Button {
                        messageStoreManager.retryMessage(message)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Tap to retry")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MeshTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    copyToClipboard(message.text)
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                if message.isOutgoing && message.status == .failed {
                    Button {
                        messageStoreManager.retryMessage(message)
                    } label: {
                        Label("Retry Send", systemImage: "arrow.clockwise")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    messageStoreManager.deleteMessage(message, in: message.contactKeyHash)
                } label: {
                    Label("Delete Message", systemImage: "trash")
                }
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var deliveryIndicator: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
        case .sent, .repeated:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
        case .retrying:
            HStack(spacing: 2) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Retrying (\(message.attempt + 1)/3)...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .flooding:
            HStack(spacing: 2) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Flooding...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .delivered:
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.accent)
                if let rtt = message.roundTripMs, rtt > 0 {
                    Text("\u{2022}")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.accent)
                    Text(String(format: "%.1fs", Double(rtt) / 1000.0))
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.accent)
                }
            }
        case .failed:
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.disconnected)
                Text("Not delivered")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.disconnected)
            }
        }
    }
}

struct ChannelMessageBubble: View {
    let message: Message
    @Environment(ContactStore.self) private var contactStore
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(MessageStoreManager.self) private var messageStoreManager

    private var highlightedText: Text {
        if message.text.contains("meshcore://") {
            return linkifyMeshcoreURLs(message.text)
        }
        return highlightMentions(in: message.text, myName: deviceConfig.deviceName)
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing, let sender = message.senderName, !sender.isEmpty {
                    Text(contactStore.channelSenderDisplayName(sender))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MeshTheme.accent)
                        .padding(.horizontal, 4)
                }

                highlightedText
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(MeshTheme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    if message.isOutgoing {
                        switch message.status {
                        case .sending:
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        case .repeated:
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.accent)
                                Text("Repeated")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.accent)
                            }
                        default:
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }

                    if !message.isOutgoing {
                        if let hops = message.hops {
                            Text("\u{2022}")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            if hops == 0 || hops == 0xFF {
                                Text("direct")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            } else {
                                Text("\(hops) hop\(hops == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                        }
                        if let snr = message.snr {
                            Text("\u{2022}")
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                            Text(String(format: "%.1f dB", Double(snr) / 4.0))
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                    }

                    if message.isSigned {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption2)
                            Text("Verified")
                                .font(.caption2)
                        }
                        .foregroundStyle(MeshTheme.connected)
                    }
                }
                .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    copyToClipboard(message.text)
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                if !message.isOutgoing, let sender = message.senderName, !sender.isEmpty {
                    Button {
                        NotificationCenter.default.post(name: .insertMention, object: sender)
                    } label: {
                        Label("@\(sender)", systemImage: "at")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    messageStoreManager.deleteMessage(message, in: message.contactKeyHash)
                } label: {
                    Label("Delete Message", systemImage: "trash")
                }
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }
}

// MARK: - Date Separator

struct DateSeparator: View {
    let date: Date

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(formattedDate(date))
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
                .padding(.horizontal, 8)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

/// Highlight @mentions in message text. Own name gets a stronger highlight.
private func highlightMentions(in text: String, myName: String) -> Text {
    let pattern = "@(\\w+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return Text(text)
    }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    guard !matches.isEmpty else { return Text(text) }

    var result = Text("")
    var lastEnd = 0
    for match in matches {
        let range = match.range
        // Text before the match
        if range.location > lastEnd {
            let prefix = nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            result = result + Text(prefix)
        }
        let mention = nsText.substring(with: range)
        let mentionName = nsText.substring(with: match.range(at: 1))
        let isMe = mentionName.localizedCaseInsensitiveCompare(myName) == .orderedSame
        result = result + Text(mention)
            .foregroundColor(isMe ? .orange : MeshTheme.accent)
            .bold()
        lastEnd = range.location + range.length
    }
    if lastEnd < nsText.length {
        result = result + Text(nsText.substring(from: lastEnd))
    }
    return result
}

#if os(iOS)
struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

/// Make meshcore:// URLs in text tappable as links.
private func linkifyMeshcoreURLs(_ text: String) -> Text {
    // Check for location pin: "📍 lat, lon"
    if text.contains("\u{1F4CD}"),
       let regex = try? NSRegularExpression(pattern: "\u{1F4CD}\\s*(-?\\d+\\.\\d+),\\s*(-?\\d+\\.\\d+)"),
       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let latRange = Range(match.range(at: 1), in: text),
       let lonRange = Range(match.range(at: 2), in: text),
       let lat = Double(text[latRange]),
       let lon = Double(text[lonRange]),
       let mapsURL = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=Shared%20Location") {
        var attr = AttributedString(text)
        if let fullRange = attr.range(of: String(text[text.range(of: "\u{1F4CD}")!.lowerBound...])) {
            attr[fullRange].link = mapsURL
            attr[fullRange].foregroundColor = .accentColor
        }
        return Text(attr)
    }

    // Check for meshcore:// URL
    guard let range = text.range(of: "meshcore://", options: .caseInsensitive) else {
        return Text(text)
    }
    var endIdx = range.upperBound
    while endIdx < text.endIndex && !text[endIdx].isWhitespace {
        endIdx = text.index(after: endIdx)
    }
    let before = String(text[text.startIndex..<range.lowerBound])
    let urlString = String(text[range.lowerBound..<endIdx])
    let after = String(text[endIdx...])

    if let url = URL(string: urlString) {
        var linked = AttributedString(urlString)
        linked.link = url
        linked.foregroundColor = .accentColor
        return Text(before) + Text(linked) + Text(after)
    }
    return Text(text)
}

struct UnreadDivider: View {
    var body: some View {
        HStack {
            VStack { Divider().background(MeshTheme.accent) }
            Text("New Messages")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MeshTheme.accent)
                .padding(.horizontal, 8)
            VStack { Divider().background(MeshTheme.accent) }
        }
        .padding(.vertical, 4)
    }
}

/// Returns true if two dates fall on different calendar days.
private func isDifferentDay(_ a: Date, _ b: Date) -> Bool {
    !Calendar.current.isDate(a, inSameDayAs: b)
}

// MARK: - Contact Notes Sheet

struct ContactNotesSheet: View {
    let contact: Contact
    @Environment(ContactStore.self) private var contactStore
    @Environment(\.dismiss) private var dismiss
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Notes") {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 120)
                        .font(.body)
                }
            }
            .navigationTitle("Notes for \(contactStore.displayName(for: contact))")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        contactStore.setNote(noteText, for: contact)
                        dismiss()
                    }
                }
            }
            .onAppear {
                noteText = contactStore.note(for: contact)
            }
        }
    }
}

// MARK: - Channel Detail Sheet

struct ChannelDetailSheet: View {
    let channelIndex: UInt8
    let channelName: String
    @Binding var notifyMode: String
    @Environment(ChannelStore.self) private var channelStore
    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveConfirm = false

    private var channel: MeshChannel? {
        channelStore.channels.first { $0.index == channelIndex }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Channel Info") {
                    LabeledContent("Name", value: channelName)
                    LabeledContent("Index", value: "\(channelIndex)")
                    if let ch = channel {
                        LabeledContent("Type", value: ch.channelType == .publicChannel ? "Public" : ch.channelType == .hashChannel ? "Hashtag" : "Private")
                        LabeledContent("Secret", value: ch.secret != nil ? "Set (\(ch.secret!.count) bytes)" : "None")
                    }
                }

                Section("Notifications") {
                    Picker("Mode", selection: $notifyMode) {
                        Text("All").tag("all")
                        Text("Mentions").tag("mentions")
                        Text("Muted").tag("muted")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: notifyMode) { _, mode in
                        if let notifyMode = ChannelStore.ChannelNotifyMode(rawValue: mode) {
                            channelStore.setChannelNotifyMode(notifyMode, for: channelName)
                        }
                    }
                }

                if channelIndex > 0 {
                    Section {
                        Button(role: .destructive) {
                            showRemoveConfirm = true
                        } label: {
                            Label("Leave Channel", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle(channelName)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Leave Channel?", isPresented: $showRemoveConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Leave", role: .destructive) {
                    channelStore.setChannel(index: channelIndex, name: "", secret: nil)
                    dismiss()
                }
            } message: {
                Text("Messages in this channel will be deleted from your device.")
            }
        }
        .meshTheme()
    }
}
