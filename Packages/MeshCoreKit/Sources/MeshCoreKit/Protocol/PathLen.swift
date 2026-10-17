//
//  PathLen.swift
//  MeshCoreKit
//
//  The one place `path_len` is decoded.
//
//  The protocol's `path_len` is two fields in one byte, and reading it whole
//  put "70 hops" on a mesh that cannot exceed 63 — `0x46` is six hops carrying
//  two-byte hashes. The firmware's accessors in `Packet.h` are the definition:
//
//      getPathHashCount() { return path_len & 63; }
//      getPathHashSize()  { return (path_len >> 6) + 1; }
//      getPathByteLen()   { return getPathHashCount() * getPathHashSize(); }
//
//  It lives here because the first fix for that bug corrected one of the five
//  places that render a hop count and missed the other four, so the number on
//  screen did not change. Five copies of a decode is four too many: call these,
//  never `& 0x3F` at a call site. `check_path_len_decoding` in
//  `scripts/check_rules.py` fails the build on a raw `path_len` reaching a view.
//
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

public enum PathLen {

    /// `path_len` for a path that is unknown or flooded rather than counted.
    ///
    /// Must be tested before the mask: read as a count it decodes to a
    /// perfectly plausible 63 hops of 4-byte hashes.
    public static let unknown: UInt8 = 0xFF

    /// The largest hop count six bits can hold.
    ///
    /// Anything above this on screen means a raw byte leaked through.
    public static let maxHops = 63

    /// Hops travelled, or `nil` when the path is unknown or flooded.
    ///
    /// `0` means direct.
    public static func hopCount(_ raw: UInt8) -> Int? {
        guard raw != unknown else { return nil }
        return Int(raw & 0x3F)
    }

    /// Hops travelled for a `path_len` held as a signed byte.
    ///
    /// `Contact.outPathLen` is `Int8`, where a negative value means flood or
    /// auto rather than a count.
    ///
    /// - Note: that signed storage cannot represent hash modes 2 and 3, whose
    ///   bytes set the high bit and so read as negative. Those are rare — most
    ///   meshes use 1- or 2-byte hashes — and widening the field would be a
    ///   persisted-`Codable` change (Critical Rules 1 and 2), so it is recorded
    ///   here rather than silently worked around.
    public static func hopCount(_ raw: Int8) -> Int? {
        guard raw >= 0 else { return nil }
        return hopCount(UInt8(bitPattern: raw))
    }

    /// Bytes per hop hash: 1, 2, 3 or 4.
    ///
    /// Carried in the top two bits. Prefer this over dividing the path's byte
    /// count by the hop count — that guess returns 0 whenever the hop count is
    /// wrong, which is exactly when it is least able to notice.
    public static func hashSize(_ raw: UInt8) -> Int {
        Int(raw >> 6) + 1
    }

    /// Meaningful bytes of the path field: `hash_count * hash_size`.
    public static func byteLength(_ raw: UInt8) -> Int {
        guard let hops = hopCount(raw) else { return 0 }
        return hops * hashSize(raw)
    }
}
