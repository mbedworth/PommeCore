import SwiftUI
import UserNotifications
import LocalAuthentication
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
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
    /// Set by OnboardingView's "Open Settings Now" button to trigger Settings on first launch.
    @AppStorage("openSettingsAfterOnboarding") private var openSettingsAfterOnboarding = false

    var body: some Scene {
        WindowGroup {
            if !hasCompletedOnboarding {
                OnboardingView(
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    navigateToSettings: { openSettingsAfterOnboarding = true }
                )
                .meshTheme()
            } else if appLock.appLockEnabled && !appLock.isUnlocked {
                AppLockView(appLock: appLock)
                    .meshTheme()
            } else {
                ContentView()
                    .environmentObject(viewModel)
                    .environment(viewModel.deviceConfig)
                    .environment(viewModel.contactStore)
                    .environment(viewModel.channelStore)
                    .environment(viewModel.messageStoreManager)
                    .environment(viewModel.connectionManager)
                    .environment(viewModel.remoteSessionManager)
                    .environment(viewModel.navigationStore)
                    .meshTheme()
                    #if os(iOS)
                    .onAppear { appDelegate.viewModel = viewModel }
                    #endif
                    #if canImport(CoreSpotlight)
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                            let hex = id.replacingOccurrences(of: "meshcore.contact.", with: "")
                            viewModel.navigateToContact(pubkeyHex: hex)
                        }
                    }
                    #endif
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.connectionManager.isInBackground = (newPhase != .active)
            if newPhase == .active {
                viewModel.messageStoreManager.updateAppBadge()
                // Authentication is handled by AppLockView.onAppear — don't duplicate here
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
        let userInfo = response.notification.request.content.userInfo

        // Handle quick reply action
        if response.actionIdentifier == "REPLY_ACTION",
           let textResponse = response as? UNTextInputNotificationResponse,
           let pubkeyHex = userInfo["contactPubkey"] as? String {
            Task { @MainActor in
                viewModel?.handleNotificationReply(text: textResponse.userText, contactPubkeyHex: pubkeyHex)
            }
        }

        // Navigate to the correct chat on tap
        Task { @MainActor in
            if let isChannel = userInfo["isChannel"] as? Bool, isChannel,
               let chIdx = userInfo["channelIndex"] as? UInt8 {
                viewModel?.navigationStore.sidebarSelection = chIdx == 0 ? .publicChannel : .channel(chIdx)
            } else if let pubkeyHex = userInfo["contactPubkey"] as? String {
                if let contact = viewModel?.contactStore.contacts.first(where: {
                    $0.publicKey.map { String(format: "%02x", $0) }.joined() == pubkeyHex
                }) {
                    viewModel?.navigationStore.sidebarSelection = .contact(contact.publicKeyPrefix)
                }
            }
        }
        completionHandler()
    }
}
#endif

struct ContentView: View {
    @Environment(ContactStore.self) private var contactStore
    @Environment(ChannelStore.self) private var channelStore
    @Environment(MessageStoreManager.self) private var messageStoreManager
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(RemoteSessionManager.self) private var remoteSessionManager
    @Environment(NavigationStore.self) private var navigationStore
    @State private var showScanner = false
    @State private var showSettings = false
    @State private var showDiscover = false
    @State private var showConnectionFailed = false
    @State private var showAdvertSent = false
    @State private var showRemoteManagement = false
    @State private var previousConnectionState: BLEConnectionState = .disconnected
    @State private var hasRequestedAutoScan = false
    /// Bridged from OnboardingView's "Open Settings Now" button.
    @AppStorage("openSettingsAfterOnboarding") private var openSettingsAfterOnboarding = false

    var body: some View {
        #if os(watchOS)
        NavigationStack {
            ContactListView(showScanner: $showScanner)
                .sheet(isPresented: $showScanner) {
                    NavigationStack {
                        DeviceScannerView()
                    }
                }
                .onAppear { requestAutoScanOnce() }
                .onChange(of: connectionManager.connectionState) { _, newState in
                    handleConnectionStateChange(newState)
                }
                .alert("Connection Failed", isPresented: $showConnectionFailed) {
                    Button("Retry") { showScanner = true }
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Could not connect to the device. Would you like to scan again?")
                }
                .alert("Device Error", isPresented: showErrorBinding) {
                    Button("OK", role: .cancel) { connectionManager.lastErrorMessage = nil }
                } message: {
                    Text(connectionManager.lastErrorMessage ?? "Unknown error")
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
            // Column width MUST be on the view inside the sidebar builder, not on
            // NavigationSplitView itself — the outer position is silently ignored.
            // ideal = first-launch default; macOS window restoration remembers any
            // user resize automatically via WindowGroup state persistence.
            #if os(macOS) || targetEnvironment(macCatalyst)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 400)
            #endif
        } detail: {
            switch navigationStore.sidebarSelection {
            case .publicChannel:
                ChannelChatView(channelIndex: 0, channelName: "Public Channel")
            case .channel(let chIdx):
                if let channel = channelStore.channels.first(where: { $0.index == chIdx }) {
                    ChannelChatView(channelIndex: channel.index, channelName: channel.name)
                } else {
                    ChannelChatView(channelIndex: chIdx, channelName: "Channel \(chIdx)")
                }
            case .contact(let key):
                if let contact = contactStore.contacts.first(where: { $0.publicKeyPrefix == key }) {
                    switch contact.type {
                    case .room:
                        RoomChatView(
                            contact: contact,
                            session: remoteSessionManager.remoteSession(for: contact)
                        )
                    case .repeater:
                        RepeaterLoginView(
                            contact: contact,
                            session: remoteSessionManager.remoteSession(for: contact)
                        )
                    default:
                        ChatView(contact: contact)
                    }
                } else {
                    Text("Contact not found")
                }
            case .settings:
                SettingsView()
            #if !os(watchOS)
            case .map:
                if #available(iOS 17.0, macOS 14.0, *) {
                    MeshMapView()
                } else {
                    Text("Map requires iOS 17+ or macOS 14+")
                }
            #endif
            #if os(macOS) || targetEnvironment(macCatalyst)
            case .usbTerminal:
                USBTerminalView()
            case .usbDevice:
                if let contact = remoteSessionManager.usbDeviceContact, let session = remoteSessionManager.usbDeviceSession {
                    RemoteManagementView(contact: contact, session: session)
                } else {
                    Text("USB device not connected")
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            #endif
            case nil:
                if connectionManager.connectionState == .disconnected {
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
        #if os(macOS) || targetEnvironment(macCatalyst)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    connectionManager.sendAdvertise(type: 1)
                    showAdvertSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showAdvertSent = false
                    }
                } label: {
                    Image(systemName: showAdvertSent
                        ? "checkmark.circle.fill"
                        : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accent)
                }
                .disabled(connectionManager.connectionState != .ready)
                .help("Advertise")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDiscover = true
                } label: {
                    Image(systemName: "binoculars.fill")
                        .foregroundStyle(MeshTheme.accent)
                }
                .disabled(connectionManager.connectionState != .ready)
                .help("Discover")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    connectionManager.refreshAll(contactStore: contactStore)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accent)
                }
                .disabled(connectionManager.connectionState != .ready)
                .help("Refresh")
            }
        }
        #endif
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                DeviceScannerView()
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
        .onAppear {
            requestAutoScanOnce()
            if openSettingsAfterOnboarding {
                openSettingsAfterOnboarding = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showSettings = true
                }
            }
        }
        .onChange(of: connectionManager.connectionState) { _, newState in
            handleConnectionStateChange(newState)
        }
        .onChange(of: connectionManager.requestShowScanner) { _, shouldShow in
            if shouldShow {
                showScanner = true
                connectionManager.requestShowScanner = false
            }
        }
        .alert("Connection Failed", isPresented: $showConnectionFailed) {
            Button("Retry") { showScanner = true }
            Button("OK", role: .cancel) { }
        } message: {
            Text("Could not connect to the device. Would you like to scan again?")
        }
        .alert("Device Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) { connectionManager.lastErrorMessage = nil }
        } message: {
            Text(connectionManager.lastErrorMessage ?? "Unknown error")
        }
        .alert("Advertisement Sent", isPresented: $showAdvertSent) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your device advertisement has been broadcast to the mesh network.")
        }
        .onOpenURL { url in
            let urlString = url.absoluteString
            if !channelStore.handleChannelURL(urlString),
               urlString.hasPrefix("meshcore://") {
                connectionManager.importContact(url: urlString)
                contactStore.requestContacts(fullSync: true)
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
        if connectionManager.connectionState == .ready || connectionManager.connectionState == .connected {
            return
        }
        // If reconnecting via state restoration, don't interrupt
        if connectionManager.connectionState == .connecting {
            return
        }

        showScanner = true
        connectionManager.requestAutoScan()
    }

    /// Find the first logged-in remote management target for the toolbar wrench button.
    private var activeManagementTarget: (Contact, RemoteDeviceSession)? {
        for contact in contactStore.contacts where contact.type == .repeater || contact.type == .room {
            let session = remoteSessionManager.remoteSession(for: contact)
            if case .loggedIn = session.loginState {
                return (contact, session)
            }
        }
        return nil
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { connectionManager.lastErrorMessage != nil },
            set: { if !$0 { connectionManager.lastErrorMessage = nil } }
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
    @Published var authFailCount = 0
    @Published var showResetOption = false
    @AppStorage("appLockEnabled") var appLockEnabled = false

    func authenticate() {
        guard appLockEnabled else {
            isUnlocked = true
            return
        }

        DebugLogger.shared.log("APP LOCK: starting authentication", level: .info)

        // Use .deviceOwnerAuthentication which falls back to device passcode
        // if biometrics fail — never leaves the user locked out.
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        // Small delay to ensure the window is fully presented before showing prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                // No authentication available (no passcode set on device) — unlock directly
                DebugLogger.shared.log("APP LOCK: no auth available, unlocking: \(error?.localizedDescription ?? "none")", level: .warning)
                self.isUnlocked = true
                return
            }

            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "Unlock MeshCore to access your messages") { success, authError in
                Task { @MainActor in
                    if success {
                        DebugLogger.shared.log("APP LOCK: authenticated successfully", level: .info)
                        self.isUnlocked = true
                        self.authFailCount = 0
                        self.showResetOption = false
                    } else {
                        self.authFailCount += 1
                        DebugLogger.shared.log("APP LOCK: auth failed (\(self.authFailCount)/3): \(authError?.localizedDescription ?? "cancelled")", level: .warning)
                        if self.authFailCount >= 3 {
                            self.showResetOption = true
                        }
                    }
                }
            }
        }
    }

    /// Emergency reset — disables app lock when user is locked out.
    func resetLock() {
        DebugLogger.shared.log("APP LOCK: emergency reset — disabling app lock", level: .warning)
        appLockEnabled = false
        isUnlocked = true
        authFailCount = 0
        showResetOption = false
    }
}

struct AppLockView: View {
    @ObservedObject var appLock: AppLockManager
    @State private var hasTriedAutoAuth = false

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

            if appLock.showResetOption {
                Text("Authentication failed \(appLock.authFailCount) times")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

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

            if appLock.showResetOption {
                Button {
                    appLock.resetLock()
                } label: {
                    Text("Disable App Lock")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(.bottom, 40)
        .background(MeshTheme.background)
        .onAppear {
            // Only auto-authenticate once per view appearance
            guard !hasTriedAutoAuth else { return }
            hasTriedAutoAuth = true
            appLock.authenticate()
        }
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
