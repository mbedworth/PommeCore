//
//  ProfileExportService.swift
//  PommeCore
//
//  Builds MeshProfileExport from live store state and applies an imported profile
//  back to a connected radio. Commands are spaced 300 ms apart to avoid lockup.
//

import Foundation
import MeshCoreKit

enum ProfileExportService {

    // MARK: - Export

    @MainActor
    static func buildExport(deviceConfig: DeviceConfig,
                            channelStore: ChannelStore,
                            contacts: [Contact]?,
                            appVersion: String) -> MeshProfileExport {
        let radio = MeshProfileRadio(
            deviceName: deviceConfig.deviceName,
            advertName: deviceConfig.deviceName,
            radioFrequency: deviceConfig.radioFrequency,
            radioBandwidth: deviceConfig.radioBandwidth,
            radioSpreadingFactor: deviceConfig.radioSpreadingFactor,
            radioCodingRate: deviceConfig.radioCodingRate,
            radioTXPower: deviceConfig.radioTXPower,
            repeatMode: deviceConfig.repeatMode,
            manualAddContacts: deviceConfig.manualAddContacts,
            telemetryBase: deviceConfig.telemetryBase,
            telemetryLocation: deviceConfig.telemetryLocation,
            advertLocPolicy: deviceConfig.advertLocPolicy,
            multiACK: deviceConfig.multiACK,
            autoAddBitmask: deviceConfig.autoAddBitmask,
            defaultFloodScope: deviceConfig.defaultFloodScope,
            rxDelayBase: deviceConfig.rxDelayBase,
            airtimeFactor: deviceConfig.airtimeFactor
        )

        let channels: [MeshProfileChannel] = channelStore.channels.map { ch in
            let hex = ch.secret.map { $0.hexCompact }
            return MeshProfileChannel(index: ch.index, name: ch.name,
                                      flags: ch.flags, secretHex: hex)
        }

        return MeshProfileExport(
            version: MeshProfileExport.currentVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            radio: radio,
            channels: channels,
            contacts: contacts,
            privateKeyHex: nil,     // reserved — serial-only, not available here
            exportedWithPIN: nil
        )
    }

    static func exportData(from profile: MeshProfileExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(profile)
    }

    static func exportURL(from profile: MeshProfileExport, radioName: String) throws -> URL {
        let data = try exportData(from: profile)
        let safe = radioName.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_",
                                                   options: .regularExpression)
        let name = safe.isEmpty ? "radio" : safe
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).meshprofile")
        // Protected because this can carry the whole contact list — names,
        // public keys and advertised positions. It is a staging file for the
        // share sheet or save panel; the caller deletes it once that is done.
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: - Import

    static func parseImport(from url: URL) throws -> MeshProfileExport {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeshProfileExport.self, from: data)
    }

    /// Apply a profile to the connected radio.
    ///
    /// `applyContacts` is separate from the profile carrying them: a file may
    /// hold contacts the user does not want added to *this* radio, and adding
    /// someone else's contacts is a change they should choose rather than
    /// inherit from a file.
    @MainActor
    @discardableResult
    static func applyProfile(_ profile: MeshProfileExport,
                              connectionManager: ConnectionManager,
                              channelStore: ChannelStore,
                              contactStore: ContactStore,
                              applyContacts: Bool = false) async -> ApplyOutcome {
        let r = profile.radio
        let delay: UInt64 = 300_000_000  // 300 ms

        /// Send one step, unless the link has gone.
        ///
        /// Hardware dropped the link part-way through an apply, and nothing
        /// noticed: every later command was written into a dead connection and
        /// the UI still said the profile had been applied. The commands are
        /// idempotent, so the fix is not to retry them but to stop and say so
        /// — a half-configured radio the user knows about is recoverable by
        /// importing again, one they do not know about is not.
        var interruptedAt: String?
        func step(_ label: String, _ send: () -> Void) async {
            guard interruptedAt == nil else { return }
            guard connectionManager.isActivelyConnected else {
                interruptedAt = label
                return
            }
            send()
            try? await Task.sleep(nanoseconds: delay)
        }

        // Contacts first, and through ContactStore so they are verified
        // against the radio afterwards.
        //
        // They used to go last, on the reasoning that settings should land
        // even if the slow part failed. Hardware inverted that: a profile
        // import sent 7 of 11 contact frames, the BLE link dropped mid-burst,
        // the remaining 4 went into a dead connection, and none of the 11
        // landed — while the UI reported success. Settings are idempotent and
        // trivially re-applied; the contact list is the data. So it goes while
        // the link is freshest, and its arrival is checked rather than
        // assumed.
        if applyContacts, let contacts = profile.contacts, !contacts.isEmpty {
            await contactStore.addContacts(contacts)
        }

        await step(String(localized: "radio parameters")) {
            connectionManager.setRadioParams(
                frequency: r.radioFrequency, bandwidth: r.radioBandwidth,
                spreadingFactor: r.radioSpreadingFactor, codingRate: r.radioCodingRate,
                repeatMode: r.repeatMode)
        }

        await step(String(localized: "transmit power")) { connectionManager.setRadioTXPower(r.radioTXPower) }

        // Name lives in `deviceName` (populated from SELF_INFO). Older profiles
        // may carry an empty `advertName`, so fall back to it only if needed.
        // Never push an empty name — that would blank the radio's existing name.
        let nameToRestore = r.deviceName.isEmpty ? r.advertName : r.deviceName
        if !nameToRestore.isEmpty {
            await step(String(localized: "radio name")) { connectionManager.setAdvertName(nameToRestore) }
        }

        await step(String(localized: "access settings")) {
            connectionManager.setOtherParams(
                manualAddContacts: r.manualAddContacts,
                telemetryBase: r.telemetryBase,
                telemetryLocation: r.telemetryLocation,
                advertLocPolicy: r.advertLocPolicy,
                multiACK: r.multiACK)
        }

        await step(String(localized: "auto-add settings")) { connectionManager.setAutoAddConfig(bitmask: r.autoAddBitmask) }

        if !r.defaultFloodScope.isEmpty {
            await step(String(localized: "flood scope")) { connectionManager.setDefaultFloodScope(r.defaultFloodScope) }
        }

        if r.rxDelayBase > 0 || r.airtimeFactor > 0 {
            await step(String(localized: "tuning")) {
                connectionManager.setTuningParams(rxDelayBase: r.rxDelayBase,
                                                  airtimeFactor: r.airtimeFactor)
            }
        }

        for ch in profile.channels where ch.index > 0 {
            let secret = ch.secretHex.flatMap { Data(hexString: $0) }
            await step(String(format: String(localized: "channel %d"), Int(ch.index))) {
                channelStore.setChannel(index: ch.index, name: ch.name, secret: secret)
            }
        }

        // Future: when firmware adds PIN-protected binary key export —
        // if let keyHex = profile.privateKeyHex, profile.exportedWithPIN == true {
        //     connectionManager.setPrivateKey(keyHex)
        //     try? await Task.sleep(nanoseconds: delay)
        // }

        if let step = interruptedAt {
            return .interrupted(atStep: step)
        }
        return .applied
    }

    /// Whether an apply finished.
    enum ApplyOutcome: Equatable {
        case applied
        /// The link dropped before this step, so it and everything after it
        /// were never sent. The radio is part-configured.
        case interrupted(atStep: String)
    }
}
