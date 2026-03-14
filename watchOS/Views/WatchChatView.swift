import SwiftUI
import MeshCoreKit

struct WatchChatView: View {
    let contact: Contact
    @EnvironmentObject var viewModel: MeshCoreViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.contacts) { _ in
                    // Placeholder — will show messages for this contact
                    EmptyView()
                }
            }
        }
        .navigationTitle(contact.name)
    }
}
