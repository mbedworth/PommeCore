import SwiftUI
import MeshCoreKit

struct ChatView: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var messageText = ""
    @State private var showNotes = false
    @State private var unreadDividerIndex: Int?
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var exportURL: URL?
    @State private var showExportSheet = false

    private let maxMessageLength = 160

    private var messages: [Message] {
        viewModel.messages(for: contact)
    }

    private var routeLabel: String {
        if contact.outPathLen == 0 { return "Direct" }
        if contact.outPathLen < 0 { return "Flood" }
        return "\(contact.outPathLen) hop\(contact.outPathLen == 1 ? "" : "s")"
    }

    private var routeColor: Color {
        if contact.outPathLen == 0 { return MeshTheme.connected }
        if contact.outPathLen < 0 { return .orange }
        return MeshTheme.textSecondary
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
        .navigationTitle(viewModel.displayName(for: contact))
        #if os(macOS)
        .navigationSubtitle(routeLabel)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Text(routeLabel)
                        .font(.caption2)
                        .foregroundStyle(routeColor)
                    Button {
                        withAnimation { isSearching.toggle() }
                        if !isSearching { searchText = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(isSearching ? MeshTheme.accent : MeshTheme.textSecondary)
                    }
                    Button {
                        exportURL = exportChatHistory()
                        showExportSheet = exportURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    Button {
                        showNotes = true
                    } label: {
                        Image(systemName: viewModel.hasNote(for: contact) ? "note.text" : "note.text.badge.plus")
                            .foregroundStyle(MeshTheme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showNotes) {
            ContactNotesSheet(contact: contact)
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
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
            viewModel.markAsRead(contact)
            if messageText.isEmpty {
                messageText = viewModel.loadDraft(for: contact.publicKeyPrefix)
            }
        }
        .onDisappear {
            viewModel.saveDraft(messageText, for: contact.publicKeyPrefix)
        }
    }

    private func exportChatHistory() -> URL? {
        let name = viewModel.displayName(for: contact)
        var text = "Chat with \(name)\n"
        text += "Exported: \(Date().formatted())\n"
        text += String(repeating: "\u{2500}", count: 40) + "\n\n"

        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .medium

        for message in messages {
            let sender = message.isOutgoing ? "You" : name
            let time = fmt.string(from: message.timestamp)
            text += "[\(time)] \(sender): \(message.text)\n"
        }

        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeshCore-Chat-\(safeName).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
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
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                unreadDividerIndex = viewModel.firstUnreadIndex(in: messages, for: contact.publicKeyPrefix)
                if let idx = unreadDividerIndex, idx < messages.count {
                    proxy.scrollTo(messages[idx].id, anchor: .center)
                } else if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
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
                    .onChange(of: messageText) { newValue in
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
        viewModel.sendTextMessage(messageText, to: contact)
        viewModel.playHapticFeedback()
        messageText = ""
        viewModel.saveDraft("", for: contact.publicKeyPrefix)
    }
}

// MARK: - Channel Chat View

struct ChannelChatView: View {
    let channelIndex: UInt8
    let channelName: String
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var messageText = ""
    @State private var unreadDividerIndex: Int?
    @State private var mentionQuery: String?

    private let maxMessageLength = 160

    private var channelKey: Data { Data([channelIndex]) }

    private var messages: [Message] {
        viewModel.messagesByContact[channelKey] ?? []
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
        .onAppear {
            // Store last-read timestamp for unread divider (iCloud synced)
            let lastReadKey = "lastRead.\(channelKey.map { String(format: "%02x", $0) }.joined())"
            NSUbiquitousKeyValueStore.default.set(Date().timeIntervalSince1970, forKey: lastReadKey)
            NSUbiquitousKeyValueStore.default.synchronize()
            viewModel.unreadCounts[channelKey] = 0
            if messageText.isEmpty {
                messageText = viewModel.loadDraft(for: channelKey)
            }
        }
        .onDisappear {
            viewModel.saveDraft(messageText, for: channelKey)
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
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                unreadDividerIndex = viewModel.firstUnreadIndex(in: messages, for: channelKey)
                if let idx = unreadDividerIndex, idx < messages.count {
                    proxy.scrollTo(messages[idx].id, anchor: .center)
                } else if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var mentionCandidates: [Contact] {
        let chatContacts = viewModel.contacts.filter { $0.type == .chat }
        guard let query = mentionQuery, !query.isEmpty else { return chatContacts }
        return chatContacts.filter {
            viewModel.displayName(for: $0).localizedCaseInsensitiveContains(query)
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
                                    Text(viewModel.displayName(for: contact))
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
                        .onChange(of: messageText) { newValue in
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
        let name = viewModel.displayName(for: contact)
        messageText = String(messageText[messageText.startIndex...atIndex]) + name + " "
        mentionQuery = nil
    }

    private func send() {
        viewModel.sendChannelMessage(messageText, channelIndex: channelIndex)
        viewModel.playHapticFeedback()
        messageText = ""
        mentionQuery = nil
        viewModel.saveDraft("", for: channelKey)
    }
}

// MARK: - Room Chat View

/// Chat view for room servers — requires login, shows room messages, has gear icon for management.
struct RoomChatView: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @ObservedObject var session: RemoteDeviceSession
    @State private var messageText = ""
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var showManagement = false

    private let maxMessageLength = 160

    /// Accent for remote management icon.
    private var remoteAccent: Color { MeshTheme.remoteRoom }

    private var messages: [Message] {
        viewModel.messages(for: contact)
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
                        viewModel.logoutFromRemoteDevice(contact)
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
        .navigationTitle(viewModel.displayName(for: contact))
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
                    .help("Remote Management — \(viewModel.displayName(for: contact))")
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
                .environmentObject(viewModel)
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
            viewModel.markAsRead(contact)
        }
        // Dismiss management sheet if logged out while it's open
        .onChange(of: isLoggedIn) { loggedIn in
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
            .onChange(of: messages.count) { _ in
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
                    .onChange(of: messageText) { newValue in
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

                Button(action: login) {
                    HStack {
                        if case .loggingIn = session.loginState {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(MeshTheme.textOnAccent)
                            Text("Logging in...")
                        } else {
                            Image(systemName: "arrow.right.circle")
                            Text("Login")
                        }
                    }
                    .frame(maxWidth: 200)
                    .padding(.vertical, 10)
                    .background(password.isEmpty ? MeshTheme.surfaceLight : MeshTheme.interactiveGreen)
                    .foregroundStyle(password.isEmpty ? MeshTheme.textSecondary : MeshTheme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(password.isEmpty || isLoggingIn)

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
        viewModel.loginToRemoteDevice(contact, password: password, remember: rememberPassword)
    }

    private func sendRoomMessage() {
        viewModel.sendRoomMessage(messageText, to: contact)
        viewModel.playHapticFeedback()
        messageText = ""
    }
}

/// Message bubble for room chat — shows sender name for incoming messages.
struct RoomMessageBubble: View {
    let message: Message
    @EnvironmentObject var viewModel: MeshCoreViewModel

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
                if !message.isOutgoing, let sender = parsed.sender {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MeshTheme.accent)
                        .padding(.horizontal, 4)
                }

                Text(parsed.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(MeshTheme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parsed.text, forType: .string)
                            #elseif !os(watchOS)
                            UIPasteboard.general.string = parsed.text
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

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
                        viewModel.retryMessage(message)
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

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }
}

// MARK: - Repeater Login View

/// Login gate for repeaters — shows management screen after login.
struct RepeaterLoginView: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
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

                    Button(action: login) {
                        HStack {
                            if isLoggingIn {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(MeshTheme.textOnAccent)
                                Text("Logging in...")
                            } else {
                                Image(systemName: "arrow.right.circle")
                                Text("Login")
                            }
                        }
                        .frame(maxWidth: 200)
                        .padding(.vertical, 10)
                        .background(password.isEmpty ? MeshTheme.surfaceLight : MeshTheme.interactiveGreen)
                        .foregroundStyle(password.isEmpty ? MeshTheme.textSecondary : MeshTheme.textOnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(password.isEmpty || isLoggingIn)

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
            .navigationTitle(viewModel.displayName(for: contact))
            .onAppear {
                if let saved = KeychainManager.getSavedPassword(forDevice: contact.publicKey) {
                    password = saved
                }
            }
        }
    }

    private func login() {
        guard !password.isEmpty else { return }
        viewModel.loginToRemoteDevice(contact, password: password, remember: rememberPassword)
    }
}

// MARK: - Message Bubbles

struct MessageBubble: View {
    let message: Message
    @EnvironmentObject var viewModel: MeshCoreViewModel

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(MeshTheme.textOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            #elseif !os(watchOS)
                            UIPasteboard.general.string = message.text
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

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
                        viewModel.retryMessage(message)
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
    @EnvironmentObject var viewModel: MeshCoreViewModel

    private var highlightedText: Text {
        highlightMentions(in: message.text, myName: viewModel.deviceConfig.deviceName)
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing, let sender = message.senderName, !sender.isEmpty {
                    Text(sender)
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
                    .contextMenu {
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            #elseif !os(watchOS)
                            UIPasteboard.general.string = message.text
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

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
    @EnvironmentObject var viewModel: MeshCoreViewModel
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
            .navigationTitle("Notes for \(viewModel.displayName(for: contact))")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.setNote(noteText, for: contact)
                        dismiss()
                    }
                }
            }
            .onAppear {
                noteText = viewModel.note(for: contact)
            }
        }
    }
}
