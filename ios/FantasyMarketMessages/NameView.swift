import SwiftUI

/// First launch: pick a display name, then sign in anonymously. Fits the compact drawer.
struct NameView: View {
    let store: MarketStore
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should the league call you?")
                .font(Theme.display(22))
                .foregroundStyle(Theme.chalk)
            HStack(spacing: 8) {
                TextField("Your name", text: $name)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(submit)
                    .fieldStyle()
                Button("Enter", action: submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 96)
                    .disabled(store.isBusy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Everyone starts with $10,000 of play money. No deposits, no payouts, just bragging rights.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = true }
    }

    private func submit() {
        Task { await store.signIn(displayName: name) }
    }
}
