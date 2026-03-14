import SwiftUI
import MeshCoreKit

/// Management view for repeater and room server contacts.
struct RemoteManagementView: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel
    @ObservedObject var session: RemoteDeviceSession

    /// Accent color — teal for room servers, amber for repeaters.
    private var remoteAccent: Color {
        contact.type == .room
            ? Color(red: 0.0, green: 0.7, blue: 0.8)  // teal
            : Color(red: 1.0, green: 0.7, blue: 0.2)   // amber
    }

    var body: some View {
        List {
            if isLoggedIn {
                remoteBanner
                disconnectSection
                if session.isFetchingSettings {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(remoteAccent)
                            if session.fetchTotalCount > 0 {
                                Text("Fetching settings... (\(session.fetchReceivedCount)/\(session.fetchTotalCount))")
                                    .foregroundStyle(MeshTheme.textSecondary)
                            } else {
                                Text("Fetching settings...")
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                        }
                        .listRowBackground(MeshTheme.surface)
                    }
                }
                infoSection
                radioSection
                timingSection
                advertisingSection
                securitySection
                gpsSection
                if contact.type == .room {
                    roomSection
                }
                maintenanceSection
                cliTerminalSection
            } else {
                loginSection
            }
        }
        .meshListStyle()
        .navigationTitle("Remote Management")
        .task {
            // Lazy-load: fetch full settings only when management screen opens
            guard isLoggedIn, !session.hasLoadedFullSettings, !session.isFetchingSettings else { return }
            viewModel.fetchRemoteSettings(for: contact)
        }
        .toolbar {
            if isLoggedIn {
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewModel.fetchRemoteSettings(for: contact)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(remoteAccent)
                    }
                    .help("Refresh all settings")
                }
            }
        }
    }

    @ViewBuilder
    private var remoteBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: contact.type == .room ? "server.rack" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(remoteAccent)
                    Text(contact.name)
                        .font(.headline)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    Text(isAdmin ? "Admin" : "Guest")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MeshTheme.textOnAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(remoteAccent)
                        .clipShape(Capsule())
                }
                Text("Managing \(contact.name) via LoRa \u{2014} commands travel over the mesh and may take a few seconds.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            .padding(.vertical, 4)
            .listRowBackground(remoteAccent.opacity(0.1))
        }
    }

    @ViewBuilder
    private var disconnectSection: some View {
        Section {
            Button {
                viewModel.logoutFromRemoteDevice(contact)
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                        .frame(width: 24)
                    Text("Disconnect")
                        .foregroundStyle(.red)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var isAdmin: Bool {
        if case .loggedIn(let admin) = session.loginState { return admin }
        return false
    }

    private func sendCLI(_ command: String) {
        viewModel.sendCLICommand(command, to: contact)
    }

    private func getValue(_ key: String) -> String {
        session.settings[key] ?? "\u{2014}"
    }
}

// MARK: - Login Section

private extension RemoteManagementView {
    var loginSection: some View {
        LoginSection(contact: contact, session: session, viewModel: viewModel)
    }
}

struct LoginSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var password = ""

    var body: some View {
        Section {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(statusColor)
                    .shadow(color: statusColor.opacity(0.5), radius: 3)
                Text("Login Status")
                    .foregroundStyle(MeshTheme.textPrimary)
                Spacer()
                Text(statusLabel)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
            .listRowBackground(MeshTheme.surface)

            if !isLoggedIn {
                HStack {
                    Image(systemName: "lock")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    #if os(watchOS)
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    SecureField("Password", text: $password)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(.roundedBorder)
                    #endif
                }
                .listRowBackground(MeshTheme.surface)

                Text("Passwords are case-sensitive, max 15 characters.")
                    .font(.caption2)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .listRowBackground(MeshTheme.surface)

                Button {
                    viewModel.loginToRemoteDevice(contact, password: password)
                } label: {
                    HStack {
                        if case .loggingIn = session.loginState {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(MeshTheme.accentFallback)
                            Text("Logging in...")
                                .foregroundStyle(MeshTheme.textSecondary)
                        } else {
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(MeshTheme.accentFallback)
                                .frame(width: 24)
                            Text("Login")
                                .foregroundStyle(MeshTheme.accentFallback)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(password.isEmpty || isLoggingIn)
                .listRowBackground(MeshTheme.surface)

                if case .loginFailed(let msg) = session.loginState {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(MeshTheme.surface)
                }
            }
        } header: {
            Text("Connection")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = session.loginState { return true }
        return false
    }

    private var isLoggingIn: Bool {
        if case .loggingIn = session.loginState { return true }
        return false
    }

    private var statusColor: Color {
        switch session.loginState {
        case .loggedIn: MeshTheme.connected
        case .loggingIn: MeshTheme.connecting
        case .loginFailed: MeshTheme.disconnected
        case .notLoggedIn: MeshTheme.textSecondary
        }
    }

    private var statusLabel: String {
        switch session.loginState {
        case .loggedIn(let isAdmin): isAdmin ? "Admin" : "Guest"
        case .loggingIn: "Logging in..."
        case .loginFailed: "Failed"
        case .notLoggedIn: "Not logged in"
        }
    }
}

// MARK: - Info Section

private extension RemoteManagementView {
    var infoSection: some View {
        Section {
            cliInfoRow(icon: "info.circle", label: "Type", value: contact.type == .repeater ? "Repeater" : "Room Server")
            cliInfoRow(icon: "arrow.triangle.branch", label: "Path", value: contact.outPathLen == 0 ? "Direct" : "\(contact.outPathLen) hops")

            Button {
                sendCLI("ver")
            } label: {
                cliSettingRow(icon: "cpu", label: "Version", value: getValue("ver"))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            RemoteClockRow(session: session, sendCLI: sendCLI)

            Button {
                sendCLI("neighbors")
            } label: {
                HStack {
                    Image(systemName: "person.3")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Neighbors")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            if let neighborsText = session.settings["neighbors"], !neighborsText.isEmpty {
                Text(neighborsText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MeshTheme.textSecondary)
                    .listRowBackground(MeshTheme.surface)
            }

            Button {
                sendCLI("ver")
                sendCLI("clock")
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Refresh Info")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)
        } header: {
            Text("Device Info")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}

// MARK: - Radio Section

private extension RemoteManagementView {
    var radioSection: some View {
        RemoteRadioSection(contact: contact, session: session, sendCLI: sendCLI)
    }
}

struct RemoteRadioSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    @State private var radioParams = ""
    @State private var txPower = ""
    @State private var saveState: SaveButtonState = .idle

    var body: some View {
        Section {
            cliEditRow(icon: "antenna.radiowaves.left.and.right", label: "Radio (freq,bw,sf,cr)", text: $radioParams, current: session.settings["radio"])
            cliEditRow(icon: "bolt", label: "TX Power", text: $txPower, current: session.settings["tx"])
            CLIToggleRow(icon: "repeat", label: "Repeat Mode", settingKey: "repeat", onCommand: "set repeat on", offCommand: "set repeat off", session: session, sendCLI: sendCLI)

            SaveButton(state: saveState, label: "Apply Radio Settings") {
                if !radioParams.isEmpty { sendCLI("set radio \(radioParams)") }
                if !txPower.isEmpty { sendCLI("set tx \(txPower)") }
                showSaved($saveState)
            }
        } header: {
            Text("Radio Configuration")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Radio format: freq_kHz,bw_kHz,sf,cr (e.g. 906000,250,12,8)")
                .foregroundStyle(MeshTheme.textSecondary)
                .font(.caption2)
        }
    }
}

// MARK: - Timing Section

private extension RemoteManagementView {
    var timingSection: some View {
        RemoteTimingSection(contact: contact, session: session, sendCLI: sendCLI)
    }
}

struct RemoteTimingSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    @State private var airtimeFactor = ""
    @State private var rxDelay = ""
    @State private var txDelay = ""
    @State private var directTxDelay = ""
    @State private var floodMax = ""
    @State private var intThresh = ""
    @State private var agcReset = ""
    @State private var saveState: SaveButtonState = .idle

    var body: some View {
        Section {
            cliEditRow(icon: "clock.arrow.2.circlepath", label: "Airtime Factor", text: $airtimeFactor, current: session.settings["af"])
            cliEditRow(icon: "timer", label: "RX Delay", text: $rxDelay, current: session.settings["rxdelay"])
            cliEditRow(icon: "arrow.up.circle", label: "TX Delay", text: $txDelay, current: session.settings["txdelay"])
            cliEditRow(icon: "arrow.right.circle", label: "Direct TX Delay", text: $directTxDelay, current: session.settings["direct.txdelay"])
            cliEditRow(icon: "arrow.triangle.branch", label: "Flood Max Hops", text: $floodMax, current: session.settings["flood.max"])
            cliEditRow(icon: "waveform.badge.exclamationmark", label: "Interference Thresh", text: $intThresh, current: session.settings["int.thresh"])
            cliEditRow(icon: "dial.low", label: "AGC Reset Interval", text: $agcReset, current: session.settings["agc.reset.interval"])

            SaveButton(state: saveState, label: "Apply Timing") {
                if !airtimeFactor.isEmpty { sendCLI("set af \(airtimeFactor)") }
                if !rxDelay.isEmpty { sendCLI("set rxdelay \(rxDelay)") }
                if !txDelay.isEmpty { sendCLI("set txdelay \(txDelay)") }
                if !directTxDelay.isEmpty { sendCLI("set direct.txdelay \(directTxDelay)") }
                if !floodMax.isEmpty { sendCLI("set flood.max \(floodMax)") }
                if !intThresh.isEmpty { sendCLI("set int.thresh \(intThresh)") }
                if !agcReset.isEmpty { sendCLI("set agc.reset.interval \(agcReset)") }
                showSaved($saveState)
            }
        } header: {
            Text("Timing & Performance")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}

// MARK: - Advertising Section

private extension RemoteManagementView {
    var advertisingSection: some View {
        RemoteAdvertSection(contact: contact, session: session, sendCLI: sendCLI)
    }
}

struct RemoteAdvertSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    @State private var name = ""
    @State private var lat = ""
    @State private var lon = ""
    @State private var ownerInfo = ""
    @State private var advertInterval = ""
    @State private var floodAdvertInterval = ""
    @State private var saveState: SaveButtonState = .idle

    var body: some View {
        Section {
            cliEditRow(icon: "person.text.rectangle", label: "Name", text: $name, current: session.settings["name"])
            cliEditRow(icon: "location", label: "Latitude", text: $lat, current: session.settings["lat"])
            cliEditRow(icon: "location", label: "Longitude", text: $lon, current: session.settings["lon"])
            cliEditRow(icon: "person.crop.rectangle", label: "Owner Info", text: $ownerInfo, current: session.settings["owner.info"])
            cliEditRow(icon: "clock.arrow.circlepath", label: "Advert Interval (min)", text: $advertInterval, current: session.settings["advert.interval"])
            cliEditRow(icon: "dot.radiowaves.left.and.right", label: "Flood Advert (hrs)", text: $floodAdvertInterval, current: session.settings["flood.advert.interval"])
            CLIToggleRow(icon: "checkmark.message", label: "Multi-ACKs", settingKey: "multi.acks", onCommand: "set multi.acks 1", offCommand: "set multi.acks 0", session: session, sendCLI: sendCLI)

            HStack(spacing: 12) {
                SaveButton(state: saveState, label: "Save Advertising") {
                    if !name.isEmpty { sendCLI("set name \(name)") }
                    if !lat.isEmpty { sendCLI("set lat \(lat)") }
                    if !lon.isEmpty { sendCLI("set lon \(lon)") }
                    if !ownerInfo.isEmpty { sendCLI("set owner.info \(ownerInfo)") }
                    if !advertInterval.isEmpty { sendCLI("set advert.interval \(advertInterval)") }
                    if !floodAdvertInterval.isEmpty { sendCLI("set flood.advert.interval \(floodAdvertInterval)") }
                    showSaved($saveState)
                }

                Spacer()

                Button {
                    sendCLI("advert")
                } label: {
                    Label("Advertise", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        } header: {
            Text("Advertising")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}

// MARK: - Security Section

private extension RemoteManagementView {
    var securitySection: some View {
        RemoteSecuritySection(contact: contact, session: session, sendCLI: sendCLI, isAdmin: isAdmin)
    }
}

struct RemoteSecuritySection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let isAdmin: Bool

    @State private var adminPassword = ""
    @State private var guestPassword = ""

    var body: some View {
        Section {
            if isAdmin {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    #if os(watchOS)
                    SecureField("New Admin Password", text: $adminPassword)
                        .foregroundStyle(MeshTheme.textPrimary)
                    #else
                    SecureField("New Admin Password", text: $adminPassword)
                        .foregroundStyle(MeshTheme.textPrimary)
                        .textFieldStyle(.roundedBorder)
                    #endif
                    Button {
                        guard !adminPassword.isEmpty else { return }
                        sendCLI("password \(adminPassword)")
                        adminPassword = ""
                    } label: {
                        Text("Set")
                            .foregroundStyle(MeshTheme.accentFallback)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(MeshTheme.surface)
            }

            HStack {
                Image(systemName: "lock")
                    .foregroundStyle(MeshTheme.accentFallback)
                    .frame(width: 24)
                #if os(watchOS)
                SecureField("Guest Password", text: $guestPassword)
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                SecureField("Guest Password", text: $guestPassword)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                #endif
                Button {
                    guard !guestPassword.isEmpty else { return }
                    sendCLI("set guest.password \(guestPassword)")
                    guestPassword = ""
                } label: {
                    Text("Set")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(MeshTheme.surface)

            Button {
                sendCLI("get acl")
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("View ACL")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            if let aclText = session.settings["acl"], !aclText.isEmpty {
                Text(aclText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(MeshTheme.textSecondary)
                    .listRowBackground(MeshTheme.surface)
            }
        } header: {
            Text("Security")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("ACL permissions: 0=Guest, 1=Read-only, 2=Read-write, 3=Admin")
                .foregroundStyle(MeshTheme.textSecondary)
                .font(.caption2)
        }
    }
}

// MARK: - GPS Section

private extension RemoteManagementView {
    var gpsSection: some View {
        Section {
            CLIToggleRow(icon: "location.circle", label: "GPS", settingKey: "gps", onCommand: "gps on", offCommand: "gps off", session: session, sendCLI: sendCLI)

            HStack(spacing: 12) {
                Button {
                    sendCLI("gps sync")
                } label: {
                    Label("Sync Time", systemImage: "clock.arrow.2.circlepath")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    sendCLI("gps setloc")
                } label: {
                    Label("Set Location", systemImage: "mappin")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)

                Spacer()

                #if os(watchOS)
                Button { sendCLI("gps advert share") } label: {
                    Label("Advert", systemImage: "location.north.line")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)
                #else
                Menu {
                    Button("None") { sendCLI("gps advert none") }
                    Button("Share") { sendCLI("gps advert share") }
                    Button("Prefs") { sendCLI("gps advert prefs") }
                } label: {
                    Label("Advert Mode", systemImage: "location.north.line")
                        .foregroundStyle(MeshTheme.accentFallback)
                }
                #endif
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            Text("GPS")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}

// MARK: - Room Server Section

private extension RemoteManagementView {
    var roomSection: some View {
        RemoteRoomSection(session: session, sendCLI: sendCLI)
    }
}

struct RemoteRoomSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    var body: some View {
        Section {
            CLIToggleRow(icon: "eye", label: "Allow Read-Only", settingKey: "allow.read.only", onCommand: "set allow.read.only on", offCommand: "set allow.read.only off", session: session, sendCLI: sendCLI)
        } header: {
            Text("Room Server")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}

// MARK: - Maintenance Section

private extension RemoteManagementView {
    var maintenanceSection: some View {
        RemoteMaintenanceSection(session: session, sendCLI: sendCLI, isAdmin: isAdmin)
    }
}

struct RemoteMaintenanceSection: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void
    let isAdmin: Bool

    @State private var showRebootConfirm = false
    @State private var adcMultiplier = ""

    var body: some View {
        Section {
            CLIToggleRow(icon: "leaf", label: "Power Saving", settingKey: "powersaving", onCommand: "powersaving on", offCommand: "powersaving off", session: session, sendCLI: sendCLI)

            cliEditRow(icon: "bolt.batteryblock", label: "ADC Multiplier", text: $adcMultiplier, current: session.settings["adc.multiplier"])

            if !adcMultiplier.isEmpty {
                Button {
                    sendCLI("set adc.multiplier \(adcMultiplier)")
                    adcMultiplier = ""
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(MeshTheme.accentFallback)
                            .frame(width: 24)
                        Text("Apply ADC Multiplier")
                            .foregroundStyle(MeshTheme.accentFallback)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            }

            // Region management
            Button {
                sendCLI("region")
            } label: {
                HStack {
                    Image(systemName: "map")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("List Regions")
                        .foregroundStyle(MeshTheme.accentFallback)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            // Logging
            HStack(spacing: 12) {
                Button { sendCLI("log start") } label: {
                    Text("Start Log").foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)

                Button { sendCLI("log stop") } label: {
                    Text("Stop Log").foregroundStyle(MeshTheme.textSecondary)
                }
                .buttonStyle(.plain)

                Button { sendCLI("log") } label: {
                    Text("View Log").foregroundStyle(MeshTheme.accentFallback)
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(MeshTheme.surface)

            Button {
                sendCLI("clear stats")
            } label: {
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    Text("Clear Stats")
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(MeshTheme.surface)

            if isAdmin {
                Button {
                    showRebootConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text("Reboot Device")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
                .alert("Reboot Remote Device?", isPresented: $showRebootConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reboot", role: .destructive) {
                        sendCLI("reboot")
                    }
                } message: {
                    Text("The remote device will restart. You will need to log in again.")
                }
            }
        } header: {
            Text("Maintenance")
                .foregroundStyle(MeshTheme.textSecondary)
        }
    }
}

// MARK: - CLI Terminal Section

private extension RemoteManagementView {
    var cliTerminalSection: some View {
        CLITerminalSection(contact: contact, session: session, viewModel: viewModel)
    }
}

struct CLITerminalSection: View {
    let contact: Contact
    @ObservedObject var session: RemoteDeviceSession
    @ObservedObject var viewModel: MeshCoreViewModel
    @State private var commandText = ""

    var body: some View {
        Section {
            // History
            if !session.cliHistory.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(session.cliHistory) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("> \(entry.command)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(MeshTheme.accentFallback)
                                if let response = entry.response {
                                    Text(response)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(MeshTheme.textPrimary)
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(MeshTheme.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 200)
                .listRowBackground(MeshTheme.background)
            }

            // Input
            HStack(spacing: 8) {
                Text(">")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.accentFallback)
                #if os(watchOS)
                TextField("CLI command", text: $commandText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.textPrimary)
                #else
                TextField("CLI command", text: $commandText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeshTheme.textPrimary)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendCommand() }
                #endif
                Button(action: sendCommand) {
                    Image(systemName: "return")
                        .foregroundStyle(
                            commandText.isEmpty ? MeshTheme.textSecondary : MeshTheme.accentFallback
                        )
                }
                .buttonStyle(.plain)
                .disabled(commandText.isEmpty)
            }
            .listRowBackground(MeshTheme.surface)
        } header: {
            Text("CLI Terminal")
                .foregroundStyle(MeshTheme.textSecondary)
        } footer: {
            Text("Send raw CLI commands to the device. Type 'help' for available commands.")
                .foregroundStyle(MeshTheme.textSecondary)
                .font(.caption2)
        }
    }

    private func sendCommand() {
        viewModel.sendCLICommand(commandText, to: contact)
        commandText = ""
    }
}

// MARK: - Remote Clock Row

struct RemoteClockRow: View {
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    private var clockValue: String {
        session.settings["clock"] ?? "\u{2014}"
    }

    /// Check if the clock text indicates a stale date (more than 24h from now).
    private var isClockStale: Bool {
        guard let clockStr = session.settings["clock"], !clockStr.isEmpty else { return false }
        // Try to parse common date formats from the clock string
        // Clock responses look like "03:42 - 19/5/2024" or similar
        // Simple heuristic: if the string contains a year that's not the current year, flag it
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        // Check if string contains a 4-digit year that doesn't match current year
        let yearPattern = try? NSRegularExpression(pattern: "\\b(20\\d{2})\\b")
        if let match = yearPattern?.firstMatch(in: clockStr, range: NSRange(clockStr.startIndex..., in: clockStr)),
           let range = Range(match.range(at: 1), in: clockStr),
           let year = Int(clockStr[range]) {
            return abs(year - currentYear) >= 1
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                sendCLI("clock")
            } label: {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(MeshTheme.accentFallback)
                        .frame(width: 24)
                    Text("Clock")
                        .foregroundStyle(MeshTheme.textPrimary)
                    Spacer()
                    Text(clockValue)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .font(.caption)
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isClockStale {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Clock out of sync")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        let epoch = Int(Date().timeIntervalSince1970)
                        sendCLI("time \(epoch)")
                        // Refresh clock after a delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            sendCLI("clock")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.caption)
                            Text("Sync Clock")
                                .font(.caption)
                        }
                        .foregroundStyle(MeshTheme.accentFallback)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowBackground(MeshTheme.surface)
    }
}

// MARK: - Reusable Row Helpers

func cliInfoRow(icon: String, label: String, value: String) -> some View {
    HStack {
        Image(systemName: icon)
            .foregroundStyle(MeshTheme.accentFallback)
            .frame(width: 24)
        Text(label)
            .foregroundStyle(MeshTheme.textPrimary)
        Spacer()
        Text(value)
            .foregroundStyle(MeshTheme.textSecondary)
    }
    .listRowBackground(MeshTheme.surface)
}

func cliSettingRow(icon: String, label: String, value: String) -> some View {
    HStack {
        Image(systemName: icon)
            .foregroundStyle(MeshTheme.accentFallback)
            .frame(width: 24)
        Text(label)
            .foregroundStyle(MeshTheme.textPrimary)
        Spacer()
        Text(value)
            .foregroundStyle(MeshTheme.textSecondary)
            .font(.caption)
        Image(systemName: "arrow.clockwise")
            .font(.caption2)
            .foregroundStyle(MeshTheme.textSecondary)
    }
    .contentShape(Rectangle())
}

/// A segmented On/Off toggle for CLI boolean settings.
/// Derives its state from the session settings dictionary and sends CLI commands on tap.
struct CLIToggleRow: View {
    let icon: String
    let label: String
    let settingKey: String
    let onCommand: String
    let offCommand: String
    @ObservedObject var session: RemoteDeviceSession
    let sendCLI: (String) -> Void

    private var isOn: Bool? {
        guard let value = session.settings[settingKey]?.lowercased() else { return nil }
        if value == "on" || value == "1" || value == "true" || value == "enabled" || value.contains("on") { return true }
        if value == "off" || value == "0" || value == "false" || value == "disabled" || value.contains("off") { return false }
        return nil
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(MeshTheme.accentFallback)
                .frame(width: 24)
            Text(label)
                .foregroundStyle(MeshTheme.textPrimary)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    sendCLI(onCommand)
                } label: {
                    Text("On")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isOn == true ? MeshTheme.textOnAccent : MeshTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(isOn == true ? MeshTheme.connected : Color.clear)
                }
                .buttonStyle(.plain)

                Button {
                    sendCLI(offCommand)
                } label: {
                    Text("Off")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isOn == false ? MeshTheme.textOnAccent : MeshTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(isOn == false ? MeshTheme.disconnected : Color.clear)
                }
                .buttonStyle(.plain)
            }
            .background(MeshTheme.background)
            .clipShape(Capsule())
        }
        .listRowBackground(MeshTheme.surface)
    }
}

func cliEditRow(icon: String, label: String, text: Binding<String>, current: String?) -> some View {
    HStack {
        Image(systemName: icon)
            .foregroundStyle(MeshTheme.accentFallback)
            .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
            #if os(watchOS)
            TextField(current ?? "value", text: text)
                .foregroundStyle(MeshTheme.textPrimary)
            #else
            TextField(current ?? "value", text: text)
                .foregroundStyle(MeshTheme.textPrimary)
                .textFieldStyle(.roundedBorder)
            #endif
        }
    }
    .listRowBackground(MeshTheme.surface)
}
