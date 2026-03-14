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
