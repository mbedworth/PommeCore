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
#endif

struct NodeSetupWizardView: View {
    @Environment(DeviceConfig.self) private var deviceConfig
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(\.dismiss) private var dismiss

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
    @State private var showRebootWarning = false

    /// Total steps adjusts based on whether identity step is needed (mobile only).
    private var totalSteps: Int {
        selectedRole?.isInfrastructure == true ? 5 : 6
    }

    /// Map logical step index to step type, skipping identity for infrastructure.
    private func stepType(for index: Int) -> StepType {
        if selectedRole?.isInfrastructure == true {
            // Infrastructure: Role → Location → KeyPrefix → Review → Preset
            switch index {
            case 0: return .role
            case 1: return .location
            case 2: return .keyPrefix
            case 3: return .review
            case 4: return .preset
            default: return .role
            }
        } else {
            // Mobile: Role → Location → Identity → KeyPrefix → Review → Preset
            switch index {
            case 0: return .role
            case 1: return .location
            case 2: return .identity
            case 3: return .keyPrefix
            case 4: return .review
            case 5: return .preset
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
            // Auto-fill key prefix from device public key
            if deviceConfig.publicKeyHex.count >= 5 {
                keyPrefix = String(deviceConfig.publicKeyHex.prefix(5))
            }
            // Auto-detect role
            let transport = connectionManager.activeTransport
            selectedRole = NodeRole.detect(selfType: deviceConfig.selfType, transport: transport)
        }
        .alert("Apply Radio Preset & Reboot?", isPresented: $showRebootWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Apply & Reboot") {
                applyPresetAndReboot()
            }
        } message: {
            Text("This will apply the radio preset and reboot your device. The connection will drop briefly and reconnect automatically.")
        }
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
                    presetStep
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
            #endif

            if let error = geocodeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
            }

            Text("You can edit the codes manually after auto-detection.")
                .font(.caption)
                .foregroundStyle(MeshTheme.textSecondary)
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
            } label: {
                HStack {
                    Image(systemName: nameApplied ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    Text(nameApplied ? "Name Applied" : "Apply Name")
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

    // MARK: - Step 6: Radio Preset

    @State private var selectedPreset: RadioPreset?

    private var presetStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                icon: "antenna.radiowaves.left.and.right",
                title: "Radio Preset",
                subtitle: isoCountryCode != nil
                    ? "Showing presets for your region. This will reboot your device."
                    : "Select a radio preset for your region. This will reboot your device."
            )

            let presets = isoCountryCode.map { presetsForCountry($0) } ?? radioPresets

            if presets.isEmpty {
                Text("No region-specific presets found. Showing all presets.")
                    .font(.caption)
                    .foregroundStyle(MeshTheme.textSecondary)
            }

            let displayPresets = presets.isEmpty ? radioPresets : presets

            ForEach(Array(displayPresets.enumerated()), id: \.offset) { _, preset in
                Button {
                    withAnimation { selectedPreset = preset }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("\(String(format: "%.3f", preset.frequencyKHz / 1000)) MHz · SF\(preset.spreadingFactor) · BW \(preset.bandwidth == preset.bandwidth.rounded() ? "\(Int(preset.bandwidth))" : "\(preset.bandwidth)") kHz")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedPreset?.name == preset.name ? MeshTheme.accent.opacity(0.2) : MeshTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selectedPreset?.name == preset.name ? MeshTheme.accent : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(MeshTheme.textPrimary)
            }

            // Apply & Reboot
            Button {
                showRebootWarning = true
            } label: {
                HStack {
                    Image(systemName: "bolt.circle.fill")
                    Text("Apply Preset & Reboot")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedPreset != nil ? MeshTheme.accent : MeshTheme.surface)
                .foregroundStyle(selectedPreset != nil ? .black : MeshTheme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(selectedPreset == nil)

            // Skip option
            Button {
                dismiss()
            } label: {
                Text("Skip — I'll configure this later")
                    .font(.subheadline)
                    .foregroundStyle(MeshTheme.textSecondary)
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
                return locationCodes != nil
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
        connectionManager.setAdvertName(name)

        // Also set location if we have GPS coordinates
        #if !os(watchOS)
        if let location = SharedLocation.manager.location, locationCodes != nil {
            connectionManager.setAdvertLatLon(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
        #endif

        withAnimation { nameApplied = true }
    }

    private func applyPresetAndReboot() {
        guard let preset = selectedPreset else { return }
        let freq = UInt32(preset.frequencyKHz)
        let bw = UInt32(preset.bandwidth * 1000)
        connectionManager.setRadioParams(
            frequency: freq, bandwidth: bw,
            spreadingFactor: preset.spreadingFactor, codingRate: preset.codingRate,
            repeatMode: false
        )
        // Radio params require reboot to take effect
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            connectionManager.sendCommand(MeshCoreProtocol.buildReboot(), label: "REBOOT")
        }
        dismiss()
    }
}
