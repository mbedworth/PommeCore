import SwiftUI
import MeshCoreKit

struct ChatView: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var messageText = ""

    private let maxMessageLength = 160

    private var messages: [Message] {
        viewModel.messages(for: contact)
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
                .overlay(MeshTheme.surfaceLight)
            messageInput
        }
        .background(MeshTheme.background)
        .navigationTitle(contact.name)
        .onAppear {
            viewModel.markAsRead(contact)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
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
                                : MeshTheme.accentFallback
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
    }
}

// MARK: - Channel Chat View

struct ChannelChatView: View {
    let channelIndex: UInt8
    let channelName: String
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var messageText = ""

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
            viewModel.unreadCounts[channelKey] = 0
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messages) { message in
                        ChannelMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
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
                                : MeshTheme.accentFallback
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
        viewModel.sendChannelMessage(messageText, channelIndex: channelIndex)
        viewModel.playHapticFeedback()
        messageText = ""
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
    @State private var showManagement = false

    private let maxMessageLength = 160

    /// Teal accent for remote management icon.
    private let remoteAccent = Color(red: 0.0, green: 0.7, blue: 0.8)

    private var messages: [Message] {
        viewModel.messages(for: contact)
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var loginStatusText: String {
        switch session.loginState {
        case .loggedIn(let isAdmin): isAdmin ? "Admin" : "Guest"
        case .loggingIn: "Logging in..."
        case .loginFailed: "Login failed"
        case .notLoggedIn: "Not logged in"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoggedIn {
                // Status bar
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(MeshTheme.connected)
                    Text(loginStatusText)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(MeshTheme.surface)

                messageList
                Divider()
                    .overlay(MeshTheme.surfaceLight)
                roomMessageInput
            } else {
                roomLoginPrompt
            }
        }
        .background(MeshTheme.background)
        .navigationTitle(contact.name)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isLoggedIn {
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
                    .help("Remote Management — \(contact.name)")
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
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messages) { message in
                        RoomMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
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
                                : MeshTheme.accentFallback
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
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    #if os(watchOS)
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { login() }
                    #endif
                }
                .padding(.horizontal, 32)

                Text("Passwords are case-sensitive, max 15 characters.")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)

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
                    .background(password.isEmpty ? MeshTheme.surfaceLight : MeshTheme.accentFallback)
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
            }

            Spacer()
        }
    }

    private var isLoggingIn: Bool {
        if case .loggingIn = session.loginState { return true }
        return false
    }

    private func login() {
        guard !password.isEmpty else { return }
        viewModel.loginToRemoteDevice(contact, password: password)
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
                        .foregroundStyle(MeshTheme.accentFallback)
                        .padding(.horizontal, 4)
                }

                Text(parsed.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(message.isOutgoing ? MeshTheme.textOnAccent : MeshTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    if message.isOutgoing {
                        Image(systemName: message.status == .sending ? "clock" : "checkmark")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }

                    if !message.isOutgoing, let snr = message.snr {
                        Text("SNR \(snr)")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 4)
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
                            .foregroundStyle(MeshTheme.accentFallback)
                            .frame(width: 24)
                        #if os(watchOS)
                        SecureField("Password", text: $password)
                            .foregroundStyle(MeshTheme.textPrimary)
                        #else
                        SecureField("Password", text: $password)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { login() }
                        #endif
                    }
                    .padding(.horizontal, 32)

                    Text("Passwords are case-sensitive, max 15 characters.")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

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
                        .background(password.isEmpty ? MeshTheme.surfaceLight : MeshTheme.accentFallback)
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
                }

                Spacer()
            }
            .background(MeshTheme.background)
            .navigationTitle(contact.name)
        }
    }

    private func login() {
        guard !password.isEmpty else { return }
        viewModel.loginToRemoteDevice(contact, password: password)
    }
}

// MARK: - Message Bubbles

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(message.isOutgoing ? MeshTheme.textOnAccent : MeshTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    if message.isOutgoing {
                        deliveryIndicator
                    }

                    if !message.isOutgoing, let snr = message.snr {
                        Text("SNR \(snr)")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 4)
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
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
        case .delivered:
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.accentFallback)
                if let rtt = message.roundTripMs, rtt > 0 {
                    Text("\(rtt)ms")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.accentFallback)
                }
            }
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(MeshTheme.disconnected)
        }
    }
}

struct ChannelMessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing, let sender = message.senderName, !sender.isEmpty {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MeshTheme.accentFallback)
                        .padding(.horizontal, 4)
                }

                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? MeshTheme.outgoingBubble : MeshTheme.incomingBubble)
                    .foregroundStyle(message.isOutgoing ? MeshTheme.textOnAccent : MeshTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)

                    if message.isOutgoing {
                        Image(systemName: message.status == .sending ? "clock" : "checkmark")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }

                    if !message.isOutgoing, let snr = message.snr {
                        Text("SNR \(snr)")
                            .font(.caption2)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 4)
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }
}
