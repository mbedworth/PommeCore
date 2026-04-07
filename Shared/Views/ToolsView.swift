//
//  ToolsView.swift
//  PommeCore
//
//  Standalone tools that don't require a radio connection or specific contact.
//

#if !os(watchOS)
import SwiftUI
import MeshCoreKit

struct ToolsView: View {
    @State private var showLineOfSight = false

    var body: some View {
        List {
            Section {
                Button {
                    showLineOfSight = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(MeshTheme.accent.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                                .foregroundStyle(MeshTheme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Line of Sight")
                                .font(.body)
                                .foregroundStyle(MeshTheme.textPrimary)
                            Text("Terrain analysis with Fresnel zone for RF path planning")
                                .font(.caption)
                                .foregroundStyle(MeshTheme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(MeshTheme.surface)
            } header: {
                Text("Planning Tools")
            } footer: {
                Text("These tools work offline and don't require a radio connection.")
            }
        }
        .meshTheme()
        .navigationTitle("Tools")
        .sheet(isPresented: $showLineOfSight) {
            LineOfSightView()
                .frame(minWidth: 400, minHeight: 600)
        }
    }
}
#endif
