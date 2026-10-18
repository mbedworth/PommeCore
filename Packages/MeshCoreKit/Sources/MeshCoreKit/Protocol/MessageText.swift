//
//  MessageText.swift
//  MeshCoreKit
//
//  How long a message may be, in the unit the radio actually counts.
//
//  The composer counted Characters and the frame builders counted bytes, and
//  for English those are the same number, which is why this survived twelve
//  languages. A 160-character Japanese message is 480 bytes: the UI showed
//  "160/160" and accepted it, the builder cut it to 160 bytes — about a third
//  of what was typed — and the cut landed mid-character, so the tail was not
//  valid UTF-8 by the time it left the radio.
//
//  One limit, one unit, one place to truncate. `truncated(toUTF8Bytes:)` never
//  splits a character, so a frame cannot carry a broken one even if some future
//  caller skips the UI entirely.
//
//  Created by Michael P. Bedworth on 10/17/26.
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import Foundation

public enum MessageText {

    /// Longest message body the app will put on the air, in UTF-8 bytes.
    ///
    /// The radio's own ceiling is higher — `MAX_GROUP_DATA_LENGTH` is 165 for a
    /// channel payload — but 166 and 167 pass the firmware's host-frame check
    /// and then fail its radio-side one with `ERR_CODE_TABLE_FULL`, a code that
    /// everywhere else means "retry later" and here never will succeed. Staying
    /// at 160 keeps that case out of reach. See `docs/FIRMWARE_COMPAT.md`.
    public static let maxBytes = 160
}

public extension String {

    /// UTF-8 length, which is the only length the radio cares about.
    var utf8ByteCount: Int { utf8.count }

    /// Drops whole characters from the end until the string fits `limit` bytes.
    ///
    /// Truncating the `Data` instead splits multi-byte characters, which is the
    /// bug this exists to make unrepresentable.
    func truncated(toUTF8Bytes limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var result = self
        while result.utf8.count > limit, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}
