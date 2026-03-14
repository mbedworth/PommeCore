import SwiftUI

enum MeshTheme {
    // Primary accent — a vibrant green that evokes radio/mesh connectivity
    static let accent = Color("AccentGreen", bundle: nil)
    static let accentFallback = Color(red: 0.0, green: 0.82, blue: 0.44) // #00D170

    // Surface colors for dark UI
    static let surface = Color(white: 0.11)         // cards, input bars
    static let surfaceLight = Color(white: 0.16)     // elevated surfaces
    static let background = Color(white: 0.06)       // deepest background

    // Message bubbles
    static let outgoingBubble = Color(red: 0.0, green: 0.82, blue: 0.44)
    static let incomingBubble = Color(white: 0.18)

    // Status colors
    static let connected = Color(red: 0.0, green: 0.82, blue: 0.44)
    static let connecting = Color(red: 1.0, green: 0.76, blue: 0.0)
    static let scanning = Color(red: 0.35, green: 0.68, blue: 1.0)
    static let disconnected = Color(red: 0.9, green: 0.3, blue: 0.3)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.55)
    static let textOnAccent = Color.black
}

struct DarkThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .tint(MeshTheme.accentFallback)
    }
}

extension View {
    func meshTheme() -> some View {
        modifier(DarkThemeModifier())
    }

    @ViewBuilder
    func meshListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MeshTheme.background)
        #elseif os(watchOS)
        self.scrollContentBackground(.hidden)
            .background(MeshTheme.background)
        #else
        self.scrollContentBackground(.hidden)
            .background(MeshTheme.background)
        #endif
    }
}
