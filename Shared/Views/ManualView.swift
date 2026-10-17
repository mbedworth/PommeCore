//
//  ManualView.swift
//  PommeCore
//
//  The user manual, rendered from `HelpCatalog`.
//
//  It ships inside the app rather than behind a link, because this is an
//  off-grid app: a manual that needs a network connection is unavailable
//  exactly when it is needed most — out of signal, trying to work out why a
//  message will not deliver.
//
//  There is no content in this file. Everything the user reads comes from
//  `HelpCatalog`, so the manual and the app's inline help can never disagree
//  about a threshold or a behaviour.
//
//  Created by Michael P. Bedworth on 10/12/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import SwiftUI

struct ManualView: View {

    @State private var query = ""

    private var matches: [HelpTopic] {
        HelpCatalog.topics.filter { $0.matches(query) }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if isSearching {
                searchResults
            } else {
                ForEach(HelpChapter.allCases) { chapter in
                    Section {
                        ForEach(HelpCatalog.topics(in: chapter)) { topic in
                            row(for: topic)
                        }
                    } header: {
                        Label {
                            Text(chapter.title.display)
                        } icon: {
                            Image(systemName: chapter.symbol)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MeshTheme.background)
        .navigationTitle("Manual")
        .searchable(text: $query, prompt: Text("Search the manual"))
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        if matches.isEmpty {
            Section {
                Text("Nothing matches that.")
                    .foregroundStyle(MeshTheme.textSecondary)
                    .listRowBackground(MeshTheme.surface)
            } footer: {
                Text("Try a single word — “flood”, “advert”, “channel”, “battery”.")
            }
        } else {
            Section {
                ForEach(matches) { topic in
                    row(for: topic)
                }
            } header: {
                Text("^[\(matches.count) topic](inflect: true)")
            }
        }
    }

    // MARK: - Rows

    private func row(for topic: HelpTopic) -> some View {
        NavigationLink {
            ManualTopicView(topic: topic)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: topic.symbol)
                    .foregroundStyle(MeshTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title.display)
                        .foregroundStyle(MeshTheme.textPrimary)
                    Text(topic.summary.display)
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(MeshTheme.surface)
        // One VoiceOver unit per topic: the title and summary are a single
        // thing to decide about, not two.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Topic Page

struct ManualTopicView: View {

    let topic: HelpTopic

    private var relatedTopics: [HelpTopic] {
        topic.related.compactMap { HelpCatalog.topic(id: $0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(topic.body) { block in
                    view(for: block)
                }
            } header: {
                Text(topic.summary.display)
                    .textCase(nil)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !relatedTopics.isEmpty {
                Section {
                    ForEach(relatedTopics) { related in
                        NavigationLink {
                            ManualTopicView(topic: related)
                        } label: {
                            Label {
                                Text(related.title.display)
                                    .foregroundStyle(MeshTheme.textPrimary)
                            } icon: {
                                Image(systemName: related.symbol)
                                    .foregroundStyle(MeshTheme.accent)
                            }
                        }
                        .listRowBackground(MeshTheme.surface)
                    }
                } header: {
                    Text("Read Next")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MeshTheme.background)
        .navigationTitle(topic.title.display)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text.display)
                .foregroundStyle(MeshTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(MeshTheme.surface)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.key) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: "•")
                            .foregroundStyle(MeshTheme.accent)
                        Text(item.display)
                            .foregroundStyle(MeshTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .listRowBackground(MeshTheme.surface)

        case .note(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(MeshTheme.accent)
                Text(text.display)
                    .font(.callout)
                    .foregroundStyle(MeshTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(MeshTheme.surfaceLight)
            .accessibilityElement(children: .combine)

        case .fact(let label, let value):
            VStack(alignment: .leading, spacing: 2) {
                Text(label.display)
                    .font(.caption)
                    .foregroundStyle(MeshTheme.accent)
                Text(value.display)
                    .foregroundStyle(MeshTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(MeshTheme.surface)
            .accessibilityElement(children: .combine)
        }
    }
}
