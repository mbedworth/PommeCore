//
//  BinaryFraming.swift
//  MeshCoreKit
//
//  Deframing for the stream transports (USB binary mode and WiFi), which
//  deliver bytes rather than whole frames. BLE needs none of this: one
//  notification is always one frame.
//
//  Created by Michael P. Bedworth on 10/02/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

/// Extracts `>` + length + payload frames from a byte stream.
///
/// USB and WiFi both carried their own byte-identical copy of this scanning
/// loop, so a fix to one silently left the other wrong. It lives here once,
/// and unlike either copy it is covered by tests.
public enum BinaryFraming {

    /// Frame start marker, `>`.
    public static let startMarker: UInt8 = 0x3E

    /// Marker plus the two length bytes.
    public static let headerLength = 3

    /// Largest payload length accepted from the wire.
    ///
    /// The length field is a UInt16, so a corrupted one can claim up to 65535
    /// bytes. The scanner would then wait for that much data and discard it as
    /// a single bogus frame — swallowing up to 64KB of real frames queued
    /// behind it, from one flipped byte. Companion frames are a few hundred
    /// bytes at most, so this is generous headroom whose only job is to reject
    /// obvious corruption; a length beyond it means the marker was not a real
    /// frame start.
    public static let maxPayloadLength = 4096

    /// Consume every complete frame from the front of `buffer`.
    ///
    /// Returns the payloads with their headers stripped, in arrival order.
    /// Leaves any trailing partial frame in `buffer` for the next read, and
    /// discards bytes that cannot begin a frame.
    ///
    /// `buffer` is `inout` so each transport keeps owning its own buffer —
    /// USB's is shared with CLI-mode line parsing and mode detection.
    public static func extractFrames(from buffer: inout Data) -> [Data] {
        var frames: [Data] = []

        while buffer.count >= headerLength {
            // Data indices stay absolute after removeFirst, so every offset
            // here is relative to startIndex rather than to zero.
            let start = buffer.startIndex

            guard buffer[start] == startMarker else {
                guard let marker = buffer.firstIndex(of: startMarker) else {
                    // Nothing in the buffer can begin a frame.
                    buffer.removeAll()
                    return frames
                }
                buffer.removeFirst(buffer.distance(from: start, to: marker))
                continue
            }

            var length: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &length) { dest in
                buffer.copyBytes(to: dest, from: (start + 1)..<(start + headerLength))
            }
            let payloadLength = Int(UInt16(littleEndian: length))

            guard payloadLength <= maxPayloadLength else {
                // A marker byte that happens to sit inside payload or noise.
                // Skip just this byte so a genuine frame starting later is
                // still found, rather than trusting the bogus length.
                buffer.removeFirst(1)
                continue
            }

            let totalLength = headerLength + payloadLength
            guard buffer.count >= totalLength else { return frames }  // await more

            frames.append(Data(buffer[(start + headerLength)..<(start + totalLength)]))
            buffer.removeFirst(totalLength)
        }

        return frames
    }
}
