//
//  RepeaterConfigView.swift
//  PommeCore
//
//  Repeater relay configuration: enable/disable, slider or contact picker, antenna height.
//

import SwiftUI
import MeshCoreKit

struct RepeaterConfigView: View {
    @Environment(LineOfSightStore.self) private var store
    @Environment(ContactStore.self) private var contactStore

    private var repeaterContacts: [Contact] {
        contactStore.contacts.filter { $0.type == .repeater && ($0.latitude != 0 || $0.longitude != 0) }
    }

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle("Add Relay Repeater", isOn: $store.repeaterEnabled)
                .foregroundStyle(MeshTheme.accent)
                .listRowBackground(MeshTheme.surface)

            if store.repeaterEnabled {
                Picker("Repeater Source", selection: Binding(
                    get: { store.repeaterSource == .slider ? 0 : 1 },
                    set: { store.repeaterSource = $0 == 0 ? .slider : .contact }
                )) {
                    Text("Position on Path").tag(0)
                    Text("Existing Repeater").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(MeshTheme.surface)

                if store.repeaterSource == .slider {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repeater Position: \(String(format: "%.0f%%", store.repeaterSliderFraction * 100)) along path")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                        Slider(value: $store.repeaterSliderFraction, in: 0.05...0.95)
                            .tint(MeshTheme.accent)
                    }
                    .listRowBackground(MeshTheme.surface)
                } else {
                    if repeaterContacts.isEmpty {
                        Text("No repeaters with GPS coordinates available")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .listRowBackground(MeshTheme.surface)
                    } else {
                        Picker("Repeater", selection: $store.repeaterContact) {
                            Text("Select...").tag(Contact?.none)
                            ForEach(repeaterContacts, id: \.publicKey) { contact in
                                Text(contactStore.displayName(for: contact)).tag(Contact?.some(contact))
                            }
                        }
                        .foregroundStyle(MeshTheme.accent)
                        .tint(.primary)
                        .listRowBackground(MeshTheme.surface)
                    }
                }

                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Repeater Antenna")
                            .font(.caption)
                            .foregroundStyle(MeshTheme.accent)
                        Stepper(value: $store.repeaterAntennaHeight, in: 0.5...100, step: 0.5) {
                            Text(String(format: "%.1f m", store.repeaterAntennaHeight))
                                .foregroundStyle(MeshTheme.textPrimary)
                        }
                    }
                }
                .listRowBackground(MeshTheme.surface)
            }
        } header: {
            Text("Relay Repeater")
        }
    }
}
