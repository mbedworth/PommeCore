// USB Serial on iOS/iPadOS: NOT currently possible.
// iOS does not expose CDC ACM serial devices to apps. The ExternalAccessory framework
// requires MFi certification (ESP32/Heltec devices are not MFi-certified). IOKit is
// macOS-only. As of iOS 18, there is no public API for USB serial communication with
// generic USB CDC ACM devices. Meshtastic iOS uses BLE only, not USB serial.
// If Apple adds DriverKit for iOS or exposes USB serial APIs in a future iOS version,
// this would need a separate USBSerialManager implementation using that framework.

#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Combine
import IOKit
import IOKit.serial
import os.log

/// Manages USB serial communication with MeshCore devices.
///
/// Supports two modes:
/// - **Binary (companion)**: Frames wrapped with `<` (0x3C) + length(2 LE) + payload (inbound)
///   and `>` (0x3E) + length(2 LE) + payload (outbound).
/// - **CLI (repeater/room)**: Plain text commands terminated by newline.
public final class USBSerialManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.meshcore", category: "USB")

    // MARK: - Published State

    @Published public private(set) var availablePorts: [String] = []
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var connectedPort: String?
    @Published public private(set) var detectedMode: DeviceMode = .unknown

    /// Publisher for incoming binary frames (companion mode).
    public let receivedDataSubject = PassthroughSubject<Data, Never>()

    /// Publisher for incoming CLI text lines (CLI mode).
    public let receivedLineSubject = PassthroughSubject<String, Never>()

    public enum DeviceMode: Equatable, Sendable {
        case unknown
        case binary   // Companion radio — binary protocol
        case cli      // Repeater/room server — text CLI
    }

    // MARK: - Private

    private var fileDescriptor: Int32 = -1
    private var readBuffer = Data()
    private let serialQueue = DispatchQueue(label: "com.meshcore.serial", qos: .userInitiated)

    public init() {}

    // MARK: - Port Discovery

    /// Scan for available serial ports using IOKit.
    public func scanPorts() {
        var ports: [String] = []
        let matchingDict = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matchingDict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else {
            Self.logger.warning("Failed to enumerate serial ports: \(result)")
            DebugLogger.shared.log("USB SCAN: IOKit enumeration failed (\(result))", level: .error)
            return
        }

        var allPaths: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let cfPath = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String {
                allPaths.append(cfPath)
                // Include all /dev/cu.* devices (callout ports)
                // Common USB-serial chips: CP2102, CH340, CH9102, FTDI
                // Port names: cu.usbmodem*, cu.usbserial*, cu.SLAB_USBtoUART*, cu.wchusbserial*
                if cfPath.contains("/dev/cu.") {
                    ports.append(cfPath)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        DispatchQueue.main.async {
            self.availablePorts = ports.sorted()
            Self.logger.info("Found \(ports.count) serial port(s)")
            DebugLogger.shared.log("USB SCAN: \(ports.count) ports found: \(ports.isEmpty ? "(none)" : ports.joined(separator: ", "))", level: .info)
            if !allPaths.isEmpty && ports.isEmpty {
                DebugLogger.shared.log("USB SCAN: IOKit found \(allPaths.count) devices but none matched /dev/cu.*: \(allPaths.joined(separator: ", "))", level: .warning)
            }
        }
    }

    // MARK: - Connect / Disconnect

    /// Connect to a serial port at the given baud rate.
    public func connect(to port: String, baudRate: speed_t = 115200) {
        guard fileDescriptor < 0 else {
            Self.logger.warning("Already connected")
            return
        }

        // Open WITHOUT O_NONBLOCK — some USB CDC devices don't work with it
        let fd = open(port, O_RDWR | O_NOCTTY)
        guard fd >= 0 else {
            Self.logger.error("Failed to open \(port): \(String(cString: strerror(errno)))")
            DebugLogger.shared.log("USB: open failed: \(String(cString: strerror(errno)))", level: .error)
            return
        }

        // Configure: raw mode only, skip baud rate (native USB CDC ignores it)
        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        options.c_cflag |= UInt(CLOCAL | CREAD)
        options.c_cc.16 = 1  // VMIN
        options.c_cc.17 = 0  // VTIME
        tcsetattr(fd, TCSANOW, &options)

        DebugLogger.shared.log("USB: port opened (blocking, raw mode, no baud set)", level: .info)

        fileDescriptor = fd
        readBuffer = Data()

        DispatchQueue.main.async {
            self.isConnected = true
            self.connectedPort = port
            self.detectedMode = .unknown
            DebugLogger.shared.log("USB: connected to \(port)", level: .info)
        }

        // Send a bare newline to flush any pending input buffer on the device
        "\r\n".data(using: .utf8)!.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = write(fd, base, 2)
            }
        }
        DebugLogger.shared.log("USB: sent \\r\\n to flush device input buffer", level: .tx)

        // Synchronous read loop on background thread — replaces DispatchSourceRead
        // which was not firing for USB CDC devices.
        // Use fd (local, set synchronously) not isConnected (@Published, set async on main).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            DebugLogger.shared.log("USB: sync read loop started on fd=\(fd)", level: .info)

            while self.fileDescriptor >= 0 {
                let bytesRead = read(fd, &buffer, 1024)
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    let hex = data.prefix(40).map { String(format: "%02X", $0) }.joined(separator: " ")
                    DebugLogger.shared.log("USB RX: \(bytesRead) bytes: \(hex)\(bytesRead > 40 ? "..." : "")", level: .rx)
                    self.handleReceivedData(data)
                } else if bytesRead == 0 {
                    DebugLogger.shared.log("USB: EOF — device disconnected", level: .warning)
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    DebugLogger.shared.log("USB: read error \(errno): \(String(cString: strerror(errno)))", level: .error)
                    break
                }
            }

            DebugLogger.shared.log("USB: read loop ended", level: .info)
            DispatchQueue.main.async { [weak self] in
                self?.disconnect()
            }
        }

        // Probe sequence with escalating approaches:
        // 1s: Send $$ (for CLI devices)
        serialQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.detectedMode == .unknown, self.fileDescriptor >= 0 else { return }
            DebugLogger.shared.log("USB PROBE 1: sending $$ (CLI probe)", level: .tx)
            self.probeDeviceType()
        }

        // 3s: Send framed binary CMD_DEVICE_QUERY: < + len + [0x16, 0x03]
        serialQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.detectedMode == .unknown, self.fileDescriptor >= 0 else { return }
            DebugLogger.shared.log("USB PROBE 2: sending framed binary CMD_DEVICE_QUERY", level: .tx)
            self.sendFrame(Data([0x16, 0x03]))
        }

        // 5s: Send RAW binary CMD_DEVICE_QUERY without framing (in case device doesn't use <> framing)
        serialQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.detectedMode == .unknown, self.fileDescriptor >= 0 else { return }
            DebugLogger.shared.log("USB PROBE 3: sending RAW binary (no framing): 16 03", level: .tx)
            let raw = Data([0x16, 0x03])
            raw.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(self.fileDescriptor, base, raw.count)
            }
        }

        // 7s: Assert DTR/RTS and try framed probe again
        serialQueue.asyncAfter(deadline: .now() + 7.0) { [weak self] in
            guard let self, self.detectedMode == .unknown, self.fileDescriptor >= 0 else { return }
            DebugLogger.shared.log("USB PROBE 4: asserting DTR/RTS + framed binary probe", level: .tx)
            var modemBits: CInt = TIOCM_DTR | TIOCM_RTS
            _ = ioctl(self.fileDescriptor, TIOCMBIS, &modemBits)
            self.sendFrame(Data([0x16, 0x03]))
        }

        // 10s: Final timeout
        serialQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self, self.detectedMode == .unknown else { return }
            DebugLogger.shared.log("USB: ALL PROBES FAILED after 10s — device not responding. Try: 1) unplug/replug device 2) press reset button 3) check if another app has the port open", level: .error)
        }
    }

    /// Disconnect from the current serial port.
    public func disconnect() {
        guard isConnected || fileDescriptor >= 0 else { return }

        let stack = Thread.callStackSymbols.prefix(6).joined(separator: "\n")
        DebugLogger.shared.log("USB: disconnect called from:\n\(stack)", level: .warning)

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPort = nil
            self.detectedMode = .unknown
            Self.logger.info("Disconnected")
            DebugLogger.shared.log("USB: disconnected — state cleared", level: .info)
        }
    }

    // MARK: - Send

    /// Send a binary frame with USB serial framing: `<` + length(2 LE) + frame data.
    public func sendFrame(_ frame: Data) {
        guard fileDescriptor >= 0 else { return }
        var framedData = Data([0x3C]) // '<' inbound marker
        var length = UInt16(frame.count).littleEndian
        framedData.append(Data(bytes: &length, count: 2))
        framedData.append(frame)

        let txHex = framedData.map { String(format: "%02X", $0) }.joined(separator: " ")
        DebugLogger.shared.log("USB RAW TX: \(framedData.count) bytes: \(txHex)", level: .tx)

        serialQueue.async { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            framedData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(self.fileDescriptor, base, framedData.count)
            }
            Self.logger.debug("TX [\(frame.count) bytes]")
        }
    }

    /// Send a CLI text command (terminated with newline).
    public func sendCLI(_ command: String) {
        guard fileDescriptor >= 0 else { return }
        guard let data = "\(command)\r\n".data(using: .utf8) else { return }

        serialQueue.async { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(self.fileDescriptor, base, data.count)
            }
            Self.logger.debug("TX CLI: \(command)")
        }
    }

    // MARK: - Read

    /// Called from the synchronous read loop with received data.
    private func handleReceivedData(_ data: Data) {
        readBuffer.append(data)

        switch detectedMode {
        case .unknown:
            detectMode()
        case .binary:
            parseBinaryFrames()
        case .cli:
            parseCLILines()
        }
    }

    // MARK: - Device Detection

    /// Send `$$` to probe if this is a CLI device or binary companion.
    private func probeDeviceType() {
        guard fileDescriptor >= 0 else { return }
        // Send $$ which triggers a response on CLI devices
        let probe = "$$\r\n".data(using: .utf8)!
        probe.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = write(fileDescriptor, base, probe.count)
        }
        Self.logger.info("Sent probe '$$' to detect device type")
        DebugLogger.shared.log("USB: sent probe '$$' for mode detection", level: .tx)
    }

    private func detectMode() {
        guard !readBuffer.isEmpty else { return }

        // Check for binary marker `>` (0x3E)
        if readBuffer[0] == 0x3E {
            DispatchQueue.main.async {
                self.detectedMode = .binary
                Self.logger.info("Detected binary companion mode")
                DebugLogger.shared.log("USB: detected BINARY mode (companion radio)", level: .info)
            }
            parseBinaryFrames()
            return
        }

        // If we have text data (printable ASCII or newlines), it's CLI mode
        let hasText = readBuffer.contains(where: { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D })
        if hasText {
            DispatchQueue.main.async {
                self.detectedMode = .cli
                Self.logger.info("Detected CLI mode")
                DebugLogger.shared.log("USB: detected CLI mode (repeater/room)", level: .info)
            }
            parseCLILines()
        }
    }

    private func parseBinaryFrames() {
        while readBuffer.count >= 3 {
            guard readBuffer[0] == 0x3E else {
                // Skip garbage bytes until we find a frame marker
                if let idx = readBuffer.firstIndex(of: 0x3E) {
                    readBuffer.removeFirst(idx)
                } else {
                    readBuffer.removeAll()
                    return
                }
                continue
            }

            var length: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &length) { dest in
                readBuffer.copyBytes(to: dest, from: 1..<3)
            }
            length = UInt16(littleEndian: length)

            let totalNeeded = 3 + Int(length)
            guard readBuffer.count >= totalNeeded else { return } // Wait for more data

            let frameData = Data(readBuffer[3..<totalNeeded])
            readBuffer.removeFirst(totalNeeded)

            Self.logger.debug("RX binary frame [\(frameData.count) bytes]")
            DispatchQueue.main.async { [weak self] in
                self?.receivedDataSubject.send(frameData)
            }
        }
    }

    private func parseCLILines() {
        while let newlineIdx = readBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(readBuffer[readBuffer.startIndex..<newlineIdx])
            readBuffer.removeFirst(newlineIdx - readBuffer.startIndex + 1)

            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters) {
                guard !line.isEmpty else { continue }
                Self.logger.debug("RX CLI: \(line)")
                DispatchQueue.main.async { [weak self] in
                    self?.receivedLineSubject.send(line)
                }
            }
        }
    }
}
#endif
