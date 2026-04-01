//
//  NodeSetupWizardView.swift
//  MeshCoreApple
//
//  Node Setup Wizard — guides new users through naming their node and selecting
//  a radio preset. 6 steps: Role → Location → Identity → Key Prefix → Review → Preset.
//
//  Created by Michael P. Bedworth on 4/1/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit
#if !os(watchOS)
import CoreLocation
import MapKit
#endif

/// Context for running the wizard against a remote device via CLI.
struct RemoteWizardContext {
    let contact: Contact
    let publicKeyHex: String
    let sendCLI: (String) -> Void
    /// Current radio frequency in kHz, if known from session settings.
    var currentFrequencyKHz: Double?
}

struct NodeSetupWizardView: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss

    /// When set, the wizard targets a remote device via CLI instead of the local connection.
    var remoteContext: RemoteWizardContext?

    private var isRemote: Bool { remoteContext != nil }

    // MARK: - Wizard State

    @State private var currentStep = 0
    @State private var selectedRole: NodeRole?
    @State private var locationCodes: LocationCodes?
    @State private var isoCountryCode: String?
    @State private var emoji: String?
    @State private var initials: String = ""
    @State private var keyPrefix: String = ""
    @State private var isGeolocating = false
    @State private var geocodeError: String?
    @State private var nameApplied = false
    #if !os(watchOS)
    @State private var showMapPicker = false
    #endif

    /// Whether the current radio frequency is legal for the detected country.
    /// If legal (or unknown), skip the preset step.
    private var needsPresetStep: Bool {
        guard let country = isoCountryCode, !country.isEmpty else { return false }
        let freqKHz: Double
        if let remote = remoteContext {
            guard let freq = remote.currentFrequencyKHz else { return true }
            freqKHz = freq
        } else {
            freqKHz = Double(deviceConfig.radioFrequency)
        }
        return !isFrequencyLegal(frequencyKHz: freqKHz, forCountry: country)
    }

    /// Total steps adjusts based on role and whether preset step is needed.
    private var totalSteps: Int {
        var steps = selectedRole?.isInfrastructure == true ? 4 : 5  // without preset
        if needsPresetStep { steps += 1 }
        return steps
    }

    /// Map logical step index to step type, skipping identity for infrastructure
    /// and skipping preset when radio is already legal.
    private func stepType(for index: Int) -> StepType {
        if selectedRole?.isInfrastructure == true {
            // Infrastructure: Role → Location → KeyPrefix → Review [→ Preset]
            switch index {
            case 0: return .role
            case 1: return .location
            case 2: return .keyPrefix
            case 3: return .review
            case 4 where needsPresetStep: return .preset
            default: return .role
            }
        } else {
            // Mobile: Role → Location → Identity → KeyPrefix → Review [→ Preset]
            switch index {
            case 0: return .role
            case 1: return .location
            case 2: return .identity
            case 3: return .keyPrefix
            case 4: return .review
            case 5 where needsPresetStep: return .preset
            default: return .role
            }
        }
    }

    private enum StepType {
        case role, location, identity, keyPrefix, review, preset
    }

    private var nameBuilder: NodeNameBuilder {
        NodeNameBuilder(
            role: selectedRole ?? .companionBLE,
            locationCodes: locationCodes,
            emoji: emoji,
            initials: initials,
            keyPrefix: keyPrefix
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            TabView(selection: $currentStep) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    stepContent(for: step)
                        .tag(step)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .animation(.easeInOut, value: currentStep)

            // Navigation controls
            navigationControls
        }
        .background(MeshTheme.background)
        .onAppear {
            if let remote = remoteContext {
                // Remote mode: use contact info
                if remote.publicKeyHex.count >= 5 {
                    keyPrefix = String(remote.publicKeyHex.prefix(5))
                }
                selectedRole = NodeRole.detect(selfType: remote.contact.type.rawValue, transport: .ble)
            } else {
                // Local mode: use device config
                if deviceConfig.publicKeyHex.count >= 5 {
                    keyPrefix = String(deviceConfig.publicKeyHex.prefix(5))
                }
                let transport = connectionManager.activeTransport
                selectedRole = NodeRole.detect(selfType: deviceConfig.selfType, transport: transport)
            }
        }
        #if !os(watchOS)
        #if os(iOS)
        .fullScreenCover(isPresented: $showMapPicker) { mapPickerContent }
        #else
        .sheet(isPresented: $showMapPicker) {
            mapPickerContent
                .frame(width: 600, height: 700)
        }
        #endif
        #endif
    }

    // MARK: - Step Content

    @ViewBuilder
    private func stepContent(for step: Int) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                switch stepType(for: step) {
                case .role:
                    roleStep
                case .location:
                    locationStep
                case .identity:
                    identityStep
                case .keyPrefix:
                    keyPrefixStep
                case .review:
                    reviewStep
                case .preset:
                    radioReminderStep
                }
            }
            .padding()
        }
    }

    // MARK: - Step 1: Role

    private var roleStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "cpu",
                title: "Device Role",
                subtitle: selectedRole != nil
                    ? "Auto-detected as \(selectedRole!.displayName). Tap to change."
                    : "What type of node is this?"
            )

            let choices: [NodeRole] = selectedRole != nil
                ? NodeRole.allCases
                : NodeRole.ambiguousChoices(selfType: deviceConfig.selfType)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(choices) { role in
                    Button {
                        withAnimation { selectedRole = role }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: role.icon)
                                .font(.title2)
                            Text(role.displayName)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(role.code)
                                .font(.caption2)
                                .foregroundStyle(MeshTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedRole == role ? MeshTheme.accent.opacity(0.2) : MeshTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedRole == role ? MeshTheme.accent : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedRole == role ? MeshTheme.accent : MeshTheme.textPrimary)
                }
            }
        }
    }

    // MARK: - Step 2: Location

    private var locationStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "location",
                title: "Location",
                subtitle: selectedRole?.isInfrastructure == true
                    ? "Used in your node name and to find radio presets for your region."
                    : "Used to find the right radio presets for your region."
            )

            #if !os(watchOS)
            Button {
                requestLocation()
            } label: {
                HStack {
                    if isGeolocating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "location.fill")
                    }
                    Text(isGeolocating ? "Locating..." : "Use My Location")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(MeshTheme.accent)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isGeolocating)

            Button {
                showMapPicker = true
            } label: {
                HStack {
                    Image(systemName: "map")
                    Text("Pick on Map")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(MeshTheme.surface)
                .foregroundStyle(MeshTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(MeshTheme.accent.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            #endif

            if let error = geocodeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if locationCodes == nil {
                Button {
                    locationCodes = LocationCodes(country: "", region: "", city: "")
                } label: {
                    HStack {
                        Image(systemName: "keyboard")
                        Text("Enter Manually")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(MeshTheme.surface)
                    .foregroundStyle(MeshTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(MeshTheme.accent.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if let loc = locationCodes {
                VStack(spacing: 12) {
                    locationField(label: "Country", value: Binding(
                        get: { loc.country },
                        set: { locationCodes?.country = $0 }
                    ), maxLength: 2)
                    locationField(label: "Region", value: Binding(
                        get: { loc.region },
                        set: { locationCodes?.region = $0 }
                    ), maxLength: 3)
                    locationField(label: "City", value: Binding(
                        get: { loc.city },
                        set: { locationCodes?.city = $0 }
                    ), maxLength: 3)
                }

                // Update country code for preset filtering
                let _ = {
                    if isoCountryCode != loc.country {
                        DispatchQueue.main.async { isoCountryCode = loc.country }
                    }
                }()

                Text("Country: 2-letter ISO code (e.g. US, GB, AU). Region: state/province (e.g. CA, NSW). City: 3-letter code (e.g. SFO, LON).")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            } else {
                Text("Location is used in infrastructure node names and to filter radio presets for your region.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }
        }
    }

    private func locationField(label: String, value: Binding<String>, maxLength: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
                .frame(width: 70, alignment: .leading)
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .textCase(.uppercase)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                #endif
                .onChange(of: value.wrappedValue) { _, newValue in
                    if newValue.count > maxLength {
                        value.wrappedValue = String(newValue.prefix(maxLength))
                    }
                }
            Text("\(value.wrappedValue.count)/\(maxLength)")
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
                .frame(width: 30)
        }
    }

    // MARK: - Step 3: Identity (Mobile Only)

    private var identityStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "person.circle",
                title: "Identity",
                subtitle: "Choose an emoji and enter your initials."
            )

            // Emoji picker
            Text("Emoji (optional)")
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                // "None" option
                Button {
                    withAnimation { emoji = nil }
                } label: {
                    Text("--")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(emoji == nil ? MeshTheme.accent.opacity(0.2) : MeshTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(emoji == nil ? MeshTheme.accent : Color.clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)

                ForEach(nodeEmojis, id: \.emoji) { item in
                    Button {
                        withAnimation { emoji = item.emoji }
                    } label: {
                        Text(item.emoji)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(emoji == item.emoji ? MeshTheme.accent.opacity(0.2) : MeshTheme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(emoji == item.emoji ? MeshTheme.accent : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                }
            }

            // Initials
            Text("Initials (2-3 letters)")
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("e.g. MB", text: $initials)
                .textFieldStyle(.roundedBorder)
                .textCase(.uppercase)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                #endif
                .onChange(of: initials) { _, newValue in
                    let filtered = newValue.filter { $0.isLetter }
                    if filtered.count > 3 {
                        initials = String(filtered.prefix(3))
                    } else if filtered != newValue {
                        initials = filtered
                    }
                }
        }
    }

    // MARK: - Step 4: Key Prefix

    private var keyPrefixStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "key",
                title: "Key Prefix",
                subtitle: "The first 5 characters of your device's public key ensure name uniqueness."
            )

            Text(keyPrefix)
                .font(.system(.largeTitle, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(MeshTheme.accent)
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(MeshTheme.surface)
                )

            Text("This is auto-filled from your device and gives over 1 million combinations to prevent name collisions.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Step 5: Review Name

    private var reviewStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "checkmark.seal",
                title: "Your Node Name",
                subtitle: "Review your generated name below."
            )

            let name = nameBuilder.assembledName
            let bytes = nameBuilder.byteCount

            // Name display
            Text(name)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(MeshTheme.accent)
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(MeshTheme.surface)
                )

            // Byte count
            HStack {
                Text("\(bytes) / \(maxAdvertNameBytes) bytes")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                if bytes <= maxAdvertNameBytes {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(bytes <= maxAdvertNameBytes ? MeshTheme.textSecondary : .red)

            // Component breakdown
            componentBreakdown

            // Apply button
            Button {
                applyName()
                if isRemote {
                    // Remote: name + reboot sent, dismiss wizard
                    dismiss()
                } else if currentStep < totalSteps - 1 {
                    // Local: auto-advance to preset step
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation { currentStep += 1 }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: nameApplied ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    Text(nameApplied ? "Name Applied" : isRemote ? "Apply Name & Reboot" : "Apply Name")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(nameApplied ? Color.green.opacity(0.2) : MeshTheme.accent)
                .foregroundStyle(nameApplied ? .green : .black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!nameBuilder.isValid || nameApplied)
        }
    }

    @ViewBuilder
    private var componentBreakdown: some View {
        let role = selectedRole ?? .companionBLE
        VStack(alignment: .leading, spacing: 8) {
            if role.isInfrastructure, let loc = locationCodes {
                componentBadge("Country", loc.country.uppercased())
                componentBadge("Region", loc.region.uppercased())
                componentBadge("City", loc.city.uppercased())
            } else {
                if let e = emoji {
                    componentBadge("Emoji", e)
                }
                if !initials.isEmpty {
                    componentBadge("Initials", initials.uppercased())
                }
            }
            componentBadge("Role", role.code)
            componentBadge("Key", keyPrefix)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func componentBadge(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MeshTheme.accent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Step: Radio Reminder

    private var radioReminderStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "exclamationmark.triangle",
                title: "Check Radio Settings",
                subtitle: "Your radio frequency may not be legal for this location."
            )

            if let country = isoCountryCode {
                let presets = presetsForCountry(country)
                if !presets.isEmpty {
                    Text("Recommended presets for your region:")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(Array(presets.prefix(3).enumerated()), id: \.offset) { _, preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("\(String(format: "%.3f", preset.frequencyKHz / 1000)) MHz \u{2022} SF\(preset.spreadingFactor) \u{2022} BW \(preset.bandwidth == preset.bandwidth.rounded() ? "\(Int(preset.bandwidth))" : "\(preset.bandwidth)") kHz")
                                    .font(.caption)
                                    .foregroundStyle(MeshTheme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(MeshTheme.surface)
                        )
                    }
                }
            }

            Text("After the device reboots, go to Settings \u{2192} Radio to apply the correct preset for your region.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Got It")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(MeshTheme.accent)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Navigation Controls

    private var canAdvance: Bool {
        switch stepType(for: currentStep) {
        case .role:
            return selectedRole != nil
        case .location:
            if selectedRole?.isInfrastructure == true {
                guard let loc = locationCodes else { return false }
                return !loc.country.isEmpty && !loc.region.isEmpty && !loc.city.isEmpty
            }
            // Mobile nodes: location is optional (just for preset filtering) but encouraged
            return true
        case .identity:
            return initials.count >= 2
        case .keyPrefix:
            return keyPrefix.count == 5
        case .review:
            return nameApplied
        case .preset:
            return true // handled by its own buttons
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 20) {
            // Back arrow
            Button {
                withAnimation { currentStep = max(0, currentStep - 1) }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundStyle(currentStep > 0 ? MeshTheme.accent : MeshTheme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(currentStep == 0)

            // Step dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step == currentStep ? MeshTheme.accent : MeshTheme.textSecondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            // Forward arrow
            Button {
                if currentStep < totalSteps - 1 {
                    withAnimation { currentStep += 1 }
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canAdvance ? MeshTheme.accent : MeshTheme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canAdvance || currentStep >= totalSteps - 1)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Helpers

    #if !os(watchOS)
    private var mapPickerContent: some View {
        NavigationStack {
            LocationPickerMapView { codes, country in
                locationCodes = codes
                isoCountryCode = country
                showMapPicker = false
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMapPicker = false }
                }
            }
        }
        .meshTheme()
    }
    #endif

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(MeshTheme.accent)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    #if !os(watchOS)
    private func requestLocation() {
        isGeolocating = true
        geocodeError = nil

        let manager = SharedLocation.manager
        manager.requestWhenInUseAuthorization()

        // Small delay for authorization prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let location = manager.location else {
                isGeolocating = false
                geocodeError = "Could not get GPS location. Ensure Location Services are enabled."
                return
            }

            Task {
                do {
                    let codes = try await NodeNameBuilder.reverseGeocode(location: location)
                    await MainActor.run {
                        locationCodes = codes
                        isoCountryCode = codes.country
                        isGeolocating = false
                    }
                } catch {
                    await MainActor.run {
                        geocodeError = error.localizedDescription
                        isGeolocating = false
                    }
                }
            }
        }
    }
    #endif

    private func applyName() {
        let name = nameBuilder.assembledName

        if let remote = remoteContext {
            // Send location first (doesn't require reboot), then name + reboot.
            // Name and radio params must be the LAST command before reboot — nothing after.
            #if !os(watchOS)
            if let location = SharedLocation.manager.location, locationCodes != nil {
                let lat = String(format: "%.6f", location.coordinate.latitude)
                let lon = String(format: "%.6f", location.coordinate.longitude)
                remote.sendCLI("set lat \(lat)")
                remote.sendCLI("set lon \(lon)")
            }
            #endif
            remote.sendCLI("set name \(name)")
            remote.sendCLI("reboot")
        } else {
            #if !os(watchOS)
            if let location = SharedLocation.manager.location, locationCodes != nil {
                connectionManager.setAdvertLatLon(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            }
            #endif
            connectionManager.setAdvertName(name)
        }

        withAnimation { nameApplied = true }
    }

}

// MARK: - Location Picker Map

#if !os(watchOS)
@available(iOS 17.0, macOS 14.0, *)
struct LocationPickerMapView: View {
    let onConfirm: (LocationCodes, String) -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var centerCoordinate: CLLocationCoordinate2D?
    @State private var pinnedCoordinate: CLLocationCoordinate2D?
    @State private var geocodedCodes: LocationCodes?
    @State private var isGeocoding = false
    @State private var geocodeError: String?
    @State private var mapReady = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Defer Map creation until after the first layout pass.
                // MapKit's Metal renderer crashes with CAMetalLayer width=0 height=0
                // when the sheet initializes before layout completes on macOS/Catalyst.
                if mapReady {
                    mapContent
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task {
                // Wait for the sheet to finish its layout animation before creating the Map
                try? await Task.sleep(nanoseconds: 300_000_000)
                mapReady = true
            }

            // Bottom panel
            VStack(spacing: 12) {
                if isGeocoding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Looking up location...")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .padding(.top, 12)
                } else if let codes = geocodedCodes {
                    HStack(spacing: 16) {
                        codeBadge("Country", codes.country)
                        codeBadge("Region", codes.region)
                        codeBadge("City", codes.city)
                    }
                    .padding(.top, 12)

                    Button {
                        onConfirm(codes, codes.country)
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Use This Location")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(MeshTheme.accent)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                } else if let error = geocodeError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                } else {
                    Text("Pan the map so the crosshair is over your location")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .padding(.top, 12)
                }

                if pinnedCoordinate == nil || geocodedCodes != nil {
                    Button {
                        if let coord = centerCoordinate {
                            pinnedCoordinate = coord
                            geocodePin(coord)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "mappin.and.ellipse")
                            Text(pinnedCoordinate == nil ? "Drop Pin Here" : "Move Pin Here")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(MeshTheme.surface)
                        .foregroundStyle(MeshTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(MeshTheme.accent.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(centerCoordinate == nil)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
            .background(MeshTheme.background)
        }
        .navigationTitle("Pick Location")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var mapContent: some View {
        ZStack {
            Map(position: $cameraPosition) {
                if let pin = pinnedCoordinate {
                    Annotation("", coordinate: pin) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundStyle(MeshTheme.accent)
                    }
                }
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                centerCoordinate = context.camera.centerCoordinate
            }

            // Crosshair at center
            if pinnedCoordinate == nil {
                Image(systemName: "plus")
                    .font(.title2)
                    .fontWeight(.light)
                    .foregroundStyle(MeshTheme.accent.opacity(0.8))
                    .allowsHitTesting(false)
            }
        }
    }

    private func codeBadge(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(MeshTheme.textSecondary)
            Text(value.uppercased())
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(MeshTheme.accent)
        }
    }

    private func geocodePin(_ coordinate: CLLocationCoordinate2D) {
        isGeocoding = true
        geocodeError = nil
        geocodedCodes = nil

        Task {
            do {
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let codes = try await NodeNameBuilder.reverseGeocode(location: location)
                await MainActor.run {
                    geocodedCodes = codes
                    isGeocoding = false
                }
            } catch {
                await MainActor.run {
                    geocodeError = "Could not identify this location. Try a different spot."
                    isGeocoding = false
                }
            }
        }
    }
}
#endif
