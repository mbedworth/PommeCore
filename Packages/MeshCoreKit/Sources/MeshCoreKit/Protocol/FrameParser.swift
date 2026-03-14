import Foundation
import os.log

/// Parses incoming binary frames from the MeshCore device.
public enum FrameParser {

    private static let logger = Logger(subsystem: "com.meshcore", category: "FrameParser")

    /// Parsed response from the device.
    public enum ParsedResponse: Sendable {
        case ok
        case error(code: UInt8, description: String)
        case selfInfo(SelfInfoPayload)
        case deviceInfo(DeviceInfoPayload)
        case battAndStorage(BattStoragePayload)
        case currentTime(UInt32)
        case tuningParams(rxDelayBase: UInt32, airtimeFactor: UInt32)
        case customVars(String)
        case stats(subType: UInt8, payload: Data)
        case contactsStart(count: UInt32)             // RESP_CODE_CONTACTS_START (code 2)
        case contact(Contact)                          // RESP_CODE_CONTACT (code 3)
        case endOfContacts(lastmod: UInt32)            // RESP_CODE_END_OF_CONTACTS (code 4)
        case sent(type: UInt8, expectedACK: UInt32, suggestedTimeout: UInt32) // RESP_CODE_SENT (code 6)
        case contactMsgRecv(Message)                   // RESP_CODE_CONTACT_MSG_RECV_V3 (code 16)
        case channelMsgRecv(Message)                   // RESP_CODE_CHANNEL_MSG_RECV_V3 (code 17)
        case noMoreMessages                            // RESP_CODE_NO_MORE_MESSAGES (code 10)
        case currentAdvert(Data)
        case rawMeshPacket(Data)
        case sendConfirmed(ackCode: UInt32, roundTripMs: UInt32)  // PUSH_CODE_SEND_CONFIRMED (0x82)
        case msgWaiting                                // PUSH_CODE_MSG_WAITING (0x83)
        case advert(Contact)                           // PUSH_CODE_ADVERT (0x80)
        case loginSuccess(permissionLevel: Int)         // PUSH_CODE_LOGIN_SUCCESS (0x85)
        case loginFail                                 // PUSH_CODE_LOGIN_FAIL (0x86)
        case unknown(type: UInt8, payload: Data)
    }

    // MARK: - Payload Structs

    /// RESP_CODE_SELF_INFO (code 5) — returned after CMD_APP_START.
    public struct SelfInfoPayload: Sendable {
        public let type: UInt8
        public let txPower: UInt8
        public let maxTXPower: UInt8
        public let publicKey: Data
        public let latitude: Double
        public let longitude: Double
        public let multiACK: UInt8
        public let advertLocPolicy: UInt8
        public let telemetryByte: UInt8
        public let manualAddContacts: UInt8
        public let radioFreq: UInt32
        public let radioBW: UInt32
        public let radioSF: UInt8
        public let radioCR: UInt8
        public let name: String
        public let rawData: Data
    }

    /// RESP_CODE_DEVICE_INFO (code 13) — returned after CMD_DEVICE_QUERY.
    public struct DeviceInfoPayload: Sendable {
        public let firmwareVersion: UInt8
        public let maxContactsDiv2: UInt8
        public let maxChannels: UInt8
        public let blePIN: UInt32
        public let buildDate: String
        public let manufacturer: String
        public let semanticVersion: String
        public let rawData: Data
    }

    /// RESP_CODE_BATT_AND_STORAGE (code 12).
    public struct BattStoragePayload: Sendable {
        public let batteryMV: UInt16
    }

    // MARK: - Parse

    public static func parse(_ data: Data) -> ParsedResponse {
        guard let firstByte = data.first else {
            return .unknown(type: 0, payload: Data())
        }

        let payload = Data(data.dropFirst())
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.info("Parse frame [\(data.count) bytes] code=0x\(String(format: "%02x", firstByte)): \(hex)")

        // Check push codes first (high bit set, 0x80-0x8F range)
        if firstByte >= 0x80 && firstByte <= 0x8F {
            if let pushCode = MeshCorePushCode(rawValue: firstByte) {
                switch pushCode {
                case .advert:
                    return parseAdvertPush(payload)
                case .sendConfirmed:
                    return parseSendConfirmed(payload)
                case .msgWaiting:
                    return .msgWaiting
                case .loginSuccess:
                    let permissions = payload.first ?? 0
                    let permissionLevel = Int(permissions & 0x03)
                    logger.info("LoginSuccess: permissionLevel=\(permissionLevel)")
                    return .loginSuccess(permissionLevel: permissionLevel)
                case .loginFail:
                    logger.info("LoginFail")
                    return .loginFail
                }
            }
            // Unknown push code in the notification range — log and ignore
            logger.debug("Received push notification 0x\(String(format: "%02x", firstByte)) (undocumented), \(payload.count) bytes payload")
            return .unknown(type: firstByte, payload: payload)
        }

        guard let code = MeshCoreResponseCode(rawValue: firstByte) else {
            logger.warning("Unknown response code 0x\(String(format: "%02x", firstByte))")
            return .unknown(type: firstByte, payload: payload)
        }

        switch code {
        case .ok:
            return .ok

        case .err:
            let errCode = payload.first ?? 0
            let errEnum = MeshCoreErrorCode(rawValue: errCode)
            let desc = errEnum?.description ?? "Unknown error (\(errCode))"
            logger.warning("RESP_CODE_ERR: code=\(errCode) (\(desc))")
            return .error(code: errCode, description: desc)

        case .selfInfo:
            return parseSelfInfo(payload)

        case .deviceInfo:
            return parseDeviceInfoResponse(payload)

        case .battAndStorage:
            return parseBattAndStorage(payload)

        case .currTime:
            return parseCurrentTime(payload)

        case .tuningParams:
            return parseTuningParams(payload)

        case .customVars:
            let str = String(data: payload, encoding: .utf8) ?? ""
            return .customVars(str)

        case .stats:
            let subType: UInt8 = payload.isEmpty ? 0 : payload[0]
            return .stats(subType: subType, payload: Data(payload.dropFirst()))

        case .contactsStart:
            return parseContactsStart(payload)

        case .contact:
            return parseContactFull(payload)

        case .endOfContacts:
            return parseEndOfContacts(payload)

        case .sent:
            return parseSentResponse(payload)

        case .contactMsgRecv:
            return parseContactMsgRecv(payload)

        case .contactMsgRecvV3:
            return parseContactMsgRecvV3(payload)

        case .channelMsgRecvV3:
            return parseChannelMsgRecvV3(payload)

        case .noMoreMessages:
            return .noMoreMessages

        case .currentAdvert:
            return .currentAdvert(payload)

        case .rawMeshPacket:
            return .rawMeshPacket(payload)
        }
    }

    // MARK: - Self Info (code 5)

    private static func parseSelfInfo(_ data: Data) -> ParsedResponse {
        var offset = 0

        let type = readUInt8(data, offset: &offset)
        let txPower = readUInt8(data, offset: &offset)
        let maxTXPower = readUInt8(data, offset: &offset)

        let pubKeyLen = min(32, data.count - offset)
        let publicKey: Data
        if pubKeyLen > 0 {
            publicKey = Data(data[offset..<offset+pubKeyLen])
            offset += pubKeyLen
        } else {
            publicKey = Data()
        }

        let latRaw = readInt32(data, offset: &offset)
        let lonRaw = readInt32(data, offset: &offset)
        let latitude = Double(latRaw) / 1_000_000.0
        let longitude = Double(lonRaw) / 1_000_000.0

        let multiACK = readUInt8(data, offset: &offset)
        let advertLocPolicy = readUInt8(data, offset: &offset)
        let telemetryByte = readUInt8(data, offset: &offset)
        let manualAddContacts = readUInt8(data, offset: &offset)

        let freq = readUInt32(data, offset: &offset)
        let bw = readUInt32(data, offset: &offset)
        let sf = readUInt8(data, offset: &offset)
        let cr = readUInt8(data, offset: &offset)

        let name: String
        if offset < data.count {
            name = String(data: Data(data[offset...]), encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
        } else {
            name = ""
        }

        logger.info("SelfInfo: type=\(type) txPwr=\(txPower)/\(maxTXPower) lat=\(latitude) lon=\(longitude) freq=\(freq) bw=\(bw) sf=\(sf) cr=\(cr) name='\(name)'")

        let payload = SelfInfoPayload(
            type: type,
            txPower: txPower,
            maxTXPower: maxTXPower,
            publicKey: publicKey,
            latitude: latitude,
            longitude: longitude,
            multiACK: multiACK,
            advertLocPolicy: advertLocPolicy,
            telemetryByte: telemetryByte,
            manualAddContacts: manualAddContacts,
            radioFreq: freq,
            radioBW: bw,
            radioSF: sf,
            radioCR: cr,
            name: name,
            rawData: data
        )
        return .selfInfo(payload)
    }

    // MARK: - Device Info (code 13)

    private static func parseDeviceInfoResponse(_ data: Data) -> ParsedResponse {
        var offset = 0

        let firmwareVer = readUInt8(data, offset: &offset)
        let maxContactsDiv2 = readUInt8(data, offset: &offset)
        let maxChannels = readUInt8(data, offset: &offset)
        let blePIN = readUInt32(data, offset: &offset)

        let buildDate = readFixedString(data, offset: &offset, maxLen: 12)
        let manufacturer = readFixedString(data, offset: &offset, maxLen: 40)
        let semanticVersion = readFixedString(data, offset: &offset, maxLen: 20)

        logger.info("DeviceInfo: fwVer=\(firmwareVer) maxContacts=\(Int(maxContactsDiv2) * 2) maxCh=\(maxChannels) blePIN=\(blePIN) buildDate='\(buildDate)' mfg='\(manufacturer)' semVer='\(semanticVersion)'")

        let payload = DeviceInfoPayload(
            firmwareVersion: firmwareVer,
            maxContactsDiv2: maxContactsDiv2,
            maxChannels: maxChannels,
            blePIN: blePIN,
            buildDate: buildDate,
            manufacturer: manufacturer,
            semanticVersion: semanticVersion,
            rawData: data
        )
        return .deviceInfo(payload)
    }

    // MARK: - Battery & Storage (code 12)

    private static func parseBattAndStorage(_ data: Data) -> ParsedResponse {
        var offset = 0
        let batt = readUInt16(data, offset: &offset)
        logger.info("BattAndStorage: \(batt) mV")
        return .battAndStorage(BattStoragePayload(batteryMV: batt))
    }

    // MARK: - Time (code 9)

    private static func parseCurrentTime(_ data: Data) -> ParsedResponse {
        var offset = 0
        let epoch = readUInt32(data, offset: &offset)
        return .currentTime(epoch)
    }

    // MARK: - Tuning Params (code 23)

    private static func parseTuningParams(_ data: Data) -> ParsedResponse {
        var offset = 0
        let rxDelay = readUInt32(data, offset: &offset)
        let airtime = readUInt32(data, offset: &offset)
        logger.info("TuningParams: rxDelay=\(rxDelay) airtime=\(airtime)")
        return .tuningParams(rxDelayBase: rxDelay, airtimeFactor: airtime)
    }

    // MARK: - Contacts Protocol

    /// RESP_CODE_CONTACTS_START (code 2) — start of contact list.
    /// Layout: count(uint32)
    private static func parseContactsStart(_ data: Data) -> ParsedResponse {
        var offset = 0
        let count = readUInt32(data, offset: &offset)
        logger.info("ContactsStart: count=\(count)")
        return .contactsStart(count: count)
    }

    /// RESP_CODE_CONTACT (code 3) — individual contact data.
    /// Layout: publicKey(32) type(1) flags(1) outPathLen(1 signed) outPath(64)
    ///         advName(32 null-terminated) lastAdvert(uint32) advLat(int32) advLon(int32) lastmod(uint32)
    private static func parseContactFull(_ data: Data) -> ParsedResponse {
        var offset = 0

        // public_key: 32 bytes
        let keyLen = min(32, data.count - offset)
        let publicKey: Data
        if keyLen > 0 {
            publicKey = Data(data[offset..<offset+keyLen])
            offset += keyLen
        } else {
            publicKey = Data()
        }

        // type: 1 byte
        let contactType = readUInt8(data, offset: &offset)

        // flags: 1 byte
        let flags = readUInt8(data, offset: &offset)

        // out_path_len: 1 byte (signed)
        let outPathLen = Int8(bitPattern: readUInt8(data, offset: &offset))

        // out_path: 64 bytes (skip — routing data, not needed by app)
        let skipLen = min(64, data.count - offset)
        offset += skipLen

        // adv_name: 32 bytes null-terminated fixed field
        let name = readFixedString(data, offset: &offset, maxLen: 32)

        // last_advert: uint32 (epoch seconds)
        let lastAdvert = readUInt32(data, offset: &offset)

        // adv_lat: int32 (degrees × 1,000,000)
        let latRaw = readInt32(data, offset: &offset)
        let latitude = Double(latRaw) / 1_000_000.0

        // adv_lon: int32 (degrees × 1,000,000)
        let lonRaw = readInt32(data, offset: &offset)
        let longitude = Double(lonRaw) / 1_000_000.0

        // lastmod: uint32
        let lastmod = readUInt32(data, offset: &offset)

        let type = ContactType(rawValue: contactType) ?? .unknown

        logger.info("Contact: name='\(name)' type=\(contactType) flags=\(flags) pathLen=\(outPathLen) lastAdvert=\(lastAdvert) lat=\(latitude) lon=\(longitude) lastmod=\(lastmod)")

        let contact = Contact(
            publicKey: publicKey,
            name: name,
            type: type,
            flags: flags,
            outPathLen: outPathLen,
            lastAdvert: lastAdvert,
            latitude: latitude,
            longitude: longitude,
            lastmod: lastmod
        )
        return .contact(contact)
    }

    /// RESP_CODE_END_OF_CONTACTS (code 4) — end of contact list.
    /// Layout: most_recent_lastmod(uint32)
    private static func parseEndOfContacts(_ data: Data) -> ParsedResponse {
        var offset = 0
        let lastmod = readUInt32(data, offset: &offset)
        logger.info("EndOfContacts: lastmod=\(lastmod)")
        return .endOfContacts(lastmod: lastmod)
    }

    // MARK: - Messages

    /// RESP_CODE_SENT (code 6) — device accepted our message for sending.
    /// Layout: type(1) expected_ack(uint32) suggested_timeout(uint32 ms)
    private static func parseSentResponse(_ data: Data) -> ParsedResponse {
        var offset = 0
        let type = readUInt8(data, offset: &offset)
        let expectedACK = readUInt32(data, offset: &offset)
        let suggestedTimeout = readUInt32(data, offset: &offset)
        logger.info("Sent: type=\(type) expectedACK=\(expectedACK) timeout=\(suggestedTimeout)ms")
        return .sent(type: type, expectedACK: expectedACK, suggestedTimeout: suggestedTimeout)
    }

    /// RESP_CODE_CONTACT_MSG_RECV_V3 (code 16) — received direct message.
    /// Layout: SNR(1) reserved(2) pubkey_prefix(6) path_len(1) txt_type(1) sender_timestamp(uint32) text
    private static func parseContactMsgRecvV3(_ data: Data) -> ParsedResponse {
        var offset = 0
        let snr = Int8(bitPattern: readUInt8(data, offset: &offset))
        _ = readUInt8(data, offset: &offset) // reserved byte 1
        _ = readUInt8(data, offset: &offset) // reserved byte 2
        let pubkeyPrefix = data.count >= offset + 6 ? Data(data[offset..<offset+6]) : Data()
        offset += min(6, data.count - offset)
        _ = readUInt8(data, offset: &offset) // path_len
        let txtType = readUInt8(data, offset: &offset)
        let senderTimestamp = readUInt32(data, offset: &offset)
        let text: String
        if offset < data.count {
            text = String(data: Data(data[offset...]), encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
        } else {
            text = ""
        }

        let timestamp = senderTimestamp > 0
            ? Date(timeIntervalSince1970: TimeInterval(senderTimestamp))
            : Date()

        logger.info("ContactMsgRecvV3: snr=\(snr) txtType=\(txtType) from=\(pubkeyPrefix.map { String(format: "%02x", $0) }.joined()) text='\(text)'")

        let message = Message(
            senderKeyHash: pubkeyPrefix,
            contactKeyHash: pubkeyPrefix,
            text: text,
            timestamp: timestamp,
            isOutgoing: false,
            status: .delivered,
            snr: snr,
            txtType: txtType
        )
        return .contactMsgRecv(message)
    }

    /// RESP_CODE_CHANNEL_MSG_RECV_V3 (code 17) — received channel message.
    /// Layout: SNR(1) reserved(1) channel_idx(1) path_len(1) txt_type(1) sender_timestamp(uint32)
    ///         sender_name(null-terminated) text(remaining)
    private static func parseChannelMsgRecvV3(_ data: Data) -> ParsedResponse {
        var offset = 0
        let snr = Int8(bitPattern: readUInt8(data, offset: &offset))
        _ = readUInt8(data, offset: &offset) // reserved
        let channelIdx = readUInt8(data, offset: &offset)
        _ = readUInt8(data, offset: &offset) // path_len
        _ = readUInt8(data, offset: &offset) // txt_type
        let senderTimestamp = readUInt32(data, offset: &offset)

        // sender_name is null-terminated, text is the remainder
        let senderName = readNullTerminated(data, offset: &offset)
        let text: String
        if offset < data.count {
            text = String(data: Data(data[offset...]), encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
        } else {
            text = ""
        }

        let timestamp = senderTimestamp > 0
            ? Date(timeIntervalSince1970: TimeInterval(senderTimestamp))
            : Date()

        logger.info("ChannelMsgRecvV3: snr=\(snr) ch=\(channelIdx) sender='\(senderName)' text='\(text)'")

        let message = Message(
            senderKeyHash: Data(),
            contactKeyHash: Data([channelIdx]),
            text: text,
            timestamp: timestamp,
            isOutgoing: false,
            status: .delivered,
            snr: snr,
            channelIndex: channelIdx,
            senderName: senderName.isEmpty ? nil : senderName
        )
        return .channelMsgRecv(message)
    }

    /// PUSH_CODE_SEND_CONFIRMED (0x82) — ACK received for a sent message.
    /// Layout: ack_code(uint32) round_trip(uint32 ms)
    private static func parseSendConfirmed(_ data: Data) -> ParsedResponse {
        var offset = 0
        let ackCode = readUInt32(data, offset: &offset)
        let roundTrip = readUInt32(data, offset: &offset)
        logger.info("SendConfirmed: ackCode=\(ackCode) roundTrip=\(roundTrip)ms")
        return .sendConfirmed(ackCode: ackCode, roundTripMs: roundTrip)
    }

    /// PUSH_CODE_ADVERT (0x80) — new advertisement received, contains contact data.
    /// Same binary layout as RESP_CODE_CONTACT.
    private static func parseAdvertPush(_ data: Data) -> ParsedResponse {
        // Advert push uses the same contact binary format
        let contactResponse = parseContactFull(data)
        if case .contact(let contact) = contactResponse {
            return .advert(contact)
        }
        return .unknown(type: MeshCorePushCode.advert.rawValue, payload: data)
    }

    /// RESP_CODE_CONTACT_MSG_RECV (code 7) — received direct message (old/v1 format).
    /// Layout: pubkey_prefix(6) path_len(1) txt_type(1) sender_timestamp(uint32) text(varchar)
    private static func parseContactMsgRecv(_ data: Data) -> ParsedResponse {
        var offset = 0

        // pubkey_prefix: 6 bytes
        let pubkeyPrefix = data.count >= offset + 6 ? Data(data[offset..<offset+6]) : Data()
        offset += min(6, data.count - offset)

        // path_len: 1 byte (0xFF = direct)
        _ = readUInt8(data, offset: &offset)

        // txt_type: 1 byte (0 = plain, 1 = CLI_DATA)
        let txtType = readUInt8(data, offset: &offset)

        // sender_timestamp: uint32
        let senderTimestamp = readUInt32(data, offset: &offset)

        // text: remainder of frame
        let text: String
        if offset < data.count {
            text = String(data: Data(data[offset...]), encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) ?? ""
        } else {
            text = ""
        }

        let timestamp = senderTimestamp > 0
            ? Date(timeIntervalSince1970: TimeInterval(senderTimestamp))
            : Date()

        logger.info("ContactMsgRecv(v1): from=\(pubkeyPrefix.map { String(format: "%02x", $0) }.joined()) txtType=\(txtType) text='\(text)'")

        let message = Message(
            senderKeyHash: pubkeyPrefix,
            contactKeyHash: pubkeyPrefix,
            text: text,
            timestamp: timestamp,
            isOutgoing: false,
            status: .delivered,
            txtType: txtType
        )
        return .contactMsgRecv(message)
    }

    // MARK: - Binary Read Helpers

    private static func readUInt8(_ data: Data, offset: inout Int) -> UInt8 {
        guard offset < data.count else { return 0 }
        let v = data[offset]
        offset += 1
        return v
    }

    private static func readUInt16(_ data: Data, offset: inout Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        var v: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+2)
        }
        offset += 2
        return UInt16(littleEndian: v)
    }

    private static func readUInt32(_ data: Data, offset: inout Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+4)
        }
        offset += 4
        return UInt32(littleEndian: v)
    }

    private static func readInt32(_ data: Data, offset: inout Int) -> Int32 {
        guard offset + 4 <= data.count else { return 0 }
        var v: Int32 = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+4)
        }
        offset += 4
        return Int32(littleEndian: v)
    }

    private static func readFloat(_ data: Data, offset: inout Int) -> Float {
        guard offset + 4 <= data.count else { return 0 }
        var v: Float = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<offset+4)
        }
        offset += 4
        return v
    }

    /// Read a fixed-length null-terminated C string (reads exactly maxLen bytes, returns up to null).
    private static func readFixedString(_ data: Data, offset: inout Int, maxLen: Int) -> String {
        let available = min(maxLen, data.count - offset)
        guard available > 0 else { return "" }
        let slice = data[offset..<offset+available]
        offset += available
        if let nullIdx = slice.firstIndex(of: 0x00) {
            return String(data: data[slice.startIndex..<nullIdx], encoding: .utf8) ?? ""
        }
        return String(data: Data(slice), encoding: .utf8) ?? ""
    }

    private static func readNullTerminated(_ data: Data, offset: inout Int) -> String {
        guard offset < data.count else { return "" }
        let slice = data[offset...]
        if let nullIdx = slice.firstIndex(of: 0x00) {
            let str = String(data: data[offset..<nullIdx], encoding: .utf8) ?? ""
            offset = nullIdx + 1
            return str
        }
        let str = String(data: Data(slice), encoding: .utf8) ?? ""
        offset = data.count
        return str
    }
}
