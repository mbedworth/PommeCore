//
//  main.swift
//  meshctl
//
//  Command-line harness for exercising a real MeshCore radio against MeshCoreKit.
//
//  Exists so the firmware smoke test is a command rather than a manual pass
//  through the app UI: see docs/FIRMWARE_COMPAT.md. `capture` additionally dumps
//  real frames as hex fixtures, which the replay tests in MeshCoreKitTests use
//  so the same checks can run later with no radio attached.
//
//  Created by Michael P. Bedworth on 10/02/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import MeshCoreKit

// MARK: - Output

let stderrHandle = FileHandle.standardError

/// When launched through `open` (required for Bluetooth — see scripts/meshctl.sh)
/// the process has no usable stdout, so every line is mirrored to this file.
var reportHandle: FileHandle?

func emit(_ s: String) {
    reportHandle?.write(Data((s + "\n").utf8))
}

func note(_ s: String) {
    stderrHandle.write(Data((s + "\n").utf8))
    emit(s)
}

func out(_ s: String) {
    print(s)
    emit(s)
}

func openReport(at path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
    reportHandle = FileHandle(forWritingAtPath: path)
}

var failures: [String] = []
var passes: [String] = []

func check(_ condition: Bool, _ label: String, detail: String = "") {
    if condition {
        passes.append(label)
        out("  PASS  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures.append(label)
        out("  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func info(_ label: String, _ value: String) {
    out("  ....  \(label): \(value)")
}

// MARK: - Argument parsing

struct Options {
    var command = "help"
    var device: String?          // BLE name filter
    var target: String?          // contact pubkey prefix (hex) for telemetry
    var outputPath: String?
    var scanSeconds: TimeInterval = 6
    var window: TimeInterval = 25
    /// How many contacts `bulkdelete` creates and then deletes. Enough to make
    /// the firmware do real work per removal, few enough to leave the radio
    /// quickly if something goes wrong.
    var bulkCount = 12
    var reportPath: String?
}

func parseArgs() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") {
        opts.command = first
        args.removeFirst()
    }
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--device", "-d":
            i += 1; opts.device = i < args.count ? args[i] : nil
        case "--target", "-t":
            i += 1; opts.target = i < args.count ? args[i] : nil
        case "--out", "-o":
            i += 1; opts.outputPath = i < args.count ? args[i] : nil
        case "--scan":
            i += 1; opts.scanSeconds = TimeInterval(i < args.count ? args[i] : "6") ?? 6
        case "--count", "-n":
            if i + 1 < args.count, let n = Int(args[i + 1]), n > 0 { opts.bulkCount = n; i += 1 }
        case "--window", "-w":
            i += 1; opts.window = TimeInterval(i < args.count ? args[i] : "25") ?? 25
        case "--report":
            i += 1; opts.reportPath = i < args.count ? args[i] : nil
        default:
            note("unknown option: \(args[i])")
        }
        i += 1
    }
    return opts
}

let usage = """
meshctl — exercise a real MeshCore radio against MeshCoreKit

USAGE
  swift run meshctl <command> [options]

COMMANDS
  scan                  List MeshCore radios advertising nearby
  info                  Connect and print device/self info
  telemetry             Request telemetry from a contact and dump the readings
  smoke                 Run the firmware smoke-test assertions
  capture               Connect, exercise the radio, write frames as hex fixtures
  bulkdelete            Exercise bulk contact deletion against real firmware
  seed                  Add test contacts and leave them (to drive the app's own UI)
  cleanup               Remove every test contact left on the radio

OPTIONS
  -d, --device <name>   BLE name substring to connect to (default: strongest signal)
  -t, --target <hex>    Contact public-key prefix for telemetry/smoke (e.g. a1b2c3)
  -o, --out <path>      Fixture output path for `capture`
      --scan <seconds>  Scan duration (default 6)
  -w, --window <secs>   How long to wait for mesh replies (default 25)
  -n, --count <n>       Test contacts to create and delete for `bulkdelete` (default 12)

NOTES
  `bulkdelete` writes to the radio. It creates its own contacts, deletes only
  those, and asserts every pre-existing contact survived — it never deletes a
  real one. Leftovers from an interrupted run are named `meshctl-del-NN` and
  are removed on the next run.

  Mesh replies travel over LoRa and are slow — a telemetry round trip can take
  20s or more. The default window is deliberately generous.
"""

// MARK: - Shared helpers

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func parseHexPrefix(_ s: String) -> Data? {
    let cleaned = s.replacingOccurrences(of: " ", with: "").lowercased()
    guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
    var bytes = [UInt8]()
    var idx = cleaned.startIndex
    while idx < cleaned.endIndex {
        let next = cleaned.index(idx, offsetBy: 2)
        guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
        bytes.append(b)
        idx = next
    }
    return Data(bytes)
}

/// Connect and complete the same handshake the app performs, so the radio is in
/// the state it would be in during normal use.
func connectAndHandshake(_ opts: Options) async throws -> BLELink {
    let link = BLELink()
    try await link.waitForPowerOn()
    try await link.connect(nameFilter: opts.device, scanTimeout: opts.scanSeconds)

    // Same order as ConnectionManager: APP_START, then DEVICE_QUERY.
    _ = await link.request(MeshCoreProtocol.buildAppStart(), window: 2.5)
    _ = await link.request(MeshCoreProtocol.buildDeviceQuery(), window: 2.5)
    return link
}

/// Pull the contact list, which the smoke test needs in order to address a repeater.
func fetchContacts(_ link: BLELink) async -> [Contact] {
    let frames = await link.request(MeshCoreProtocol.buildGetContacts(since: 0), window: 6)
    var contacts: [Contact] = []
    for frame in frames {
        if case .contact(let c) = FrameParser.parse(frame) { contacts.append(c) }
    }
    return contacts
}

/// CMD_SEND_TELEMETRY_REQ with no recipient — code(1) + 3 reserved bytes.
///
/// Firmware treats `len == 4` as a request for the node's *own* telemetry and
/// answers immediately with PUSH_CODE_TELEMETRY_RESPONSE, no mesh round trip.
/// MeshCoreKit has no builder for this because the app only ever asks remote
/// nodes, but it is the cheapest deterministic way to exercise the 1.17 MCU
/// temperature addition and the LPP parser.
func selfTelemetryFrame() -> Data {
    Data([0x27, 0x00, 0x00, 0x00])
}

func readings(in frames: [Data]) -> [TelemetryReading] {
    for frame in frames {
        if case .telemetryResponse(_, let r) = FrameParser.parse(frame) { return r }
    }
    return []
}

func describe(_ reading: TelemetryReading) -> String {
    let value = String(format: "%.2f", reading.value)
    return "\(reading.label) = \(value)\(reading.unit.isEmpty ? "" : " " + reading.unit) [ch \(reading.channel), key \(reading.key)]"
}

// MARK: - Commands

func cmdScan(_ opts: Options) async throws {
    let link = BLELink()
    try await link.waitForPowerOn()
    note("scanning \(Int(opts.scanSeconds))s…")
    let found = try await link.scan(duration: opts.scanSeconds)
    if found.isEmpty {
        out("No MeshCore radios found.")
        return
    }
    // Pad in Swift, not with %s — radio names are commonly emoji, and a C string
    // formatter mangles multi-byte characters.
    for d in found {
        let name = d.name.count < 28
            ? d.name + String(repeating: " ", count: 28 - d.name.count)
            : d.name
        out("\(name) RSSI \(d.rssi)")
    }
}

func cmdInfo(_ opts: Options) async throws {
    let link = await { () -> BLELink? in
        do { return try await connectAndHandshake(opts) } catch { note("\(error)"); return nil }
    }()
    guard let link else { exit(2) }
    defer { link.disconnect() }

    for frame in link.capturedFrames {
        switch FrameParser.parse(frame) {
        case .selfInfo(let s):
            info("radio name", s.name)
            info("public key", hex(s.publicKey.prefix(6)))
            info("radio", "\(Double(s.radioFreq) / 1000.0) MHz  SF\(s.radioSF)  CR\(s.radioCR)")
        case .deviceInfo(let d):
            info("firmware", d.semanticVersion)
            info("manufacturer", d.manufacturer)
            info("build date", d.buildDate)
            // `firmwareVersion` is the protocol version byte (FIRMWARE_VER_CODE),
            // not the semantic version — see docs/PROTOCOL.md.
            info("ver code", "\(d.firmwareVersion)")
        default:
            break
        }
    }
    let contacts = await fetchContacts(link)
    info("contacts", "\(contacts.count)")
    for c in contacts.sorted(by: { $0.type.rawValue < $1.type.rawValue }) {
        out("        \(hex(c.publicKeyPrefix))  \(c.type.displayName.padding(toLength: 9, withPad: " ", startingAt: 0))  \(c.name.isEmpty ? "(unnamed)" : c.name)")
    }
}

func cmdTelemetry(_ opts: Options) async throws {
    if opts.target == nil {
        // No target: ask the radio about itself.
        let link = try await connectAndHandshake(opts)
        defer { link.disconnect() }
        let r = readings(in: await link.request(selfTelemetryFrame(), window: 4))
        if r.isEmpty { out("No self telemetry response."); exit(3) }
        for reading in r { info("reading", describe(reading)) }
        return
    }
    guard let targetHex = opts.target, let prefix = parseHexPrefix(targetHex) else {
        note("telemetry needs --target <pubkey-prefix-hex>; run `meshctl info` to list contacts")
        exit(64)
    }
    let link = try await connectAndHandshake(opts)
    defer { link.disconnect() }

    let contacts = await fetchContacts(link)
    guard let contact = contacts.first(where: { $0.publicKey.starts(with: prefix) }) else {
        note("no contact whose public key starts with \(targetHex)")
        exit(2)
    }
    note("requesting telemetry from \(contact.name) — up to \(Int(opts.window))s over LoRa…")

    let frames = await link.request(
        MeshCoreProtocol.buildSendTelemetryReq(recipientPublicKey: contact.publicKey),
        window: opts.window
    )
    var readings: [TelemetryReading] = []
    for frame in frames {
        if case .telemetryResponse(_, let r) = FrameParser.parse(frame) { readings = r }
    }
    if readings.isEmpty {
        out("No telemetry response. Either the node is out of range, or telemetry sharing is disabled on it.")
        exit(3)
    }
    for r in readings { info("reading", describe(r)) }
}

func cmdSmoke(_ opts: Options) async throws {
    out("MeshCore firmware smoke test")
    out("")

    let link = try await connectAndHandshake(opts)
    defer { link.disconnect() }

    // --- Connection and firmware identity
    var firmware = ""
    var verCode = 0
    for frame in link.capturedFrames {
        if case .deviceInfo(let d) = FrameParser.parse(frame) {
            firmware = d.semanticVersion
            verCode = Int(d.firmwareVersion)
        }
    }
    check(!firmware.isEmpty, "connected and device query answered", detail: firmware)
    check(verCode >= 13, "FIRMWARE_VER_CODE >= 13", detail: "got \(verCode)")

    // --- Contacts: the sync path, plus whatever 1.17 now returns
    let contacts = await fetchContacts(link)
    check(!contacts.isEmpty, "contact sync returned contacts", detail: "\(contacts.count)")

    let unidentified = contacts.filter(\.isUnidentified)
    info("unidentified nodes", "\(unidentified.count) (firmware 1.17 returns ADV_TYPE_NONE entries; 0 is normal)")

    // --- Self telemetry: the headline 1.17 behaviour change, no mesh hop needed
    let selfFrames = await link.request(selfTelemetryFrame(), window: 4)
    let selfReadings = readings(in: selfFrames)
    check(!selfReadings.isEmpty, "self telemetry answered", detail: "\(selfReadings.count) readings")
    for r in selfReadings { info("self", describe(r)) }

    if !selfReadings.isEmpty {
        assertTelemetryShape(selfReadings, label: "self")
    }

    // --- Remote telemetry, only when a target is given: most public repeaters
    // will not answer a non-admin, so a failure here is not necessarily ours.
    guard opts.target != nil else {
        out("  SKIP  remote telemetry — pass --target <pubkey-prefix> to include it")
        summarise()
        return
    }

    let target: Contact?
    if let targetHex = opts.target, let prefix = parseHexPrefix(targetHex) {
        target = contacts.first(where: { $0.publicKey.starts(with: prefix) })
    } else {
        target = contacts.first(where: { $0.type == .repeater })
            ?? contacts.first(where: { $0.type == .room || $0.type == .sensor })
    }

    guard let node = target else {
        out("  SKIP  telemetry — no repeater/room/sensor contact to query (pass --target)")
        summarise()
        return
    }

    note("requesting telemetry from \(node.name) — up to \(Int(opts.window))s over LoRa…")
    let frames = await link.request(
        MeshCoreProtocol.buildSendTelemetryReq(recipientPublicKey: node.publicKey),
        window: opts.window
    )
    var readings: [TelemetryReading] = []
    for frame in frames {
        if case .telemetryResponse(_, let r) = FrameParser.parse(frame) { readings = r }
    }

    check(!readings.isEmpty, "telemetry response received from \(node.name)",
          detail: readings.isEmpty ? "no response — out of range, or sharing disabled" : "\(readings.count) readings")
    for r in readings { info("reading", describe(r)) }

    if !readings.isEmpty {
        assertTelemetryShape(readings, label: node.name)
    }

    summarise()
}

/// Assertions that must hold for any telemetry response, from any node.
func assertTelemetryShape(_ readings: [TelemetryReading], label: String) {
    // 1.17.0 appends board.getMCUTemperature() on TELEM_CHANNEL_SELF.
    let temps = readings.filter { $0.name == "Temperature" }
    check(!temps.isEmpty, "[\(label)] 1.17 MCU temperature present",
          detail: temps.isEmpty ? "no Temperature reading — firmware may predate 1.17.0" : "\(temps.count) found")

    if let t = temps.first {
        check((-40...125).contains(t.value), "[\(label)] temperature within sane die range",
              detail: String(format: "%.1f °C", t.value))
    }

    // Keys must be unique, or telemetry history silently collapses two series into one.
    let keys = readings.map(\.key)
    check(Set(keys).count == keys.count, "[\(label)] reading keys are unique",
          detail: Set(keys).count == keys.count ? "\(keys.count) distinct" : "duplicates: \(keys)")

    // A type that appears once keeps its plain name — no spurious channel suffix.
    let singles = Dictionary(grouping: readings, by: \.name).filter { $0.value.count == 1 }
    let mislabelled = singles.values.flatMap { $0 }.filter { $0.label != $0.name }
    check(mislabelled.isEmpty, "[\(label)] unique reading types keep plain labels",
          detail: mislabelled.isEmpty ? "" : mislabelled.map(\.label).joined(separator: ", "))

    // Every reading must carry a channel; 0 would mean the channel byte was lost.
    check(readings.allSatisfy { $0.channel > 0 }, "[\(label)] every reading carries an LPP channel")
}

func cmdCapture(_ opts: Options) async throws {
    let path = opts.outputPath ?? "frames-\(Int(Date().timeIntervalSince1970)).txt"
    let link = try await connectAndHandshake(opts)

    let contacts = await fetchContacts(link)
    note("captured handshake + \(contacts.count) contacts")

    if let node = contacts.first(where: { $0.type == .repeater })
        ?? contacts.first(where: { $0.type == .room || $0.type == .sensor }) {
        note("requesting telemetry from \(node.name) for capture…")
        _ = await link.request(
            MeshCoreProtocol.buildSendTelemetryReq(recipientPublicKey: node.publicKey),
            window: opts.window
        )
    }
    _ = await link.request(MeshCoreProtocol.buildGetBattAndStorage(), window: 2)
    link.disconnect()

    // One frame per line: "<opcode-name-hint> <hex>" so fixtures stay readable in diffs.
    var lines: [String] = [
        "# meshctl capture \(ISO8601DateFormatter().string(from: Date()))",
        "# one frame per line, hex. Replay with FrameParser.parse().",
    ]
    for frame in link.capturedFrames {
        lines.append(hex(frame))
    }
    try lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    out("Wrote \(link.capturedFrames.count) frames to \(path)")
}

// MARK: - Bulk delete

/// Name prefix for the contacts this test creates, so a leftover from an
/// interrupted run is identifiable and removable.
let bulkTestNamePrefix = "meshctl-del-"

/// A synthetic contact, with a key no real node can hold.
///
/// Byte 0 is 0xEE and byte 1 is the index, so prefixes are unique and visibly
/// not a real public key. Keys are unverifiable from the companion bridge
/// anyway — a contact entry is just a record.
func bulkTestContact(_ index: Int) -> Contact {
    var key = Data(repeating: 0, count: 32)
    key[0] = 0xEE
    key[1] = UInt8(index)
    key[2] = 0xEE
    for i in 3..<32 { key[i] = UInt8((index * 7 + i) & 0xFF) }
    return Contact(
        publicKey: key,
        name: "\(bulkTestNamePrefix)\(String(format: "%02d", index))",
        type: .chat,
        lastAdvert: UInt32(Date().timeIntervalSince1970)
    )
}

func addContactFrame(_ c: Contact) -> Data {
    MeshCoreProtocol.buildAddUpdateContact(
        publicKey: c.publicKey, type: c.type.rawValue, flags: c.flags,
        outPathLen: c.outPathLen, outPath: c.outPath, advName: c.name,
        lastAdvert: c.lastAdvert,
        latitude: MeshCoreProtocol.microDegrees(c.latitude),
        longitude: MeshCoreProtocol.microDegrees(c.longitude)
    )
}

/// A full contact sync, returning the announced count alongside the contacts.
///
/// The announced count is the whole point: the data-loss bug was a sync that
/// delivered fewer contacts than CONTACTS_START promised, and the app
/// believing the shortfall.
func fullSync(_ link: BLELink, window: TimeInterval = 8) async -> (announced: Int, contacts: [Contact], sawEnd: Bool) {
    let frames = await link.request(MeshCoreProtocol.buildGetContacts(since: 0), window: window)
    var announced = 0
    var contacts: [Contact] = []
    var sawEnd = false
    for frame in frames {
        switch FrameParser.parse(frame) {
        case .contactsStart(let count): announced = Int(count)
        case .contact(let c): contacts.append(c)
        case .endOfContacts: sawEnd = true
        default: break
        }
    }
    return (announced, contacts, sawEnd)
}

/// Send frames spaced out, the way the app paces removals and restores.
func sendPaced(_ link: BLELink, _ frames: [Data], spacing: TimeInterval = 0.15) async {
    for (offset, frame) in frames.enumerated() {
        link.send(frame)
        if offset < frames.count - 1 {
            try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
        }
    }
}

/// Remove every leftover test contact, whatever happened above.
func cleanUpTestContacts(_ link: BLELink) async {
    let state = await fullSync(link)
    let leftovers = state.contacts.filter { $0.name.hasPrefix(bulkTestNamePrefix) }
    guard !leftovers.isEmpty else { return }
    note("cleaning up \(leftovers.count) leftover test contact(s)")
    await sendPaced(link, leftovers.map { MeshCoreProtocol.buildRemoveContact(publicKey: $0.publicKey) })
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}

/// Add test contacts and leave them on the radio.
///
/// For driving the app's own bulk-delete and restore UI against contacts that
/// are safe to destroy, instead of the user's real ones.
func cmdSeed(_ opts: Options) async throws {
    let link = try await connectAndHandshake(opts)
    defer { link.disconnect() }

    let baseline = await fullSync(link)
    let existing = Set(baseline.contacts.map(\.publicKeyPrefix))
    let synthetic = (1...opts.bulkCount).map { bulkTestContact($0) }
        .filter { !existing.contains($0.publicKeyPrefix) }

    guard !synthetic.isEmpty else {
        out("All \(opts.bulkCount) test contacts are already present.")
        return
    }

    note("adding \(synthetic.count) test contacts…")
    await sendPaced(link, synthetic.map(addContactFrame))
    try? await Task.sleep(nanoseconds: 1_000_000_000)

    let after = await fullSync(link)
    let present = Set(after.contacts.map(\.publicKeyPrefix))
    check(
        Set(synthetic.map(\.publicKeyPrefix)).isSubset(of: present),
        "all \(synthetic.count) test contacts added",
        detail: "\(after.contacts.count) contacts on the radio"
    )
    for c in after.contacts.sorted(by: { $0.name < $1.name }) {
        out("        \(hex(c.publicKeyPrefix))  \(c.name.isEmpty ? "(unnamed)" : c.name)")
    }
    summarise()
}

/// Remove every `meshctl-del-*` contact, whatever state a run left behind.
func cmdCleanup(_ opts: Options) async throws {
    let link = try await connectAndHandshake(opts)
    defer { link.disconnect() }

    await cleanUpTestContacts(link)
    let after = await fullSync(link)
    check(
        !after.contacts.contains { $0.name.hasPrefix(bulkTestNamePrefix) },
        "no test contacts remain",
        detail: "\(after.contacts.count) contacts on the radio"
    )
    for c in after.contacts { out("        \(hex(c.publicKeyPrefix))  \(c.name.isEmpty ? "(unnamed)" : c.name)") }
    summarise()
}

/// Exercise bulk contact deletion against real firmware.
///
/// This is the one thing no unit test can cover: the data loss came from
/// CMD_REMOVE_CONTACT responses interleaving with a contact sync requested too
/// soon after, which is firmware timing. The reducer tests prove the app
/// *rejects* a truncated sync; only hardware shows whether truncation still
/// happens and whether the pacing avoids it.
///
/// Deliberately never touches a real contact: it creates its own, deletes only
/// those, and asserts the pre-existing list is untouched.
func cmdBulkDelete(_ opts: Options) async throws {
    out("MeshCore bulk-delete test")
    out("")

    let link = try await connectAndHandshake(opts)
    defer { link.disconnect() }

    let count = opts.bulkCount
    let baseline = await fullSync(link)
    check(baseline.sawEnd, "baseline sync completed", detail: "\(baseline.contacts.count) contacts")
    info("baseline", "announced \(baseline.announced), received \(baseline.contacts.count)")

    let baselineKeys = Set(baseline.contacts.map(\.publicKeyPrefix))
    let leftovers = baseline.contacts.filter { $0.name.hasPrefix(bulkTestNamePrefix) }
    if !leftovers.isEmpty {
        note("found \(leftovers.count) leftover test contact(s) from a previous run — removing first")
        await cleanUpTestContacts(link)
    }

    // --- Create the contacts this test will delete.
    //
    // This is also the first hardware exercise of the restore path: restoring
    // a backup sends exactly these frames.
    let synthetic = (1...count).map { bulkTestContact($0) }
    let syntheticKeys = Set(synthetic.map(\.publicKeyPrefix))
    guard syntheticKeys.isDisjoint(with: baselineKeys) else {
        check(false, "synthetic keys do not collide with real contacts")
        summarise()
        return
    }

    note("adding \(count) test contacts…")
    await sendPaced(link, synthetic.map(addContactFrame))
    try? await Task.sleep(nanoseconds: 1_000_000_000)

    let afterAdd = await fullSync(link)
    check(afterAdd.sawEnd, "sync after adds completed")
    check(
        afterAdd.announced == afterAdd.contacts.count,
        "sync after adds delivered everything it announced",
        detail: "announced \(afterAdd.announced), received \(afterAdd.contacts.count)"
    )
    let addedKeys = Set(afterAdd.contacts.map(\.publicKeyPrefix))
    check(
        syntheticKeys.isSubset(of: addedKeys),
        "all \(count) added contacts are on the radio",
        detail: "\(syntheticKeys.intersection(addedKeys).count)/\(count) present"
    )
    check(
        baselineKeys.isSubset(of: addedKeys),
        "adding contacts did not disturb the existing ones"
    )

    // --- Round 1: the app's sequence — paced removals, settle, then sync.
    out("")
    out("Round 1 — the app's sequence (150ms spacing, 1s settle)")
    await sendPaced(link, synthetic.map { MeshCoreProtocol.buildRemoveContact(publicKey: $0.publicKey) })
    try? await Task.sleep(nanoseconds: 1_000_000_000)

    let afterDelete = await fullSync(link)
    check(afterDelete.sawEnd, "sync after deletes completed")
    check(
        afterDelete.announced == afterDelete.contacts.count,
        "sync after deletes delivered everything it announced",
        detail: "announced \(afterDelete.announced), received \(afterDelete.contacts.count)"
    )

    let finalKeys = Set(afterDelete.contacts.map(\.publicKeyPrefix))
    check(
        finalKeys.isDisjoint(with: syntheticKeys),
        "every deleted contact is gone",
        detail: "\(finalKeys.intersection(syntheticKeys).count) still present"
    )
    // The assertion that matters: the data loss was the *survivors*
    // disappearing, not the deletions failing.
    check(
        baselineKeys.isSubset(of: finalKeys),
        "every contact that was NOT deleted survived",
        detail: "\(baselineKeys.subtracting(finalKeys).count) of \(baselineKeys.count) lost"
    )

    // What the reducer would do with this sync, which is what the app does.
    let outcome = ContactSyncReducer.reduce(
        existing: afterAdd.contacts, incoming: afterDelete.contacts,
        announced: afterDelete.announced, isIncremental: false
    )
    if case .replace = outcome {
        check(true, "reducer accepts the post-delete sync as authoritative")
    } else {
        check(false, "reducer accepts the post-delete sync as authoritative", detail: "\(outcome)")
    }

    // --- Round 2: the original bug's timing — no settle at all.
    //
    // Run to find out whether truncation still occurs when the sync is
    // requested immediately. A truncated sync here is not a failure: it is the
    // firmware behaviour the guard exists for, and the assertion is that the
    // reducer refuses it rather than collapsing the list.
    out("")
    out("Round 2 — no settle, the timing that caused the data loss")
    await sendPaced(link, synthetic.map(addContactFrame))
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let before2 = await fullSync(link)
    check(
        syntheticKeys.isSubset(of: Set(before2.contacts.map(\.publicKeyPrefix))),
        "test contacts re-added for round 2"
    )

    // No settle: sync immediately after the last removal frame.
    await sendPaced(link, synthetic.map { MeshCoreProtocol.buildRemoveContact(publicKey: $0.publicKey) })
    let racy = await fullSync(link)
    info("round 2", "announced \(racy.announced), received \(racy.contacts.count), end-of-contacts \(racy.sawEnd)")

    let racyOutcome = ContactSyncReducer.reduce(
        existing: before2.contacts, incoming: racy.contacts,
        announced: racy.announced, isIncremental: false
    )
    switch racyOutcome {
    case .replace:
        info("round 2", "sync was complete even with no settle — truncation not reproduced")
        check(
            racy.announced == racy.contacts.count,
            "unsettled sync, when accepted, was genuinely complete",
            detail: "announced \(racy.announced), received \(racy.contacts.count)"
        )
    case .rejectTruncated(let received, let announced):
        info("round 2", "truncation REPRODUCED — announced \(announced), received \(received)")
        check(true, "truncated sync is rejected, so the stored list is kept")
    case .rejectUnverifiable:
        info("round 2", "sync was unverifiable (no announced count)")
        check(true, "unverifiable sync is rejected, so the stored list is kept")
    case .merge, .noChange:
        check(false, "a full sync must not reduce to a merge", detail: "\(racyOutcome)")
    }

    // --- Round 3: the actual pre-fix sequence.
    //
    // Round 2 removed only the settle; the removals were still paced. The code
    // that lost the data did neither — it wrote every CMD_REMOVE_CONTACT back
    // to back and then asked for a full sync immediately. Both mitigations
    // have to be off to learn whether the firmware really truncates, and
    // therefore whether the reducer's guard is load-bearing or merely
    // belt-and-braces.
    out("")
    out("Round 3 — unpaced burst then immediate sync: the pre-fix sequence")
    await sendPaced(link, synthetic.map(addContactFrame))
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let before3 = await fullSync(link, window: 10)
    check(
        syntheticKeys.isSubset(of: Set(before3.contacts.map(\.publicKeyPrefix))),
        "test contacts re-added for round 3",
        detail: "\(before3.contacts.count) contacts"
    )

    for contact in synthetic {
        link.send(MeshCoreProtocol.buildRemoveContact(publicKey: contact.publicKey))
    }
    let burst = await fullSync(link, window: 10)
    info("round 3", "announced \(burst.announced), received \(burst.contacts.count), end-of-contacts \(burst.sawEnd)")

    let burstOutcome = ContactSyncReducer.reduce(
        existing: before3.contacts, incoming: burst.contacts,
        announced: burst.announced, isIncremental: false
    )
    switch burstOutcome {
    case .rejectTruncated(let received, let announced):
        info("round 3", "TRUNCATION REPRODUCED — announced \(announced), received \(received)")
        info("round 3", "pre-fix, this shortfall became the whole contact list")
        check(true, "truncated sync is rejected, so the stored list is kept")
    case .rejectUnverifiable:
        info("round 3", "sync delivered nothing verifiable")
        check(true, "unverifiable sync is rejected, so the stored list is kept")
    case .replace:
        info("round 3", "firmware stayed consistent even unpaced — truncation not reproduced here")
        check(
            burst.announced == burst.contacts.count,
            "unpaced sync, when accepted, was genuinely complete",
            detail: "announced \(burst.announced), received \(burst.contacts.count)"
        )
    case .merge, .noChange:
        check(false, "a full sync must not reduce to a merge", detail: "\(burstOutcome)")
    }

    // The finding this round actually produced: an unpaced burst loses
    // writes. Reported rather than asserted, because it measures a sequence
    // the app deliberately no longer uses, and a future firmware that fixed
    // it should not read as a regression here.
    let afterBurst = await fullSync(link, window: 10)
    let dropped = Set(afterBurst.contacts.map(\.publicKeyPrefix)).intersection(syntheticKeys)
    if dropped.isEmpty {
        info("round 3", "all \(count) unpaced removals landed")
    } else {
        info("round 3", "\(dropped.count) of \(count) unpaced removals were DROPPED — firmware lost the writes")
        info("round 3", "the sync reported this honestly, so only verification catches it, not the sync")
    }

    // What the app relies on, which is worth asserting: pacing lands every
    // removal. Round 1 already deleted the same contacts cleanly at the same
    // scale, so this re-states that as the comparison that justifies it.
    if !dropped.isEmpty {
        note("re-removing the \(dropped.count) survivor(s), paced, to confirm pacing recovers them")
        let survivors = afterBurst.contacts.filter { syntheticKeys.contains($0.publicKeyPrefix) }
        await sendPaced(link, survivors.map { MeshCoreProtocol.buildRemoveContact(publicKey: $0.publicKey) })
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let recovered = await fullSync(link, window: 10)
        check(
            Set(recovered.contacts.map(\.publicKeyPrefix)).isDisjoint(with: syntheticKeys),
            "paced retry removed every contact the unpaced burst dropped",
            detail: "\(Set(recovered.contacts.map(\.publicKeyPrefix)).intersection(syntheticKeys).count) still present"
        )
    }

    // --- Always leave the radio as we found it.
    out("")
    await cleanUpTestContacts(link)
    let restored = await fullSync(link)
    check(
        baselineKeys.isSubset(of: Set(restored.contacts.map(\.publicKeyPrefix))),
        "radio left as found: all \(baselineKeys.count) original contacts present",
        detail: "\(restored.contacts.count) contacts"
    )
    check(
        !restored.contacts.contains { $0.name.hasPrefix(bulkTestNamePrefix) },
        "no test contacts left behind"
    )

    summarise()
}

func summarise() {
    out("")
    out("\(passes.count) passed, \(failures.count) failed")
    if !failures.isEmpty {
        for f in failures { out("  failed: \(f)") }
    }
}

// MARK: - Entry point

let opts = parseArgs()
if let path = opts.reportPath { openReport(at: path) }

do {
    switch opts.command {
    case "scan":      try await cmdScan(opts)
    case "info":      try await cmdInfo(opts)
    case "telemetry": try await cmdTelemetry(opts)
    case "smoke":     try await cmdSmoke(opts)
    case "capture":   try await cmdCapture(opts)
    case "bulkdelete": try await cmdBulkDelete(opts)
    case "seed":      try await cmdSeed(opts)
    case "cleanup":   try await cmdCleanup(opts)
    case "help", "-h", "--help":
        out(usage)
    default:
        out(usage)
        exit(64)
    }
} catch {
    note("error: \(error)")
    emit("meshctl-exit: 1")
    try? reportHandle?.close()
    exit(1)
}

let exitCode: Int32 = failures.isEmpty ? 0 : 1
emit("meshctl-exit: \(exitCode)")
try? reportHandle?.close()
exit(exitCode)
