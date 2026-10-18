//
//  MessageComposer.swift
//  PommeCore
//
//  The one compose field.
//
//  There were three near-identical copies — direct message, channel and room —
//  and they had drifted. The channel's field would not empty after sending
//  while the direct message's did, which is the kind of difference three copies
//  of the same screen produce and one copy cannot.
//
//  The actual cause was in the draft store rather than here, but the three
//  copies are what made it a *channel* bug instead of a bug: each screen cleared
//  its own field its own way, so nothing forced them to behave alike. With one
//  composer, a difference in behaviour has to be asked for.
//
//  Everything that was duplicated lives here: the field, the send button and its
//  enabled state, the character counter, the length clamp, submit-on-return, and
//  the draft load/save/clear cycle. The parts that genuinely differ are passed
//  in — a quote bar above the field (direct messages), an autocomplete overlay
//  (channel mentions), and a trailing accessory. A screen that needs none of
//  them passes none.
//
//  Created by Michael P. Bedworth on 10/17/26.
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import SwiftUI
import MeshCoreKit

struct MessageComposer<Accessory: View, Overlay: View>: View {

    /// The text being composed. Owned by the caller so it can prefill a mention
    /// or a quote reply.
    @Binding var text: String

    /// Conversation this field belongs to: a contact's key prefix, or a
    /// channel's single-byte index. Drafts are stored against it.
    let conversationKey: Data

    /// Sends `text`. The composer clears the field and the draft afterwards, so
    /// a caller must not clear them itself — that double-clearing is what the
    /// three copies each did slightly differently.
    let onSend: () -> Void

    /// Shown above the field, e.g. the quoted-message bar.
    @ViewBuilder var accessory: () -> Accessory

    /// Shown above the accessory, e.g. the mention autocomplete list.
    @ViewBuilder var overlay: () -> Overlay

    @Environment(MessageStoreManager.self) private var messageStoreManager

    /// The radio counts UTF-8 bytes, so the field does too. For English the two
    /// are the same number, which is exactly why counting Characters here went
    /// unnoticed in twelve languages — see `MessageText`.
    private var byteCount: Int { text.utf8ByteCount }
    private var maxBytes: Int { MessageText.maxBytes }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEmpty: Bool { trimmed.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            overlay()
            VStack(spacing: 4) {
                accessory()
                HStack(spacing: 10) {
                    TextField("Type a message...", text: $text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(MeshTheme.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(MeshTheme.textPrimary)
                        .onChange(of: text) { _, newValue in
                            let clamped = newValue.truncated(toUTF8Bytes: maxBytes)
                            if clamped != newValue { text = clamped }
                        }
                        #if !os(watchOS)
                        .onSubmit(send)
                        #endif

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .accessibilityLabel("Send message")
                            .font(.title)
                            .foregroundStyle(isEmpty ? MeshTheme.textSecondary : MeshTheme.accent)
                    }
                    .disabled(isEmpty)
                }
                .padding(.horizontal, 12)

                if !text.isEmpty {
                    HStack {
                        Spacer()
                        Text("\(byteCount)/\(maxBytes)")
                            .font(.caption2)
                            .foregroundStyle(
                                byteCount > maxBytes - 10
                                    ? MeshTheme.statusWarn
                                    : MeshTheme.textSecondary
                            )
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
            .background(MeshTheme.surface)
        }
        .onAppear {
            // Only restore when the field is empty: a mention or quote reply may
            // already have put something there.
            if text.isEmpty {
                text = messageStoreManager.loadDraft(for: conversationKey)
            }
        }
        .onDisappear {
            messageStoreManager.saveDraft(text, for: conversationKey)
        }
    }

    private func send() {
        guard !isEmpty else { return }
        onSend()
        messageStoreManager.playHapticFeedback()
        text = ""
        messageStoreManager.saveDraft("", for: conversationKey)
    }
}

// Convenience initialisers so a screen only names what it actually uses.
extension MessageComposer where Accessory == EmptyView, Overlay == EmptyView {
    init(text: Binding<String>, conversationKey: Data, onSend: @escaping () -> Void) {
        self.init(text: text, conversationKey: conversationKey, onSend: onSend,
                  accessory: { EmptyView() }, overlay: { EmptyView() })
    }
}

extension MessageComposer where Overlay == EmptyView {
    init(text: Binding<String>,
         conversationKey: Data,
         onSend: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(text: text, conversationKey: conversationKey, onSend: onSend,
                  accessory: accessory, overlay: { EmptyView() })
    }
}

extension MessageComposer where Accessory == EmptyView {
    init(text: Binding<String>,
         conversationKey: Data,
         onSend: @escaping () -> Void,
         @ViewBuilder overlay: @escaping () -> Overlay) {
        self.init(text: text, conversationKey: conversationKey, onSend: onSend,
                  accessory: { EmptyView() }, overlay: overlay)
    }
}
