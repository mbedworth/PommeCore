import SwiftUI
import CoreImage.CIFilterBuiltins
import MeshCoreKit

// MARK: - QR Code Generator

#if !os(watchOS)
struct QRCodeView: View {
    let content: String
    let label: String

    var body: some View {
        VStack(spacing: 16) {
            if let image = generateQRCode(from: content) {
                #if os(macOS)
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                #else
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                #endif
            }

            Text(label)
                .font(.headline)
                .foregroundStyle(MeshTheme.textPrimary)

            Text(content)
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Button {
                #if os(iOS)
                UIPasteboard.general.string = content
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
                #endif
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
                    .foregroundStyle(MeshTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    #if os(macOS)
    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: transform)
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
    #else
    private func generateQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .ascii) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: transform)
        return UIImage(ciImage: scaled)
    }
    #endif
}
#endif

// MARK: - QR Code Camera Scanner (iOS only)

#if os(iOS)
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            showError("Camera not available")
            return
        }

        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // Scan target overlay
        let guide = UIView()
        guide.layer.borderColor = UIColor.white.cgColor
        guide.layer.borderWidth = 2
        guide.layer.cornerRadius = 12
        guide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guide)
        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            guide.widthAnchor.constraint(equalToConstant: 250),
            guide.heightAnchor.constraint(equalToConstant: 250),
        ])

        let hint = UILabel()
        hint.text = "Point camera at a meshcore:// QR code"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 14)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: 20),
        ])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue,
              string.hasPrefix("meshcore://") else { return }
        hasScanned = true
        captureSession.stopRunning()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCodeScanned?(string)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stopRunning()
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
#endif

// MARK: - Share Contact Sheet

#if !os(watchOS)
struct ShareContactSheet: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportedURL: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let url = exportedURL {
                    QRCodeView(
                        content: url,
                        label: "Share \(viewModel.displayName(for: contact))"
                    )
                    Text("Scan this QR code or share the link to add this contact.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    ProgressView()
                        .tint(MeshTheme.accent)
                    Text("Generating contact link...")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Share Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                viewModel.exportContact(contact)
            }
            .onReceive(viewModel.$lastExportedURL) { url in
                if let url, !url.isEmpty {
                    exportedURL = url
                    viewModel.lastExportedURL = nil
                }
            }
        }
        .meshTheme()
    }
}
#endif

// MARK: - My Contact Code Sheet

#if !os(watchOS)
struct MyContactCodeSheet: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportedURL: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let url = exportedURL {
                    QRCodeView(
                        content: url,
                        label: viewModel.deviceConfig.deviceName.isEmpty ? "My Contact Code" : viewModel.deviceConfig.deviceName
                    )
                    Text("Others can scan this QR code to add you as a contact.")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    ProgressView()
                        .tint(MeshTheme.accent)
                    Text("Generating contact code...")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("My Contact Code")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                viewModel.exportSelfContact()
            }
            .onReceive(viewModel.$lastExportedURL) { url in
                if let url, !url.isEmpty {
                    exportedURL = url
                    viewModel.lastExportedURL = nil
                }
            }
        }
        .meshTheme()
    }
}
#endif

// MARK: - Share Channel Sheet

#if !os(watchOS)
struct ShareChannelSheet: View {
    let channel: MeshChannel
    @Environment(\.dismiss) private var dismiss

    /// Build a meshcore:// channel URL.
    /// Format: meshcore://channel?name=NAME&secret=HEX (secret optional)
    private var channelURL: String {
        var url = "meshcore://channel?name=\(channel.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channel.name)"
        if let secret = channel.secret {
            url += "&secret=\(secret.map { String(format: "%02x", $0) }.joined())"
        }
        return url
    }

    private var secretHex: String? {
        channel.secret?.map { String(format: "%02x", $0) }.joined()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRCodeView(
                    content: channelURL,
                    label: "Share \(channel.name)"
                )

                if channel.secret == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Channel secret not available locally. Recipients will need the secret separately to join.")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .padding(.horizontal)
                }

                // Action buttons
                VStack(spacing: 10) {
                    if let hex = secretHex {
                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = hex
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(hex, forType: .string)
                            #endif
                        } label: {
                            Label("Copy Secret", systemImage: "key")
                                .foregroundStyle(MeshTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    #if os(iOS)
                    Button {
                        let av = UIActivityViewController(activityItems: [channelURL], applicationActivities: nil)
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let root = scene.windows.first?.rootViewController {
                            root.present(av, animated: true)
                        }
                    } label: {
                        Label("Share via AirDrop / Messages", systemImage: "square.and.arrow.up")
                            .foregroundStyle(MeshTheme.accent)
                    }
                    .buttonStyle(.plain)
                    #endif
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Share Channel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .meshTheme()
    }
}
#endif
