import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0
    private let lastPage = 3

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                connectPage.tag(1)
                communicatePage.tag(2)
                getStartedPage.tag(3)
            }
            #if os(watchOS)
            .tabViewStyle(.carousel)
            #elseif os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .background(MeshTheme.background)
            .animation(.easeInOut, value: currentPage)

            // Skip button (top-right, all pages except last)
            if currentPage < lastPage {
                HStack {
                    Spacer()
                    Button {
                        withAnimation { hasCompletedOnboarding = true }
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .foregroundStyle(MeshTheme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 72))
                .foregroundStyle(MeshTheme.accent)
            Text("Welcome to MeshCore")
                .font(.largeTitle.bold())
                .foregroundStyle(MeshTheme.textPrimary)
            Text("Off-Grid Mesh Messaging")
                .font(.title3)
                .foregroundStyle(MeshTheme.accent)
            Text("Send messages, share channels, and connect with others using LoRa radio \u{2014} no internet or cell service needed.")
                .font(.body)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            navigationControls
        }
        .padding()
    }

    private var connectPage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "cable.connector")
                .font(.system(size: 72))
                .foregroundStyle(MeshTheme.accent)
            Text("Connect Your Radio")
                .font(.title.bold())
                .foregroundStyle(MeshTheme.textPrimary)
            Text("MeshCore works with companion radios over Bluetooth Low Energy. Turn on your radio and the app will find it automatically.")
                .font(.body)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 24) {
                VStack {
                    Image(systemName: "wave.3.right")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.accent)
                    Text("BLE")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                #if os(macOS)
                VStack {
                    Image(systemName: "cable.connector.horizontal")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.accent)
                    Text("USB")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                #endif
            }
            Spacer()
            navigationControls
        }
        .padding()
    }

    private var communicatePage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 72))
                .foregroundStyle(MeshTheme.accent)
            Text("Communicate Off-Grid")
                .font(.title.bold())
                .foregroundStyle(MeshTheme.textPrimary)
            Text("Send direct messages, join channels, and connect with others across the mesh network without internet or cell service.")
                .font(.body)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 32) {
                VStack {
                    Image(systemName: "person.2")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.accent)
                    Text("Direct")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                VStack {
                    Image(systemName: "number")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.accent)
                    Text("Channels")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
                VStack {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(MeshTheme.accent)
                    Text("Rooms")
                        .font(.caption)
                        .foregroundStyle(MeshTheme.textSecondary)
                }
            }
            Spacer()
            navigationControls
        }
        .padding()
    }

    private var getStartedPage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 72))
                .foregroundStyle(MeshTheme.accent)
            Text("Get Started")
                .font(.title.bold())
                .foregroundStyle(MeshTheme.textPrimary)
            Text("Turn on your MeshCore radio and tap Connect to begin.")
                .font(.body)
                .foregroundStyle(MeshTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                withAnimation { hasCompletedOnboarding = true }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(MeshTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)

            navigationControls
        }
        .padding()
    }

    // MARK: - Navigation Controls

    private var navigationControls: some View {
        HStack(spacing: 20) {
            // Back arrow
            Button {
                withAnimation { currentPage = max(0, currentPage - 1) }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundStyle(currentPage > 0 ? MeshTheme.accent : MeshTheme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(currentPage == 0)

            // Page dots
            HStack(spacing: 8) {
                ForEach(0...lastPage, id: \.self) { page in
                    Circle()
                        .fill(page == currentPage ? MeshTheme.accent : MeshTheme.textSecondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            // Forward arrow
            Button {
                if currentPage < lastPage {
                    withAnimation { currentPage += 1 }
                } else {
                    withAnimation { hasCompletedOnboarding = true }
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(MeshTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 20)
    }
}
