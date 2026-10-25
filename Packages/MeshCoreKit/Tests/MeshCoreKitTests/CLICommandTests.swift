//
//  CLICommandTests.swift
//  MeshCoreKitTests
//
//  Firmware 1.18.0's companion CLI: CMD_RUN_CLI_COMMAND (66) /
//  RESP_CODE_CLI_REPLY (29), and the TXT_TYPE_CLI_COMMAND (3) text type.
//
//  Frame shapes asserted against `examples/companion_radio/MyMesh.cpp` at the
//  v1.18.0 companion tag `7d6d255104ea`, not against our own documentation.
//
//  Created by Michael P. Bedworth on 10/24/26.
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
@testable import MeshCoreKit

final class CLICommandTests: XCTestCase {

    // MARK: - CMD_RUN_CLI_COMMAND

    /// Firmware: `cmd_frame[0] == CMD_RUN_CLI_COMMAND && len >= 3`, then the
    /// command text runs from index 1 to the end of the frame.
    func testRunCLICommandFrameLayout() throws {
        let frame = try XCTUnwrap(MeshCoreProtocol.buildRunCLICommand("get name"))
        XCTAssertEqual(frame[0], 66, "opcode must be CMD_RUN_CLI_COMMAND (0x42)")
        XCTAssertEqual(String(data: frame.dropFirst(), encoding: .utf8), "get name")
        XCTAssertEqual(frame.count, 9)
    }

    /// No null terminator: the firmware writes one itself at `text[tlen] = 0`
    /// using the frame length, so sending one would put a stray byte in the
    /// command the CLI parses.
    func testRunCLICommandHasNoNullTerminator() throws {
        let frame = try XCTUnwrap(MeshCoreProtocol.buildRunCLICommand("reboot"))
        XCTAssertFalse(frame.contains(0), "frame must carry no null byte")
    }

    /// The firmware rejects anything under 3 bytes total, which is a one-byte
    /// command. Building it anyway costs a round trip and comes back looking
    /// exactly like an unsupported-firmware answer.
    func testRunCLICommandRejectsUnderLengthCommands() {
        XCTAssertNil(MeshCoreProtocol.buildRunCLICommand(""))
        XCTAssertNil(MeshCoreProtocol.buildRunCLICommand("v"))
        XCTAssertNil(MeshCoreProtocol.buildRunCLICommand("   "), "whitespace trims to empty")
        XCTAssertNotNil(MeshCoreProtocol.buildRunCLICommand("ver"))
    }

    func testRunCLICommandTrimsSurroundingWhitespace() throws {
        let frame = try XCTUnwrap(MeshCoreProtocol.buildRunCLICommand("  get name \n"))
        XCTAssertEqual(String(data: frame.dropFirst(), encoding: .utf8), "get name")
    }

    // MARK: - RESP_CODE_CLI_REPLY

    func testCLIReplyParses() throws {
        var frame = Data([29])
        frame.append(contentsOf: Array("> MPB-CB-9ae81".utf8))
        guard case .cliReply(let text) = FrameParser.parse(frame) else {
            return XCTFail("expected .cliReply, got \(FrameParser.parse(frame))")
        }
        XCTAssertEqual(text, "> MPB-CB-9ae81")
    }

    /// Several `set` commands reply with nothing. An empty payload is a legal
    /// answer, not a parse failure.
    func testCLIReplyAcceptsEmptyPayload() {
        guard case .cliReply(let text) = FrameParser.parse(Data([29])) else {
            return XCTFail("empty reply payload must still parse as .cliReply")
        }
        XCTAssertEqual(text, "")
    }

    /// An unrecognised command answers with this literal string rather than an
    /// error frame — so "Unknown command" means the *command* was unknown, and
    /// says nothing about whether the firmware supports the CLI at all.
    func testUnknownCommandArrivesAsOrdinaryReplyText() throws {
        var frame = Data([29])
        frame.append(contentsOf: Array("Unknown command".utf8))
        guard case .cliReply(let text) = FrameParser.parse(frame) else {
            return XCTFail("expected .cliReply")
        }
        XCTAssertEqual(text, "Unknown command")
    }

    func testCLIReplyHandlesMultilineAndUTF8() throws {
        var frame = Data([29])
        frame.append(contentsOf: Array("freq: 910.525\nbw: 62.5\nnote: °C ✓".utf8))
        guard case .cliReply(let text) = FrameParser.parse(frame) else {
            return XCTFail("expected .cliReply")
        }
        XCTAssertEqual(text, "freq: 910.525\nbw: 62.5\nnote: °C ✓")
    }

    // MARK: - TXT_TYPE_CLI_COMMAND

    /// The bug this guards: the app tested `txtType == 2` for signed and treated
    /// everything else as conversation, so firmware 1.18's type 3 became a chat
    /// bubble.
    func testOnlyPlainAndSignedAreConversational() {
        XCTAssertTrue(MeshCoreTextType.plain.isConversational)
        XCTAssertTrue(MeshCoreTextType.signedPlain.isConversational)
        XCTAssertFalse(MeshCoreTextType.cliData.isConversational)
        XCTAssertFalse(MeshCoreTextType.cliCommand.isConversational,
                       "a CLI command refused by the firmware must never render as chat")
    }

    func testTextTypeRawValuesMatchFirmware() {
        // src/helpers/TxtDataHelpers.h
        XCTAssertEqual(MeshCoreTextType.plain.rawValue, 0)
        XCTAssertEqual(MeshCoreTextType.cliData.rawValue, 1)
        XCTAssertEqual(MeshCoreTextType.signedPlain.rawValue, 2)
        XCTAssertEqual(MeshCoreTextType.cliCommand.rawValue, 3)
    }

    /// An unrecognised future type must not be assumed to be chat. `init?` fails,
    /// and the call site treats an unparsed type as non-conversational.
    func testUnknownTextTypeIsNotSilentlyPlain() {
        XCTAssertNil(MeshCoreTextType(rawValue: 4))
    }

    // MARK: - Opcodes

    func testOpcodesMatchFirmware() {
        XCTAssertEqual(MeshCoreCommand.runCLICommand.rawValue, 66)
        XCTAssertEqual(MeshCoreResponseCode.cliReply.rawValue, 29)
    }
}

// MARK: - Unsupported-setting detection

/// `supportedValue(for:)` is what every firmware-gated control asks, and the
/// companion CLI reports an unknown command differently from the serial CLI.
@MainActor
final class SupportedValueTests: XCTestCase {

    private func session(settings: [String: String]) -> RemoteDeviceSession {
        let contact = Contact(
            publicKey: Data(repeating: 0xFD, count: 32), name: "radio", type: .repeater,
            flags: 0, outPathLen: 0, outPath: Data(), lastAdvert: 0, latitude: 0, longitude: 0
        )
        let s = RemoteDeviceSession(contact: contact)
        for (k, v) in settings { s.settings[k] = v }
        return s
    }

    /// Firmware 1.18's `CMD_RUN_CLI_COMMAND` appends this literal string rather
    /// than the serial CLI's `??:` prefix. Without it, every setting a companion
    /// does not implement reads back as having the *value* "Unknown command" and
    /// its control renders as supported.
    func testUnknownCommandIsNotAValue() {
        let s = session(settings: ["advert.interval": "Unknown command"])
        XCTAssertNil(s.supportedValue(for: "advert.interval"))
    }

    func testSerialCLIUnknownFormStillDetected() {
        XCTAssertNil(session(settings: ["cad": "??: get cad"]).supportedValue(for: "cad"))
    }

    func testUnsupportedHardwareDetected() {
        XCTAssertNil(session(settings: ["gps": "Error: unsupported"]).supportedValue(for: "gps"))
    }

    func testRealValuesSurvive() {
        let s = session(settings: ["tx": "22", "name": "MPB-CB-9ae81", "dutycycle": "0"])
        XCTAssertEqual(s.supportedValue(for: "tx"), "22")
        XCTAssertEqual(s.supportedValue(for: "name"), "MPB-CB-9ae81")
        XCTAssertEqual(s.supportedValue(for: "dutycycle"), "0", "a legitimate \"0\" is a value, not an absence")
    }

    func testMissingAndEmptyAreNil() {
        let s = session(settings: ["blank": "   "])
        XCTAssertNil(s.supportedValue(for: "blank"))
        XCTAssertNil(s.supportedValue(for: "never-fetched"))
    }
}
