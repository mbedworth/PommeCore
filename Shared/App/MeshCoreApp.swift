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
            if newPhase == .active {
                viewModel.updateAppBadge()
            }
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
            ContactListView(
                showScanner: $showScanner,
                showDiscover: $showDiscover,
                showSettings: $showSettings,
                showRemoteManagement: $showRemoteManagement,
                showAdvertSent: $showAdvertSent
            )
        } detail: {
            switch viewModel.sidebarSelection {
            case .publicChannel:
                ChannelChatView(channelIndex: 0, channelName: "Public Channel")
            case .channel(let chIdx):
                if let channel = viewModel.channels.first(where: { $0.index == chIdx }) {
                    ChannelChatView(channelIndex: channel.index, channelName: channel.name)
                } else {
                    ChannelChatView(channelIndex: chIdx, channelName: "Channel \(chIdx)")
                }
            case .contact(let key):
                if let contact = viewModel.contacts.first(where: { $0.publicKeyPrefix == key }) {
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
                } else {
                    Text("Contact not found")
                }
            case .settings:
                SettingsView()
                    .environmentObject(viewModel)
            case nil:
                if viewModel.connectionState == .disconnected {
                    VStack(spacing: 16) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("No Radio Connected")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Turn on your MeshCore radio and tap the button below to scan for nearby devices.")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan for Devices", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MeshTheme.interactiveGreen)
                        .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(MeshTheme.textSecondary)
                        Text("Select a Contact")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Choose a contact or channel from the sidebar to start messaging.")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
