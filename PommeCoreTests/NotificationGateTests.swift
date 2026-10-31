//
//  NotificationGateTests.swift
//  PommeCoreTests
//
//  The App Store reviewer's complaint — "the notification settings don't work at
//  all, I always get a notification" — and the half of it that survived the
//  first fix.
//
//  `alertIsAllowed(for:)` is the single gate every alerting path must ask. It
//  used to live inline in `postLocalNotification`, while the receive haptic
//  fired from `store(_:)` with no checks whatsoever: a Muted channel still
//  buzzed once per message, and reconnecting after the app had been away
//  drained the radio's backlog and buzzed once for *each* of them. Found on
//  hardware 2026-10-30, after the notification half had already shipped as
//  fixed — which is precisely why it is now one function with tests, and not
//  two code paths that agree by inspection.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
import MeshCoreKit
@testable import PommeCore

@MainActor
final class NotificationGateTests: XCTestCase {

    private var store: MessageStoreManager!
    private var savedDirect = true
    private var savedChannel = true
    private var savedRoom = true

    private let myName = "MPB-Base"

    override func setUp() async throws {
        let prefs = NotificationPreferences.shared
        savedDirect = prefs.notifyDirect
        savedChannel = prefs.notifyChannel
        savedRoom = prefs.notifyRoom
        prefs.notifyDirect = true
        prefs.notifyChannel = true
        prefs.notifyRoom = true

        store = MessageStoreManager()
        store.deviceNameProvider = { [myName] in myName }
    }

    override func tearDown() async throws {
        let prefs = NotificationPreferences.shared
        prefs.notifyDirect = savedDirect
        prefs.notifyChannel = savedChannel
        prefs.notifyRoom = savedRoom
        store = nil
    }

    // MARK: - Fixtures

    private func channelMessage(_ text: String, index: UInt8 = 0) -> Message {
        Message(text: text,
                timestamp: Date(),
                isOutgoing: false,
                status: .sending,
                channelIndex: index,
                senderName: "Z-max")
    }

    private func directMessage(from contact: Contact) -> Message {
        Message(contactKeyHash: contact.publicKeyPrefix,
                text: "hello",
                timestamp: Date(),
                isOutgoing: false,
                status: .sending)
    }

    private func contact(_ type: ContactType) -> Contact {
        Contact(publicKey: Data(repeating: 0xAB, count: 32), name: "Z-max", type: type)
    }

    private func withChannelMode(_ mode: ChannelStore.ChannelNotifyMode) {
        store.channelNotifyModeProvider = { _ in mode }
    }

    // MARK: - Muted means muted

    /// The defect, in one line. Muted is unconditional: no notification, no
    /// haptic, no exceptions, including for a message that mentions you.
    func testMutedChannelAllowsNothing() {
        withChannelMode(.muted)

        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("anything")))
        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("hey @MPB-Base")),
                       "Muted outranks a mention — the user asked not to be interrupted")
    }

    // MARK: - Mentions only

    func testMentionsOnlyStaysSilentWithoutAMention() {
        withChannelMode(.mentionsOnly)

        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("anyone on frequency?")))
    }

    func testMentionsOnlyMatchesTheBareForm() {
        withChannelMode(.mentionsOnly)

        XCTAssertTrue(store.alertIsAllowed(for: channelMessage("copy @MPB-Base")))
    }

    /// `@[name]` is the MeshCore One form, and the only one that works for a
    /// name containing a space or emoji — which most names on the mesh have.
    /// Only the bare form was checked, so "mentions only" stayed silent for
    /// anyone addressed the usual way.
    func testMentionsOnlyMatchesTheBracketedForm() {
        withChannelMode(.mentionsOnly)

        XCTAssertTrue(store.alertIsAllowed(for: channelMessage("copy @[MPB-Base]")))
    }

    func testMentionMatchingIgnoresCase() {
        withChannelMode(.mentionsOnly)

        XCTAssertTrue(store.alertIsAllowed(for: channelMessage("copy @mpb-base")))
        XCTAssertTrue(store.alertIsAllowed(for: channelMessage("copy @[MPB-BASE]")))
    }

    /// Fails closed. With no device name there is no way to recognise a
    /// mention, and "mentions only" is a request not to be interrupted
    /// otherwise — so the unknown case must be silence, not noise.
    func testMentionsOnlyFailsClosedWithNoDeviceName() {
        withChannelMode(.mentionsOnly)
        store.deviceNameProvider = { "" }

        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("copy @MPB-Base")))
    }

    // MARK: - A mode that only applies when a lookup succeeds is not a mode

    /// An unresolved channel — one not yet synced — used to skip every check
    /// below the lookup and notify anyway. It now defaults to `.all`, which
    /// still has to pass the channel preference.
    func testUnresolvedChannelStillHonoursTheChannelPreference() {
        store.channelNotifyModeProvider = nil

        XCTAssertTrue(store.alertIsAllowed(for: channelMessage("hello")))

        NotificationPreferences.shared.notifyChannel = false
        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("hello")))
    }

    /// The master switch outranks the per-channel mode in both directions.
    func testChannelPreferenceOffSilencesEvenAllMode() {
        withChannelMode(.all)
        NotificationPreferences.shared.notifyChannel = false

        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("hello")))
    }

    /// The mode is read per index, so a second channel is not governed by the
    /// first. The original bug only ever hit index 0.
    func testEachChannelIndexIsGovernedSeparately() {
        store.channelNotifyModeProvider = { index in index == 0 ? .muted : .all }

        XCTAssertFalse(store.alertIsAllowed(for: channelMessage("hello", index: 0)))
        XCTAssertTrue(store.alertIsAllowed(for: channelMessage("hello", index: 3)))
    }

    // MARK: - Direct messages

    func testPlainContactIsAllowed() {
        XCTAssertTrue(store.alertIsAllowed(for: directMessage(from: contact(.chat))))
    }

    func testDirectPreferenceOffSilencesContacts() {
        NotificationPreferences.shared.notifyDirect = false

        XCTAssertFalse(store.alertIsAllowed(for: directMessage(from: contact(.chat))))
    }

    /// Infrastructure does not get to interrupt you. A repeater or sensor
    /// answering a telemetry request is not a person talking.
    func testInfrastructureNodesNeverAlert() {
        for type in [ContactType.repeater, .sensor] {
            let node = contact(type)
            store.contactProvider = { _ in node }

            XCTAssertFalse(store.alertIsAllowed(for: directMessage(from: node)),
                           "\(type) should not raise an alert")
        }
    }

    func testMutedContactIsSilenced() {
        let person = contact(.chat)
        store.contactProvider = { _ in person }
        store.contactNotifyModeProvider = { _ in .muted }

        XCTAssertFalse(store.alertIsAllowed(for: directMessage(from: person)))
    }

    func testRoomUsesTheRoomPreference() {
        let room = contact(.room)
        store.contactProvider = { _ in room }

        XCTAssertTrue(store.alertIsAllowed(for: directMessage(from: room)))

        NotificationPreferences.shared.notifyRoom = false
        XCTAssertFalse(store.alertIsAllowed(for: directMessage(from: room)))
    }

    /// A room is governed by the room preference, not the direct one — they are
    /// separate settings and must not be wired to each other.
    func testRoomIsNotGovernedByTheDirectPreference() {
        let room = contact(.room)
        store.contactProvider = { _ in room }
        NotificationPreferences.shared.notifyDirect = false

        XCTAssertTrue(store.alertIsAllowed(for: directMessage(from: room)))
    }
}
