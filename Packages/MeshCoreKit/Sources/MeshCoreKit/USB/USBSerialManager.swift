#if os(macOS)
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
    private var readSource: DispatchSourceRead?
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
            return
        }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let cfPath = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String {
                // Filter to cu.* devices (callout ports)
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
        }
    }

    // MARK: - Connect / Disconnect

    /// Connect to a serial port at the given baud rate.
    public func connect(to port: String, baudRate: speed_t = 115200) {
        guard fileDescriptor < 0 else {
            Self.logger.warning("Already connected")
            return
        }

        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            Self.logger.error("Failed to open \(port): \(String(cString: strerror(errno)))")
            return
        }

        // Configure serial port: 8N1 at specified baud rate
        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, baudRate)
        cfsetospeed(&options, baudRate)

        // 8 data bits, no parity, 1 stop bit
        options.c_cflag &= ~UInt(PARENB)
        options.c_cflag &= ~UInt(CSTOPB)
        options.c_cflag &= ~UInt(CSIZE)
        options.c_cflag |= UInt(CS8)
        options.c_cflag |= UInt(CLOCAL | CREAD)

        // Raw mode — no echo, no canonical processing
        options.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        options.c_oflag &= ~UInt(OPOST)

        // Minimum 1 byte, no timeout
        options.c_cc.16 = 1  // VMIN
        options.c_cc.17 = 0  // VTIME

        tcsetattr(fd, TCSANOW, &options)

        // Clear non-blocking after configuration
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        fcntl(fd, F_SETFL, flags)

        fileDescriptor = fd
        readBuffer = Data()

        // Set up async read
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serialQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        source.resume()
        readSource = source

        DispatchQueue.main.async {
            self.isConnected = true
            self.connectedPort = port
            self.detectedMode = .unknown
            Self.logger.info("Connected to \(port)")
        }

        // Probe device type after brief delay
        serialQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.probeDeviceType()
        }
    }

    /// Disconnect from the current serial port.
    public func disconnect() {
        readSource?.cancel()
        readSource = nil

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPort = nil
            self.detectedMode = .unknown
            Self.logger.info("Disconnected")
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

    private func readAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fileDescriptor, &buffer, buffer.count)
        guard bytesRead > 0 else {
            if bytesRead == 0 {
                // EOF — port closed
                DispatchQueue.main.async { [weak self] in
                    self?.disconnect()
                }
            }
            return
        }

        readBuffer.append(contentsOf: buffer[0..<bytesRead])

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
    }

    private func detectMode() {
        guard !readBuffer.isEmpty else { return }

        // Check for binary marker `>` (0x3E)
        if readBuffer[0] == 0x3E {
            DispatchQueue.main.async {
                self.detectedMode = .binary
                Self.logger.info("Detected binary companion mode")
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
