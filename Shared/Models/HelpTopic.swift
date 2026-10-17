//
//  HelpTopic.swift
//  PommeCore
//
//  The manual's content model.
//
//  ## Why the text lives here and not in the views
//
//  Before this file, every explanation in the app was written at its point of
//  use — eight `sectionInfoHeader` strings, twenty-three `Section(footer:)`
//  strings, four `InfoPopover` call sites — in inconsistent forms and attached
//  to sections rather than to the thing being explained. That is how the map
//  legend and the overlay it described drifted apart: two copies of one fact,
//  with nothing keeping them equal.
//
//  So an explanation is written once, here, and the UI reads it. The manual is
//  not a second copy of the help text; it is the help text, rendered as a book.
//  That is design principle 2 (one source of truth) made structural instead of
//  a thing to remember, and principle 4 (reuse, never duplicate).
//
//  ## Why `HelpText` exists
//
//  A manual has to be searchable, and search needs a `String`. The app's rule
//  for a String that reaches the user is `String(localized:)` (Critical Rule
//  18) — but that initialiser only accepts a *literal*, so it cannot resolve a
//  key held in a registry at runtime. `HelpText` therefore keeps the English
//  text once and resolves it two ways from that single literal: as a
//  `LocalizedStringKey` for display, and through the bundle for search. Both
//  read the same catalog entry, so a translation can never apply to one and
//  not the other.
//
//  Because the literals here sit in a registry rather than inside `Text(...)`,
//  neither Xcode's extraction nor `check_literals_in_catalog` can see them.
//  `check_help_catalog` in `scripts/check_rules.py` covers exactly this gap —
//  it fails the build if any string in this file is missing from
//  `Shared/Localizable.xcstrings`. Without it this file would be precisely the
//  blind spot that let 51 untranslated literals accumulate unnoticed.
//

import Foundation
import SwiftUI

// MARK: - Help Text

/// One piece of user-facing help: a single English literal that serves as both
/// the string-catalog key and the text search matches against.
///
/// Never construct one from a computed or interpolated string. The literal is
/// the catalog key, so a key assembled at runtime has no entry to resolve and
/// would silently render English in all 11 other languages.
struct HelpText: Sendable, Hashable, ExpressibleByStringLiteral {

    /// The English text, which is also the catalog key.
    let key: String

    init(stringLiteral value: String) { self.key = value }
    init(_ key: String) { self.key = key }

    /// For display. Resolved by SwiftUI against the catalog at render time.
    var display: LocalizedStringKey { LocalizedStringKey(key) }

    /// For search and accessibility, where a `String` is unavoidable.
    ///
    /// Falls back to the English key rather than to an empty string: a missing
    /// entry should read as untranslated text, never as a blank topic.
    var localized: String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - Blocks

/// A run of content inside a topic.
///
/// Deliberately a small closed set rather than Markdown. Markdown would put the
/// formatting inside the translated string, where a machine translation can
/// break it — and this project has already shipped 120 structurally broken
/// entries that way. Here the structure is in Swift and only prose is
/// translated, so a bad translation can be wrong but cannot be malformed.
enum HelpBlock: Sendable, Hashable, Identifiable {

    /// A paragraph of prose.
    case paragraph(HelpText)

    /// A list of points. Rendered with bullets.
    case bullets([HelpText])

    /// A short aside — a caveat, a limit, a "this is firmware behaviour, not
    /// ours". Rendered as a callout so it is not mistaken for prose.
    case note(HelpText)

    /// A labelled fact, such as a threshold or a default.
    case fact(label: HelpText, value: HelpText)

    var id: String {
        switch self {
        case .paragraph(let t): return "p:\(t.key)"
        case .bullets(let items): return "b:\(items.map(\.key).joined(separator: "|"))"
        case .note(let t): return "n:\(t.key)"
        case .fact(let label, let value): return "f:\(label.key)=\(value.key)"
        }
    }

    /// Every string in this block, for search.
    var searchText: [HelpText] {
        switch self {
        case .paragraph(let t), .note(let t): return [t]
        case .bullets(let items): return items
        case .fact(let label, let value): return [label, value]
        }
    }
}

// MARK: - Chapters

/// The manual's top-level grouping.
///
/// Three chapters, in the order a user meets them: what the mesh is, how the
/// app drives it, and what to do when it misbehaves.
enum HelpChapter: String, Sendable, CaseIterable, Identifiable {
    case concepts
    case using
    case troubleshooting

    var id: String { rawValue }

    var title: HelpText {
        switch self {
        case .concepts: return "How the Mesh Works"
        case .using: return "Using PommeCore"
        case .troubleshooting: return "When Something Is Wrong"
        }
    }

    var symbol: String {
        switch self {
        case .concepts: return "antenna.radiowaves.left.and.right"
        case .using: return "iphone.gen3"
        case .troubleshooting: return "stethoscope"
        }
    }
}

// MARK: - Topic

/// One page of the manual.
struct HelpTopic: Sendable, Hashable, Identifiable {

    /// A stable slug. Persisted in deep links and in `related`, so it must not
    /// change when a title is reworded.
    let id: String

    let chapter: HelpChapter
    let title: HelpText

    /// One line, shown in the topic list. Must stand alone — it is often all a
    /// user reads.
    let summary: HelpText

    let symbol: String
    let body: [HelpBlock]

    /// Ids of topics worth reading next.
    let related: [String]

    init(id: String,
         chapter: HelpChapter,
         title: HelpText,
         summary: HelpText,
         symbol: String,
         body: [HelpBlock],
         related: [String] = []) {
        self.id = id
        self.chapter = chapter
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.body = body
        self.related = related
    }

    /// Lowercased haystack for search, in the user's language.
    ///
    /// Built on demand rather than cached: the manual is searched by hand at
    /// human speed over a few dozen topics, so there is nothing here worth
    /// spending memory to avoid (principle 7 cuts both ways — an unnecessary
    /// cache is also waste).
    var searchHaystack: String {
        var parts = [title.localized, summary.localized]
        for block in body {
            parts.append(contentsOf: block.searchText.map(\.localized))
        }
        return parts.joined(separator: "\n").lowercased()
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        // Every whitespace-separated term must appear, so narrowing a search by
        // adding a word behaves the way a user expects.
        return trimmed.split(separator: " ").allSatisfy { searchHaystack.contains($0) }
    }
}
