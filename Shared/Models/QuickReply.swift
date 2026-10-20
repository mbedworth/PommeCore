//
//  QuickReply.swift
//  PommeCore
//
//  Builds the "Copy, @[Name]! 8 hops to Ft Pierce, FL @ 21:50" acknowledgement
//  that mesh operators send back after a radio check.
//
//  This is a *manual* action — a long-press on the message being answered, which
//  fills the composer so it can be edited before sending. It is deliberately not
//  an auto-responder: two stations with auto-reply on the same public channel
//  answer each other forever, and airtime is the scarce resource on this mesh.
//  Nothing here sends anything.
//
//  The parts are assembled rather than substituted into a template. A template
//  with `{hops}`-style tokens has to decide what to do when a token has no value
//  — a message that arrived by flood has no hop count — and the answer is always
//  some fragile string surgery on the leftover punctuation ("Copy, Bob!  to  @
//  21:50"). Assembling from parts means an absent part was simply never added,
//  and it is also the only form that can be translated: a user-edited template
//  cannot be, because the catalog has never seen it.
//
//  Created by Michael P. Bedworth on 10/19/26.
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import Foundation
import MeshCoreKit

enum QuickReply {

    // MARK: - Settings

    static let locationKey = "quickReplyLocation"
    static let includeHopsKey = "quickReplyIncludeHops"
    static let includeLocationKey = "quickReplyIncludeLocation"
    static let includeTimeKey = "quickReplyIncludeTime"
    static let includeSNRKey = "quickReplyIncludeSNR"

    /// What the operator wants in the acknowledgement.
    ///
    /// Everything except SNR defaults on, because everything except SNR appears
    /// in what other stations on the band actually send. SNR is the one people
    /// disagree about — it is already on the message row for anyone who cares,
    /// and it costs bytes against a 160-byte limit.
    struct Options {
        var location: String = ""
        var includeHops: Bool = true
        var includeLocation: Bool = true
        var includeTime: Bool = true
        var includeSNR: Bool = false

        static var current: Options {
            let defaults = UserDefaults.standard
            // `bool(forKey:)` is false for a key that was never written, so the
            // three defaulting to on have to be registered rather than read raw.
            defaults.register(defaults: [
                includeHopsKey: true,
                includeLocationKey: true,
                includeTimeKey: true,
                includeSNRKey: false
            ])
            return Options(
                location: defaults.string(forKey: locationKey) ?? "",
                includeHops: defaults.bool(forKey: includeHopsKey),
                includeLocation: defaults.bool(forKey: includeLocationKey),
                includeTime: defaults.bool(forKey: includeTimeKey),
                includeSNR: defaults.bool(forKey: includeSNRKey)
            )
        }
    }

    // MARK: - Addressing

    /// How to name the station being answered.
    ///
    /// On a channel it is `@[Name]`, the MeshCore One mention form the other
    /// clients already use. The brackets are not decoration: channel names
    /// contain spaces and emoji (`W4KWS 📡 GAT30S`), so a bare `@name` has no
    /// way to say where the name stops.
    ///
    /// In a direct message there is only one person it could be addressed to,
    /// so the plain display name reads better and costs fewer bytes.
    static func address(senderName: String?, displayName: String, isChannel: Bool) -> String {
        if isChannel, let senderName, !senderName.isEmpty {
            return "@[\(senderName)]"
        }
        return displayName
    }

    // MARK: - Building

    /// The acknowledgement for `message`, clamped to what the radio will carry.
    ///
    /// - Parameters:
    ///   - message: the received message being answered. Its hop count, SNR and
    ///     timestamp are the ones reported — **not** the current time, because
    ///     the point of the acknowledgement is to tell the sender how their
    ///     transmission arrived.
    ///   - address: the result of `address(senderName:displayName:isChannel:)`.
    static func text(replyingTo message: Message,
                     address: String,
                     options: Options = .current) -> String {

        var parts: [String] = []

        if options.includeHops, let hops = message.hopCount {
            parts.append(hopsPhrase(hops))
        }

        let location = options.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.includeLocation, !location.isEmpty {
            parts.append(String(localized: "to \(location)"))
        }

        if options.includeSNR, let snr = message.snr {
            parts.append(snrPhrase(Double(snr) / 4.0))
        }

        if options.includeTime {
            parts.append("@ \(formatMeshTime(message.timestamp))")
        }

        return assemble(greetingFor: address, parts: parts)
    }

    /// Join the greeting to the parts, dropping parts from the end until the
    /// result fits in a single message.
    ///
    /// Dropping beats truncating: a reply cut at 160 bytes ends mid-word, and a
    /// hop count is worth more to the sender than the timestamp they can already
    /// see on their own screen. The greeting is never dropped — an
    /// acknowledgement that does not say who it is for is worse than none — so a
    /// long enough name still falls through to the clamp, which is correct by
    /// UTF-8 boundaries (`MessageText`).
    private static func assemble(greetingFor address: String, parts: [String]) -> String {
        var parts = parts
        while true {
            let greeting = String(localized: "Copy, \(address)!")
            let line = ([greeting] + parts).joined(separator: " ")
            if line.utf8ByteCount <= MessageText.maxBytes || parts.isEmpty {
                return line.truncated(toUTF8Bytes: MessageText.maxBytes)
            }
            parts.removeLast()
        }
    }

    // MARK: - Phrases

    /// `direct`, `1 hop`, `8 hops` — inflected by the catalog, not by an `== 1`
    /// here, because not every language pluralises on one.
    private static func hopsPhrase(_ hops: Int) -> String {
        guard hops > 0 else { return String(localized: "direct") }
        return String(localized: "^[\(hops) hop](inflect: true)")
    }

    /// One decimal place, matching how SNR is shown on the message row.
    private static func snrPhrase(_ dB: Double) -> String {
        String(localized: "\(String(format: "%.1f", dB)) dB")
    }
}
