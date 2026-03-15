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
    @State private var showDiscover = false
    @State private var showConnectionFailed = false
    @State private var showAdvertSent = false
    @State private var showRemoteManagement = false
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
            } else if let chIdx = viewModel.selectedChannelIndex,
                      let channel = viewModel.channels.first(where: { $0.index == chIdx }) {
                ChannelChatView(channelIndex: channel.index, channelName: channel.name)
            } else if let contact = viewModel.selectedContact {
                switch contact.type {
                case .room:
                    RoomChatView(
                        contact: contact,
                        session: viewModel.remoteSession(for: contact)
                    )
                case .repeater:
                    RepeaterLoginView(
                        contact: contact,
                        session: viewModel.remoteSession(for: contact)
                    )
                default:
                    ChatView(contact: contact)
                }
            } else if viewModel.connectionState == .disconnected {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("Connect to a MeshCore device")
                        .foregroundStyle(MeshTheme.textSecondary)
                    Button {
                        showScanner = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Scan for Devices")
                        }
                        .foregroundStyle(MeshTheme.accentFallback)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundStyle(MeshTheme.textSecondary)
                    Text("Select a contact to start messaging")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if viewModel.connectionState == .ready {
                        viewModel.sendAdvertise(type: 0)
                        showAdvertSent = true
                    } else {
                        showScanner = true
                    }
                } label: {
                    Image(systemName: viewModel.connectionState == .ready
                          ? "antenna.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Send Advertisement — announce your presence on the mesh")
                .accessibilityLabel("Send Advertisement")
                .accessibilityHint("Announce your presence on the mesh network")

                Button {
                    showDiscover = true
                } label: {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Discover — scan for nearby mesh nodes")
                .accessibilityLabel("Discover Nearby Nodes")
                .accessibilityHint("Scan the mesh for nearby devices")
                .disabled(viewModel.connectionState != .ready)

                Button {
                    viewModel.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Refresh — re-sync contacts, channels, and settings from device")
                .accessibilityLabel("Refresh")
                .accessibilityHint("Re-sync contacts, channels, and settings from device")
                .disabled(viewModel.connectionState != .ready)

                if viewModel.hasActiveManagementSession {
                    Button {
                        showRemoteManagement = true
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(MeshTheme.accentFallback)
                    }
                    .help("Remote Management — configure remote device")
                    .accessibilityLabel("Remote Management")
                    .accessibilityHint("Open remote device management")
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .help("Device Settings — configure your local radio")
                .accessibilityLabel("Device Settings")
                .accessibilityHint("Configure your local radio settings")
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
        .sheet(isPresented: $showDiscover) {
            NavigationStack {
                DiscoverView()
                    .environmentObject(viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showDiscover = false }
                        }
                    }
            }
            .meshTheme()
            .frame(minWidth: 360, minHeight: 400)
        }
        .sheet(isPresented: $showRemoteManagement) {
            if let (contact, session) = activeManagementTarget {
                NavigationStack {
                    RemoteManagementView(contact: contact, session: session)
                        .environmentObject(viewModel)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showRemoteManagement = false }
                            }
                        }
                }
                .meshTheme()
                .frame(minWidth: 360, minHeight: 400)
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
        .alert("Advertisement Sent", isPresented: $showAdvertSent) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your device advertisement has been broadcast to the mesh network.")
        }
        .onOpenURL { url in
            let urlString = url.absoluteString
            if urlString.hasPrefix("meshcore://") {
                viewModel.importContact(url: urlString)
            }
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

    /// Find the first logged-in remote management target for the toolbar wrench button.
    private var activeManagementTarget: (Contact, RemoteDeviceSession)? {
        for contact in viewModel.contacts where contact.type == .repeater || contact.type == .room {
            let session = viewModel.remoteSession(for: contact)
            if case .loggedIn = session.loginState {
                return (contact, session)
            }
        }
        return nil
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
