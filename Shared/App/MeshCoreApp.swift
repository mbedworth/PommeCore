import SwiftUI
import MeshCoreKit

@main
struct MeshCoreApp: App {
    @StateObject private var viewModel = MeshCoreViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .meshTheme()
        }
        .onChange(of: scenePhase) { newPhase in
            viewModel.isInBackground = (newPhase != .active)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @State private var showScanner = false
    @State private var showSettings = false
    @State private var showConnectionFailed = false
    @State private var previousConnectionState: BLEConnectionState = .disconnected
    @State private var hasRequestedAutoScan = false

    var body: some View {
        #if os(watchOS)
        NavigationStack {
            ContactListView(showScanner: $showScanner)
                .sheet(isPresented: $showScanner) {
                    NavigationStack {
                        DeviceScannerView()
                            .environmentObject(viewModel)
                    }
                }
                .onAppear { requestAutoScanOnce() }
                .onChange(of: viewModel.connectionState) { newState in
                    handleConnectionStateChange(newState)
                }
                .alert("Connection Failed", isPresented: $showConnectionFailed) {
                    Button("Retry") { showScanner = true }
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Could not connect to the device. Would you like to scan again?")
                }
                .alert("Device Error", isPresented: showErrorBinding) {
                    Button("OK", role: .cancel) { viewModel.lastErrorMessage = nil }
                } message: {
                    Text(viewModel.lastErrorMessage ?? "Unknown error")
                }
        }
        #else
        NavigationSplitView {
            ContactListView(showScanner: $showScanner)
        } detail: {
            if viewModel.showPublicChannel {
                ChannelChatView(channelIndex: 0, channelName: "Public Channel")
            } else if let contact = viewModel.selectedContact {
                if contact.type == .repeater || contact.type == .room {
                    RemoteManagementView(
                        contact: contact,
                        session: viewModel.remoteSession(for: contact)
                    )
                } else {
                    ChatView(contact: contact)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("Select a contact")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Scan for devices")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                DeviceScannerView()
                    .environmentObject(viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showScanner = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 400)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 400)
        }
        .onAppear { requestAutoScanOnce() }
        .onChange(of: viewModel.connectionState) { newState in
            handleConnectionStateChange(newState)
        }
        .alert("Connection Failed", isPresented: $showConnectionFailed) {
            Button("Retry") { showScanner = true }
            Button("OK", role: .cancel) { }
        } message: {
            Text("Could not connect to the device. Would you like to scan again?")
        }
        .alert("Device Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) { viewModel.lastErrorMessage = nil }
        } message: {
            Text(viewModel.lastErrorMessage ?? "Unknown error")
        }
        #endif
    }

    /// Request auto-scan on first launch. The ViewModel waits for BLE poweredOn
    /// before actually starting the scan. Shows scanner sheet immediately.
    private func requestAutoScanOnce() {
        guard !hasRequestedAutoScan else { return }
        hasRequestedAutoScan = true

        // If already connected (e.g. state restoration), don't show scanner
        if viewModel.connectionState == .ready || viewModel.connectionState == .connected {
            return
        }
        // If reconnecting via state restoration, don't interrupt
        if viewModel.connectionState == .connecting {
            return
        }

        showScanner = true
        viewModel.requestAutoScan()
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastErrorMessage != nil },
            set: { if !$0 { viewModel.lastErrorMessage = nil } }
        )
    }

    private func handleConnectionStateChange(_ newState: BLEConnectionState) {
        // Auto-dismiss scanner when connection succeeds
        if newState == .ready || newState == .connected {
            showScanner = false
        }
        // Show failure alert if connection drops during connecting
        if newState == .disconnected && previousConnectionState == .connecting {
            showConnectionFailed = true
        }
        previousConnectionState = newState
    }
}
