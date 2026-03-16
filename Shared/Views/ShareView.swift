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

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                QRCodeView(
                    content: channelURL,
                    label: "Share \(channel.name)"
                )
                Text("Scan this QR code or share the link to join this channel.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
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
