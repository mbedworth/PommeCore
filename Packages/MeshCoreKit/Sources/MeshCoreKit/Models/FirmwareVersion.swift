//
//  FirmwareVersion.swift
//  MeshCoreKit
//
//  Semantic version comparison for firmware version strings.
//
//  Created by Michael P. Bedworth on 10/4/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// A firmware version, parsed out of whatever the device or a release tag calls itself.
///
/// Firmware reports its version in several shapes depending on where it is read:
/// `v1.17.1`, `1.17.1`, `v1.17.1-d929643`, and the GitHub release tags add their own
/// prefixes. All of them reduce to the same three numbers, so this type pulls those
/// out and ignores everything else.
///
/// It exists because some firmware features cannot be detected by asking for them.
/// Most capability gates in the app read a getter and check whether the device
/// understood it (`RemoteDeviceSession.supportedValue(for:)`), which is always
/// preferable: it reports what this board actually does rather than what its version
/// number implies. But a few commands are write-only — `room.post` has no `get
/// room.post` — and for those the version string is the only signal available.
public struct FirmwareVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses the first `N.N.N` (or `N.N`) sequence in a string, or returns nil.
    ///
    /// Anything around the numbers is discarded, so a build suffix, a `v` prefix, or a
    /// surrounding sentence all parse. A string with no version-shaped substring returns
    /// nil rather than a zero version — callers gating a feature must not treat an
    /// unreadable version as "very old but valid", because the two cases warrant
    /// different UI.
    public init?(_ string: String) {
        let pattern = #"(\d+)\.(\d+)(?:\.(\d+))?"#
        guard let match = string.range(of: pattern, options: .regularExpression) else { return nil }
        let parts = string[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
