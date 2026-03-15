import SwiftUI

// MARK: - App Theme Preference

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Theme Colors

enum MeshTheme {
    // Primary accent — adaptive green: darker/richer in light mode, bright in dark mode
    static var accent: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.0, green: 0.85, blue: 0.35, alpha: 1.0)
            } else {
                return NSColor(red: 0.0, green: 0.60, blue: 0.25, alpha: 1.0)
            }
        })
        #elseif os(watchOS)
        Color(red: 0.0, green: 0.85, blue: 0.35) // always bright on watch
        #else
        Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.0, green: 0.85, blue: 0.35, alpha: 1.0)
            } else {
                return UIColor(red: 0.0, green: 0.60, blue: 0.25, alpha: 1.0)
            }
        })
        #endif
    }

    // Surface colors — adaptive to light/dark mode
    static var surface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #elseif os(watchOS)
        Color(white: 0.15)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var surfaceLight: Color {
        #if os(macOS)
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #elseif os(watchOS)
        Color(white: 0.22)
        #else
        Color(uiColor: .tertiarySystemGroupedBackground)
        #endif
    }

    static var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(watchOS)
        Color.black
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    // Interactive green — for any element where green is the BACKGROUND with black text on top.
    // Lighter than accent in light mode so black text is readable; medium green in dark mode.
    // Used for: buttons, badges, toggles, pills, login buttons, chat bubbles.
    static var interactiveGreen: Color { outgoingBubble }

    // Message bubbles — independent from accent; light enough for black text
    static var outgoingBubble: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.0, green: 0.65, blue: 0.3, alpha: 1.0)
            } else {
                return NSColor(red: 0.75, green: 0.93, blue: 0.78, alpha: 1.0)
            }
        })
        #elseif os(watchOS)
        Color(red: 0.0, green: 0.65, blue: 0.3)
        #else
        Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.0, green: 0.65, blue: 0.3, alpha: 1.0)
            } else {
                return UIColor(red: 0.75, green: 0.93, blue: 0.78, alpha: 1.0)
            }
        })
        #endif
    }

    static var incomingBubble: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1.0)
            } else {
                return NSColor(red: 1.0, green: 0.88, blue: 0.75, alpha: 1.0)
            }
        })
        #elseif os(watchOS)
        Color(red: 0.80, green: 0.45, blue: 0.10)
        #else
        Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1.0)
            } else {
                return UIColor(red: 1.0, green: 0.88, blue: 0.75, alpha: 1.0)
            }
        })
        #endif
    }

    // Status colors — these system colors adapt automatically
    static let connected = Color.green
    static let connecting = Color.orange
    static let scanning = Color.blue
    static let disconnected = Color.red

    // Text — adaptive
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textOnAccent = Color.black

    // Remote management accent colors
    static let remoteRoom = Color.teal
    static let remoteRepeater = Color.orange
}

// MARK: - TextField Style
//
// .roundedBorder uses systemBackground which is pure black on OLED in dark mode,
// making it invisible on secondarySystemGroupedBackground list rows.
// This style uses the correct elevated surface color for grouped lists.

#if !os(watchOS)
struct MeshTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .foregroundColor(.primary)
            .padding(7)
            #if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
            #else
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            #endif
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}
#endif

// MARK: - Theme Modifier

struct MeshThemeModifier: ViewModifier {
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(selectedTheme.colorScheme)
            .tint(MeshTheme.accent)
    }
}

extension View {
    func meshTheme() -> some View {
        modifier(MeshThemeModifier())
    }

    @ViewBuilder
    func meshListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #elseif os(watchOS)
        self
        #else
        self
        #endif
    }
}
