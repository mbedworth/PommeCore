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

// MARK: - Retired and renamed defaults keys

/// A stand-in for the iCloud key-value store, so a test can say "the new
/// location is empty" or "the new location already holds the user's choice"
/// without touching the real one.
private final class FakeCloudStore: NSUbiquitousKeyValueStore {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func synchronize() -> Bool { true }
}

/// `RetiredDefaults.sweepIfNeeded` — the recovery for the settings that
/// `9cf94d7` lost, and the retirement of the keys `#94` left behind.
///
/// The case that matters most is `testCurrentValueIsNeverOverwritten`: this
/// runs eight months after the rename, so anyone who re-set a notification
/// since then has a deliberate choice in the new location, and a migration
/// that stamped the March value over it would be a second silent reset — the
/// same defect it exists to repair, pointed the other way.
final class RetiredDefaultsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cloud: FakeCloudStore!

    override func setUp() {
        super.setUp()
        suiteName = "RetiredDefaultsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cloud = FakeCloudStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLegacyValueIsAdoptedWhenTheNewLocationIsEmpty() {
        defaults.set(false, forKey: "notifyDirectMessages")

        RetiredDefaults.sweepIfNeeded(defaults: defaults, cloud: cloud)

        // The whole point: a preference switched off before March 2026 comes
        // back off, instead of being read as "never set" and so as on.
        XCTAssertEqual(cloud.values["notify.direct"] as? Bool, false)
    }

    func testCurrentValueIsNeverOverwritten() {
        defaults.set(false, forKey: "notifyDirectMessages")
        cloud.values["notify.direct"] = true   // the user set it since

        RetiredDefaults.sweepIfNeeded(defaults: defaults, cloud: cloud)

        XCTAssertEqual(cloud.values["notify.direct"] as? Bool, true)
    }

    func testLegacyKeysAreClearedWhetherOrNotTheyWereAdopted() {
        defaults.set(false, forKey: "notifyDirectMessages")   // adopted
        defaults.set(false, forKey: "notifyChannelMessages")  // not adopted
        cloud.values["notify.channel"] = true

        RetiredDefaults.sweepIfNeeded(defaults: defaults, cloud: cloud)

        // A value left behind is a value a future key of the same name inherits.
        for (legacy, _) in RetiredDefaults.renamedToCloud {
            XCTAssertNil(defaults.object(forKey: legacy), "\(legacy) survived")
        }
    }

    func testRetiredKeysAreRemoved() {
        for key in RetiredDefaults.retired {
            defaults.set(true, forKey: key)
        }

        RetiredDefaults.sweepIfNeeded(defaults: defaults, cloud: cloud)

        for key in RetiredDefaults.retired {
            XCTAssertNil(defaults.object(forKey: key), "\(key) survived")
        }
    }

    func testSweepRunsOnlyOnce() {
        defaults.set(false, forKey: "notifyDirectMessages")
        RetiredDefaults.sweepIfNeeded(defaults: defaults, cloud: cloud)
        XCTAssertEqual(cloud.values["notify.direct"] as? Bool, false)

        // A legacy key that reappears later — a restored backup, an old value
        // syncing down from another device — must not be adopted a second
        // time. The new location is deliberately left *empty* here, so the
        // no-overwrite guard cannot be what stops it: only the once-only flag
        // can. Written the obvious way round, with a value in the new
        // location, this test passed with the flag deleted entirely.
        defaults.set(false, forKey: "notifyDirectMessages")
        cloud.values.removeValue(forKey: "notify.direct")
        RetiredDefaults.sweepIfNeeded(defaults: defaults, cloud: cloud)

        XCTAssertNil(cloud.values["notify.direct"],
                     "the sweep ran a second time")
    }

    func testALiveSettingIsNotRetiredByMistake() {
        // `notifyContactPurge` is shaped exactly like the five legacy names and
        // is a working setting. If it ever appears in the registry, the sweep
        // would delete a preference the user still sets.
        let names = RetiredDefaults.retired
            + RetiredDefaults.renamedToCloud.map(\.legacy)
        XCTAssertFalse(names.contains("notifyContactPurge"))
    }
}
