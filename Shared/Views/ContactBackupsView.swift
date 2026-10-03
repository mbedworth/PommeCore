//
//  ContactBackupsView.swift
//  PommeCore
//
//  Browse and restore contact snapshots.
//
//  A snapshot is taken automatically before any bulk contact deletion. This is
//  the only way back: contacts live on the radio, so deleting them there is
//  final, and without this the only recovery was waiting for every node to
//  advert again.
//
//  Created by Michael P. Bedworth on 10/03/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI
import MeshCoreKit

struct ContactBackupsView: View {
    @Environment(ContactBackupStore.self) private var backupStore
    @Environment(ContactStore.self) private var contactStore
    @Environment(ConnectionManager.self) private var connectionManager
    @Environment(DeviceConfig.self) private var deviceConfig

    @State private var backupToRestore: ContactBackup?
    @State private var backupToDelete: ContactBackup?

    private var relevant: [ContactBackup] {
        backupStore.backups(forRadio: deviceConfig.publicKeyHex)
    }

    private var others: [ContactBackup] {
        backupStore.backups.filter { !$0.belongs(toRadio: deviceConfig.publicKeyHex) }
    }

    var body: some View {
        List {
            if let progress = backupStore.restoreProgress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restoring contact \(progress.sent) of \(progress.total)…")
                            .foregroundStyle(MeshTheme.accent)
                        ProgressView(value: Double(progress.sent), total: Double(progress.total))
                    }
                    .listRowBackground(MeshTheme.surface)
                }
                .accessibilityElement(children: .combine)
            }

            if relevant.isEmpty && others.isEmpty {
                Section {
                    Text("No snapshots yet.")
                        .foregroundStyle(MeshTheme.textSecondary)
                        .listRowBackground(MeshTheme.surface)
                } footer: {
                    Text("A snapshot is saved automatically just before contacts are deleted in bulk, so a mistaken deletion can be undone. The last \(ContactBackupRetention.keepCount) are kept.")
                }
            }

            if !relevant.isEmpty {
                Section {
                    ForEach(relevant) { backup in
                        row(for: backup)
                    }
                } header: {
                    Text("This Radio")
                } footer: {
                    Text("Restoring adds these contacts back to the radio. Contacts it already has are updated, never removed, so restoring is safe to retry.")
                }
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { backup in
                        row(for: backup)
                    }
                } header: {
                    Text("Other Radios")
                } footer: {
                    Text("Snapshots taken on a different radio. Contact keys belong to the mesh they were discovered on, so these cannot be restored here.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MeshTheme.background)
        .navigationTitle("Contact Backups")
        .confirmationDialog(
            "Restore Contacts?",
            isPresented: Binding(get: { backupToRestore != nil },
                                 set: { if !$0 { backupToRestore = nil } }),
            presenting: backupToRestore
        ) { backup in
            Button("Restore \(backup.contacts.count) Contacts") {
                restore(backup)
            }
            Button("Cancel", role: .cancel) { backupToRestore = nil }
        } message: { backup in
            Text("\(backup.contacts.count) contacts will be added back to the radio, along with their nicknames, notes and groups. Nothing is deleted.")
        }
        .confirmationDialog(
            "Delete Snapshot?",
            isPresented: Binding(get: { backupToDelete != nil },
                                 set: { if !$0 { backupToDelete = nil } }),
            presenting: backupToDelete
        ) { backup in
            Button("Delete Snapshot", role: .destructive) {
                backupStore.delete(backup)
                backupToDelete = nil
            }
            Button("Cancel", role: .cancel) { backupToDelete = nil }
        } message: { _ in
            Text("This removes the snapshot from this device. The contacts on the radio are not affected.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for backup: ContactBackup) -> some View {
        let restorable = backup.belongs(toRadio: deviceConfig.publicKeyHex)
            && connectionManager.isActivelyConnected
            && !backupStore.isRestoring

        // Tap restores, long-press offers everything — the standard
        // interaction for every row in the app.
        Button {
            backupToRestore = backup
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(backup.contacts.count) contacts")
                        .foregroundStyle(MeshTheme.accent)
                    Spacer()
                    Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                if !backup.reason.isEmpty {
                    Text(backup.reason)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!restorable)
        .listRowBackground(MeshTheme.surface)
        .contextMenu {
            if restorable {
                Button {
                    backupToRestore = backup
                } label: {
                    Label("Restore Contacts", systemImage: "arrow.counterclockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                backupToDelete = backup
            } label: {
                Label("Delete Snapshot", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(restorable
            ? "Restores these contacts to the radio"
            : "Cannot be restored: connect to the radio this snapshot came from")
    }

    // MARK: - Actions

    private func restore(_ backup: ContactBackup) {
        backupToRestore = nil
        guard !backupStore.isRestoring else { return }
        backupStore.beginRestore(count: backup.contacts.count)
        Task { @MainActor in
            // ContactStore owns the send: it paces the frames, stops if the
            // link drops, and verifies against the radio's own list rather
            // than assuming every frame arrived.
            await contactStore.addContacts(backup.contacts)
            // Nicknames, notes, mute state and groups are the app's own — the
            // radio never had them, so they are re-applied here. The contacts
            // themselves come back through the sync the add already triggers.
            contactStore.restoreLocalData(from: backup)
            backupStore.endRestore()
        }
    }
}
