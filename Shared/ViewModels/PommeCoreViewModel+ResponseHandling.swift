//
//  PommeCoreViewModel+ResponseHandling.swift
//  PommeCore
//
//  Frame dispatch from radio to stores, message handling, sync flow.
//
//  Created by Michael P. Bedworth on 3/29/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation
import os.log
import MeshCoreKit
#if !os(watchOS)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Response Handling
// Extracted from PommeCoreViewModel — dispatches parsed frames to stores.

extension PommeCoreViewModel {

    static let routineResponseCodes: Set<UInt8> = [
        0x00, 0x02, 0x03, 0x04, 0x09, 0x0A, 0x0C, 0x12,
        0x17, 0x18, 0x19, 0x80, 0x81, 0x83, 0x88,
    ]

    func handleReceivedData(_ data: Data) {
        let hex = data.hexFormatted()
        Self.logger.info("RX [\(data.count)]: \(hex)")
        let code = data.first ?? 0
        if !Self.routineResponseCodes.contains(code) {
            DebugLogger.shared.log("RX [\(data.count)B] \(hex)", level: .rx)
        }

        let response = FrameParser.parse(data)

        switch response {
        case .ok:
            Self.logger.info("RESP OK — last command accepted by device")

        case .error(let code, let description):
            Self.logger.warning("Error response: code=\(code) \(description)")
            DebugLogger.shared.log("RESP ERR code=\(code) \(description)", level: .error)
            handleErrorResponse(code: code, description: description)

        case .selfInfo(let info):
            Self.logger.info("PARSED SelfInfo: name='\(info.name)' txPwr=\(info.txPower)/\(info.maxTXPower) freq=\(info.radioFreq) bw=\(info.radioBW) sf=\(info.radioSF) cr=\(info.radioCR) lat=\(info.latitude) lon=\(info.longitude)")
            let freqStr = formatFrequency(Double(info.radioFreq))
            let bwKHz = String(format: "%.1f", Double(info.radioBW) / 1000.0)
            let keyHex = Data(info.publicKey.prefix(8)).hexCompact
            DebugLogger.shared.log("RADIO: freq=\(freqStr) BW=\(bwKHz)kHz SF=\(info.radioSF) CR=\(info.radioCR) TX=\(info.txPower)/\(info.maxTXPower)dBm", level: .rx)
            DebugLogger.shared.log("RADIO: name='\(info.name)' type=\(info.type) pubkey=\(keyHex)...", level: .rx)
            DebugLogger.shared.log("RADIO: lat=\(info.latitude) lon=\(info.longitude) multiACK=\(info.multiACK) advLoc=\(info.advertLocPolicy)", level: .rx)
            deviceConfig.deviceName = info.name
            deviceConfig.selfType = info.type
            deviceConfig.radioTXPower = info.txPower
            deviceConfig.maxTXPower = info.maxTXPower
            deviceConfig.publicKeyHex = info.publicKey.hexCompact
            deviceConfig.loadBatteryCalibration()
            let radioPrefix = String(deviceConfig.publicKeyHex.prefix(12))
            messageStoreManager.activateForRadio(radioPrefix)
            channelStore.activateForRadio(radioPrefix)
            contactStore.loadNicknamesFromiCloud()
            contactStore.loadContactNotesFromiCloud()
            #if !os(watchOS)
            telemetryCloudSync.radioPrefix = radioPrefix
            telemetryCloudSync.migrateIfNeeded(telemetryHistory: rfMonitorStore.telemetryHistory)
            telemetryCloudSync.fetchFromCloud()
            #endif
            deviceConfig.latitude = info.latitude
            deviceConfig.longitude = info.longitude
            deviceConfig.radioFrequency = info.radioFreq
            deviceConfig.radioBandwidth = info.radioBW
            deviceConfig.radioSpreadingFactor = info.radioSF
            deviceConfig.radioCodingRate = info.radioCR
            deviceConfig.manualAddContacts = info.manualAddContacts
            deviceConfig.telemetryBase = info.telemetryByte & 0x03
            deviceConfig.telemetryLocation = (info.telemetryByte >> 2) & 0x03
            deviceConfig.advertLocPolicy = info.advertLocPolicy
            deviceConfig.multiACK = info.multiACK
            deviceConfig.loadedSections.insert("selfInfo")
            checkLoadingComplete()

            let epoch = Date().epochUInt32
            connectionManager.sendCommand(MeshCoreProtocol.buildSetDeviceTime(epochSeconds: epoch), label: "SET_TIME(auto)")
            DebugLogger.shared.log("CLOCK: auto-synced device time to \(epoch)", level: .info)

            #if !os(watchOS)
            let mapOptIn = UserDefaults.standard.bool(forKey: "shareOnMeshMap")
            let hasLocation = info.latitude != 0 || info.longitude != 0
            if mapOptIn, hasLocation {
                pendingMapUpload = true
                connectionManager.sendCommand(Data([0x11]), label: "EXPORT_SELF(map)")
                DebugLogger.shared.log("MAP: triggered self-export for upload", level: .info)
            }
            #endif

        case .deviceInfo(let info):
            Self.logger.info("PARSED DeviceInfo: fwVer=\(info.firmwareVersion) buildDate='\(info.buildDate)' mfg='\(info.manufacturer)' semVer='\(info.semanticVersion)' blePIN=\(info.blePIN)")
            DebugLogger.shared.log("DEVICE: fw=\(info.firmwareVersion) ver='\(info.semanticVersion)' build='\(info.buildDate)'", level: .rx)
            DebugLogger.shared.log("DEVICE: mfg='\(info.manufacturer)' maxContacts=\(Int(info.maxContactsDiv2) * 2) maxCh=\(info.maxChannels) PIN=\(info.blePIN)", level: .rx)
            deviceConfig.firmwareVersion = String(info.firmwareVersion)
            deviceConfig.buildDate = info.buildDate
            deviceConfig.manufacturer = info.manufacturer
            deviceConfig.semanticVersion = info.semanticVersion
            deviceConfig.blePIN = info.blePIN
            deviceConfig.maxContacts = UInt16(info.maxContactsDiv2) * 2
            deviceConfig.maxChannels = info.maxChannels
            deviceConfig.loadedSections.insert("deviceInfo")
            checkLoadingComplete()

        case .battAndStorage(let info):
            Self.logger.info("PARSED BattAndStorage: \(info.batteryMV) mV")
            deviceConfig.batteryMillivolts = info.batteryMV
            let chemRaw = UserDefaults.standard.string(forKey: "batteryChemistry") ?? BatteryChemistry.lipo.rawValue
            let chem = BatteryChemistry(rawValue: chemRaw) ?? .lipo
            deviceConfig.updateBatteryCalibration(rawMillivolts: info.batteryMV, chemistry: chem)
            deviceConfig.loadedSections.insert("battAndStorage")
            checkLoadingComplete()

        case .currentTime(let epoch):
            Self.logger.info("PARSED Time: epoch=\(epoch)")
            deviceConfig.deviceTimeEpoch = epoch
            deviceConfig.loadedSections.insert("time")
            checkLoadingComplete()

        case .tuningParams(let rxDelay, let airtime):
            Self.logger.info("PARSED Tuning: rxDelay=\(rxDelay) airtime=\(airtime)")
            DebugLogger.shared.log("TUNING: rxDelay=\(String(format: "%.1f", Double(rxDelay) / 1000.0))s airtime=\(String(format: "%.1f", Double(airtime) / 1000.0))x (raw: \(rxDelay), \(airtime))", level: .rx)
            deviceConfig.rxDelayBase = rxDelay
            deviceConfig.airtimeFactor = airtime
            deviceConfig.loadedSections.insert("tuning")
            checkLoadingComplete()

        case .customVars(let str):
            Self.logger.info("PARSED CustomVars: '\(str)'")
            let pairs = str.split(separator: ",").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
            deviceConfig.customVars = pairs
            deviceConfig.loadedSections.insert("customVars")
            checkLoadingComplete()

        case .stats(let subType, let payload):
            Self.logger.info("PARSED Stats subType=\(subType), \(payload.count) bytes")
            parseStats(subType: subType, payload: payload)
            deviceConfig.loadedSections.insert("stats")
            checkLoadingComplete()

        case .autoAddConfig(let bitmask, let maxHops):
            Self.logger.info("PARSED AutoAddConfig: bitmask=0x\(String(format: "%02x", bitmask)) maxHops=\(maxHops)")
            deviceConfig.autoAddBitmask = bitmask
            deviceConfig.autoAddMaxHops = maxHops

        case .defaultFloodScope(let name):
            Self.logger.info("PARSED DefaultFloodScope: '\(name)'")
            deviceConfig.defaultFloodScope = name

        case .contactsStart(let count):
            contactStore.handleContactsStart(count: count)

        case .contact(let contact):
            contactStore.handleContact(contact)

        case .endOfContacts(let lastmod):
            let shouldSyncChannels = contactStore.handleEndOfContacts(lastmod: lastmod)
            if shouldSyncChannels && !channelStore.hasCompletedInitialChannelSync {
                channelStore.syncChannels(maxChannels: deviceConfig.maxChannels)
                channelStore.hasCompletedInitialChannelSync = true
            }

        case .sent(let type, let expectedACK, let suggestedTimeout):
            Self.logger.info("PARSED Sent: type=\(type) expectedACK=\(expectedACK) timeout=\(suggestedTimeout)ms")
            DebugLogger.shared.log("Sent: type=\(type == 0 ? "direct" : "flood") ack=\(expectedACK) timeout=\(suggestedTimeout)ms", level: .rx)
            remoteSessionManager.handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeout)
            messageStoreManager.handleSentResponse(expectedACK: expectedACK, suggestedTimeoutMs: suggestedTimeout)

        case .contactMsgRecv(let message):
            Self.logger.info("Received direct message: \(message.text)")
            DebugLogger.shared.log("DM RX: '\(message.text.prefix(60))'", level: .rx)
            handleIncomingMessage(message)
            if messageStoreManager.isSyncingMessages { syncNextMessage() }
            #if os(iOS)
            if !message.isOutgoing { syncWidget() }
            #endif

        case .channelMsgRecv(let message):
            Self.logger.info("CHANNEL RX: ch=\(message.channelIndex ?? 0) isOutgoing=\(message.isOutgoing) sender='\(message.senderName ?? "?")' text='\(message.text.prefix(40))'")
            DebugLogger.shared.log("CH RX: ch=\(message.channelIndex ?? 0) from='\(message.senderName ?? "?")' '\(message.text.prefix(40))'", level: .rx)
            handleIncomingMessage(message)
            if messageStoreManager.isSyncingMessages { syncNextMessage() }
            #if os(iOS)
            if !message.isOutgoing { syncWidget() }
            #endif

        case .noMoreMessages:
            Self.logger.debug("No more messages")
            messageStoreManager.isSyncingMessages = false

        case .sendConfirmed(let ackCode, let roundTripMs):
            Self.logger.info("PARSED SendConfirmed: ackCode=\(ackCode) roundTrip=\(roundTripMs)ms")
            DebugLogger.shared.log("ACK confirmed: \(roundTripMs)ms", level: .rx)
            if let contactKey = messageStoreManager.handleSendConfirmed(ackCode: ackCode, roundTripMs: roundTripMs) {
                contactStore.touchContact(publicKeyPrefix: contactKey)
                // Firmware may have updated the path during delivery — sync to pick it up
                contactStore.requestDebouncedIncrementalSync()
            }

        case .msgWaiting:
            Self.logger.info("PARSED MsgWaiting — syncing next message")
            syncNextMessage()

        case .loginSuccess(let permissionLevel):
            Self.logger.info("PUSH LoginSuccess: permissionLevel=\(permissionLevel)")
            if let contactKey = remoteSessionManager.handleLoginSuccess(permissionLevel: permissionLevel) {
                contactStore.touchContact(publicKeyPrefix: contactKey)
                // Auto-request status for infrastructure devices after login (battery/uptime)
                if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == contactKey }),
                   contact.type == .repeater || contact.type == .room || contact.type == .sensor {
                    remoteSessionManager.requestStatus(for: contact, silent: true)
                }
            }

        case .loginFail:
            Self.logger.info("PUSH LoginFail")
            remoteSessionManager.handleLoginFail()

        case .advert(let contact):
            Self.logger.debug("PUSH Advert from: \(contact.name)")
            // If manual add is on and this is an unknown contact, route to pending
            let isKnown = contactStore.contacts.contains { $0.publicKeyPrefix == contact.publicKeyPrefix }
            if !isKnown && deviceConfig.manualAddContacts != 0 {
                contactStore.handleNewAdvert(contact, isInBackground: connectionManager.isInBackground)
            } else {
                contactStore.handleAdvert(contact)
            }
            if remoteSessionManager.isDiscovering {
                remoteSessionManager.addAdvertAsDiscoveredNode(contact)
            }
            contactStore.requestDebouncedIncrementalSync()

        case .pathUpdated:
            contactStore.requestDebouncedIncrementalSync()

        case .newAdvert(let contact):
            contactStore.handleNewAdvert(contact, isInBackground: connectionManager.isInBackground)
            if remoteSessionManager.isDiscovering {
                remoteSessionManager.addAdvertAsDiscoveredNode(contact)
            }

        case .statusResponse(let info):
            Self.logger.info("PUSH StatusResponse: batt=\(info.batteryMV)mV uptime=\(info.uptime)")
            remoteSessionManager.handleStatusResponse(info)

        case .traceData(let result):
            Self.logger.info("PUSH TraceData: tag=\(result.tag) hops=\(result.hops.count)")
            DebugLogger.shared.log("TRACE: \(result.hops.count) hops received", level: .rx)
            remoteSessionManager.handleTraceData(result)

        case .telemetryResponse(let senderKey, let readings):
            Self.logger.info("PUSH Telemetry: \(readings.count) readings from \(Data(senderKey.prefix(6)).hexCompact)")
            remoteSessionManager.handleTelemetryResponse(senderKey: senderKey, readings: readings)
            #if !os(watchOS)
            rfMonitorStore.recordTelemetry(for: Data(senderKey.prefix(6)), readings: readings)
            #endif

        case .pathDiscovery(let result):
            Self.logger.info("PUSH PathDiscovery: outHops=\(result.outHopCount) inHops=\(result.inHopCount) from \(result.pubKeyPrefix.hexCompact)")
            remoteSessionManager.handlePathDiscovery(result)

        case .controlData(let snr, let rssi, let pathLen, let payload):
            Self.logger.info("PUSH ControlData: snr=\(snr) rssi=\(rssi) pathLen=\(pathLen)")
            remoteSessionManager.handleControlData(snr: snr, rssi: rssi, pathLen: pathLen, payload: payload)

        case .channelInfo(let channel):
            Self.logger.info("Channel info: idx=\(channel.index) name='\(channel.name)' secret=\(channel.secret != nil ? "present" : "none")")
            DebugLogger.shared.log("CH[\(channel.index)]: '\(channel.name)' secret=\(channel.secret != nil ? "\(channel.secret!.count)B" : "none")", level: .rx)
            channelStore.handleChannelInfo(channel)
            channelStore.checkChannelSyncComplete(maxChannels: deviceConfig.maxChannels)

        case .exportedContact(let url):
            Self.logger.info("EXPORT RESP: url='\(url.prefix(80))' (\(url.count) chars)")
            DebugLogger.shared.log("EXPORT: \(url.count) chars → \(url.prefix(60))...", level: .rx)
            if url.isEmpty {
                Self.logger.warning("EXPORT RESP: empty URL — device returned no card data")
            }
            #if !os(watchOS)
            if pendingMapUpload {
                pendingMapUpload = false
                if !url.isEmpty,
                   let dataJSON = MeshMapService.buildDataJSON(
                       exportURL: url,
                       freq: Double(deviceConfig.radioFrequency) / 1000.0,
                       bw:   Double(deviceConfig.radioBandwidth) / 1000.0,
                       sf:   Int(deviceConfig.radioSpreadingFactor),
                       cr:   Int(deviceConfig.radioCodingRate)
                   ) {
                    pendingMapDataJSON = dataJSON
                    DebugLogger.shared.log("MAP SIGN: starting device signing for \(dataJSON.count) byte payload", level: .info)
                    connectionManager.sendCommand(MeshCoreProtocol.buildSignStart(), label: "SIGN_START(map)")
                }
                return
            }
            #endif
            messageStoreManager.lastExportedURL = url

        case .advertPath(let info):
            Self.logger.info("AdvertPath: timestamp=\(info.recvTimestamp) pathLen=\(info.pathLen)")
            remoteSessionManager.handleAdvertPathResponse(info)
            messageStoreManager.handleAdvertPathForPendingSend(info)

        case .allowedRepeatFreq(let ranges):
            Self.logger.info("AllowedRepeatFreq: \(ranges.count) ranges")
            connectionManager.allowedFreqRanges = ranges
            remoteSessionManager.handleAllowedRepeatFreq(ranges)

        case .currentAdvert(let adData):
            Self.logger.debug("Current advert: \(adData.count) bytes")

        case .rawData(let pktData):
            Self.logger.debug("Raw data: \(pktData.count) bytes")

        case .contactDeleted(let publicKey):
            let name = contactStore.contacts.first(where: { $0.publicKeyPrefix == publicKey.prefix(6) })?.name ?? "Unknown"
            contactStore.handleContactDeleted(publicKey: publicKey)
            connectionManager.lastErrorMessage = "Contact \"\(name)\" was removed from device to make room for new contacts."

        case .contactsFull(let maxContacts):
            Self.logger.warning("Contact storage full: \(maxContacts)")
            connectionManager.lastErrorMessage = "Contact storage is full (\(maxContacts) contacts). New contacts cannot be added."
            postEventNotification(title: "Contact Storage Full", body: "Device has reached \(maxContacts) contacts. New contacts cannot be added.", threadId: "system")

        #if !os(watchOS)
        case .signStartResp(let maxLength):
            guard let dataJSON = pendingMapDataJSON else {
                DebugLogger.shared.log("MAP SIGN: signStart received but no pending data", level: .warning)
                break
            }
            DebugLogger.shared.log("MAP SIGN: session ready, maxLen=\(maxLength)", level: .info)
            guard let jsonBytes = dataJSON.data(using: .utf8) else { break }
            let hashBytes = Data(SHA256.hash(data: jsonBytes))
            DebugLogger.shared.log("MAP SIGN: sending \(hashBytes.count)-byte SHA-256 hash to device", level: .info)
            connectionManager.sendCommand(MeshCoreProtocol.buildSignData(chunk: hashBytes), label: "SIGN_DATA(map)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.connectionManager.sendCommand(MeshCoreProtocol.buildSignFinish(), label: "SIGN_FINISH(map)")
            }

        case .signatureResp(let signature):
            guard let dataJSON = pendingMapDataJSON else {
                DebugLogger.shared.log("MAP SIGN: signature received but no pending data", level: .warning)
                break
            }
            let sigHex = signature.hexCompact
            let pubKeyHex = deviceConfig.publicKeyHex
            DebugLogger.shared.log("MAP SIGN: got \(signature.count)-byte signature, uploading", level: .info)
            pendingMapDataJSON = nil
            MeshMapService.shared.uploadSignedNode(dataJSON: dataJSON, signatureHex: sigHex, publicKeyHex: pubKeyHex)
        #endif

        case .unknown(let type, let payload):
            if type == 0x88 {
                let snr = payload.count > 0 ? Int8(bitPattern: payload[0]) : 0
                let rssi = payload.count > 1 ? Int8(bitPattern: payload[1]) : 0
                Self.logger.debug("LOG_RX_DATA (0x88): snr=\(Float(snr)/4.0) rssi=\(rssi) rawLen=\(payload.count - 2)")
                messageStoreManager.handleLogRxData(payload)
                #if !os(watchOS)
                rfMonitorStore.recordRFSample(snr: snr, rssi: rssi)
                #endif
            } else if type >= 0x80 {
                Self.logger.debug("Ignoring push notification 0x\(String(format: "%02x", type)), \(payload.count) bytes payload")
            } else {
                Self.logger.warning("Unhandled response 0x\(String(format: "%02x", type)), \(payload.count) bytes payload")
            }
        }
    }

    // MARK: - Response Helpers

    func handleErrorResponse(code: UInt8, description: String) {
        if remoteSessionManager.handleErrorResponse(code: code, description: description) { return }
        // If there's a message stuck in .sending when the error arrives, it will never get
        // a RESP_SENT (no expectedACK → no timeout task). Mark it failed immediately.
        messageStoreManager.failPendingSendingMessage()
        switch MeshCoreErrorCode(rawValue: code) {
        case .unsupportedCmd:
            Self.logger.warning("ERR_CODE_UNSUPPORTED_CMD — firmware does not support this command (older firmware version), not user-actionable")
        case .illegalArg:
            Self.logger.warning("ERR_CODE_ILLEGAL_ARG received — likely protocol/firmware mismatch, not user-actionable")
        case .notFound, .tableFull, .badState, .fileIOError:
            connectionManager.lastErrorMessage = description
        case nil:
            connectionManager.lastErrorMessage = description
        }
    }

    func handleIncomingMessage(_ message: Message) {
        if remoteSessionManager.routeIncomingMessage(message) { return }
        // Suppress messages from blocked contacts
        if contactStore.isBlocked(publicKeyPrefix: message.contactKeyHash) { return }
        // Suppress stray messages from infrastructure nodes (late CLI responses after navigating away)
        if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == message.contactKeyHash }),
           contact.type == .repeater || contact.type == .sensor {
            return
        }
        // Touch contact activity — proves the contact is alive
        contactStore.touchContact(publicKeyPrefix: message.contactKeyHash)
        // Auto-reset stale routed path when contact is back in direct range
        if let hops = message.hops, hops == 0,
           let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == message.contactKeyHash }),
           contact.outPathLen > 0 {
            DebugLogger.shared.log("PATH AUTO-RESET: \(contact.name) sent direct msg but outPathLen=\(contact.outPathLen) — resetting", level: .info)
            contactStore.resetPath(for: contact)
        }
        messageStoreManager.isInBackground = connectionManager.isInBackground
        // Only suppress unread/notifications when the user is actively viewing the chat.
        // On macOS, scenePhase doesn't reliably detect background — use NSApplication.isActive.
        var userIsViewing = false
        if case .contact(let key) = navigationStore.sidebarSelection, key == message.contactKeyHash {
            #if os(macOS)
            userIsViewing = NSApplication.shared.isUserViewing
            #else
            userIsViewing = !connectionManager.isInBackground
            #endif
        }
        messageStoreManager.selectedContactKey = userIsViewing ? message.contactKeyHash : nil
        if let stored = messageStoreManager.handleIncomingMessage(message) {
            messageStoreManager.postLocalNotification(for: stored)
        }
    }

    func checkLoadingComplete() {
        let required: Set<String> = ["selfInfo", "deviceInfo", "battAndStorage"]
        if required.isSubset(of: deviceConfig.loadedSections) {
            deviceConfig.isLoading = false
        }
    }

    func parseStats(subType: UInt8, payload: Data) {
        var offset = 0
        switch subType {
        case 0:
            deviceConfig.statsBatteryMV = Int16(bitPattern: readUInt16(payload, offset: &offset))
            deviceConfig.statsUptime = readUInt32(payload, offset: &offset)
            deviceConfig.statsErrorFlags = readUInt16(payload, offset: &offset)
            deviceConfig.statsQueueLength = readUInt8(payload, offset: &offset)
        case 1:
            deviceConfig.statsNoiseFloor = Int16(bitPattern: readUInt16(payload, offset: &offset))
            deviceConfig.statsLastRSSI = Int8(bitPattern: readUInt8(payload, offset: &offset))
            deviceConfig.statsLastSNR = Int8(bitPattern: readUInt8(payload, offset: &offset))
            deviceConfig.statsTXAirtime = readUInt32(payload, offset: &offset)
            deviceConfig.statsRXAirtime = readUInt32(payload, offset: &offset)
        case 2:
            deviceConfig.statsPacketsReceived = readUInt32(payload, offset: &offset)
            deviceConfig.statsPacketsSent = readUInt32(payload, offset: &offset)
            deviceConfig.statsFloodCount = readUInt32(payload, offset: &offset)
            deviceConfig.statsDirectCount = readUInt32(payload, offset: &offset)
            deviceConfig.statsRecvFlood = readUInt32(payload, offset: &offset)
            deviceConfig.statsRecvDirect = readUInt32(payload, offset: &offset)
            if offset < payload.count { deviceConfig.statsReceiveErrors = readUInt32(payload, offset: &offset) }
        default:
            Self.logger.debug("Unknown stats subtype \(subType)")
        }
    }

    // MARK: - Binary Helpers

    func readUInt8(_ data: Data, offset: inout Int) -> UInt8 {
        guard offset < data.count else { return 0 }
        let v = data[offset]; offset += 1; return v
    }

    func readUInt16(_ data: Data, offset: inout Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        var v: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+2)
        }
        offset += 2; return UInt16(littleEndian: v)
    }

    func readUInt32(_ data: Data, offset: inout Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+4)
        }
        offset += 4; return UInt32(littleEndian: v)
    }
}
