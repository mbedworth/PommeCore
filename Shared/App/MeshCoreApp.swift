import SwiftUI
import UserNotifications
import LocalAuthentication
import MeshCoreKit

@main
struct MeshCoreApp: App {
    @StateObject private var viewModel = MeshCoreViewModel()
    @StateObject private var appLock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if !hasCompletedOnboarding {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                    .meshTheme()
            } else if appLock.appLockEnabled && !appLock.isUnlocked {
                AppLockView(appLock: appLock)
                    .meshTheme()
            } else {
                ContentView()
                    .environmentObject(viewModel)
                    .meshTheme()
                    #if os(iOS)
                    .onAppear { appDelegate.viewModel = viewModel }
                    #endif
            }
        }
        .onChange(of: scenePhase) { newPhase in
            viewModel.isInBackground = (newPhase != .active)
            if newPhase == .active {
                viewModel.updateAppBadge()
                if appLock.appLockEnabled && !appLock.isUnlocked {
                    appLock.authenticate()
                }
            }
            if newPhase == .background && appLock.appLockEnabled {
                appLock.isUnlocked = false
            }
        }
    }
}

#if os(iOS)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var viewModel: MeshCoreViewModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "REPLY_ACTION",
           let textResponse = response as? UNTextInputNotificationResponse,
           let pubkeyHex = response.notification.request.content.userInfo["contactPubkey"] as? String {
            Task { @MainActor in
                viewModel?.handleNotificationReply(text: textResponse.userText, contactPubkeyHex: pubkeyHex)
            }
        }
        completionHandler()
    }
}
#endif

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
            #if !os(watchOS)
            case .map:
                if #available(iOS 17.0, macOS 14.0, *) {
                    MeshMapView()
                } else {
                    Text("Map requires iOS 17+ or macOS 14+")
                }
            #endif
            #if os(macOS)
            case .usbTerminal:
                USBTerminalView()
            #endif
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
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        #endif
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
        .onChange(of: viewModel.requestShowScanner) { shouldShow in
            if shouldShow {
                showScanner = true
                viewModel.requestShowScanner = false
            }
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
                viewModel.handleMeshCoreURL(urlString)
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
        // No alert on connecting → disconnected — the auto-reconnect and
        // auto-scan flow handles this silently via status bar updates.
        previousConnectionState = newState
    }
}

// MARK: - App Lock

class AppLockManager: ObservableObject {
    @Published var isUnlocked = false
    @AppStorage("appLockEnabled") var appLockEnabled = false

    func authenticate() {
        guard appLockEnabled else {
            isUnlocked = true
            return
        }
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: "Unlock MeshCore to access your messages") { success, _ in
                Task { @MainActor in
                    if success {
                        self.isUnlocked = true
                    } else {
                        self.authenticateWithPasscode()
                    }
                }
            }
        } else {
            authenticateWithPasscode()
        }
    }

    func authenticateWithPasscode() {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock MeshCore") { success, _ in
            Task { @MainActor in
                self.isUnlocked = success
            }
        }
    }
}

struct AppLockView: View {
    @ObservedObject var appLock: AppLockManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(MeshTheme.accent)
            Text("MeshCore is Locked")
                .font(.title2.bold())
                .foregroundStyle(MeshTheme.textPrimary)
            Text("Authenticate to access your messages")
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
            Spacer()
            Button {
                appLock.authenticate()
            } label: {
                Label("Unlock", systemImage: biometricIcon)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(MeshTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .background(MeshTheme.background)
        .onAppear { appLock.authenticate() }
    }

    private var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open"
        }
    }
}
