import SwiftUI

struct JoinMarketView: View {
    let store: MarketStore
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @State private var error: String?
    @State private var joining = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Join a market", onClose: onCancel)
                Text("Ask the commissioner for the invite code, or just tap their Fantasy Market bubble in the chat.")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.muted)
                LabeledField(label: "Invite code") {
                    TextField("8 characters", text: $code)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(Theme.display(24, weight: .semibold))
                        .focused($focused)
                        .onSubmit(join)
                        .fieldStyle()
                }
                if let error {
                    Text(error).font(Theme.body(15)).foregroundStyle(Theme.ask)
                }
                Button(joining ? "Joining…" : "Join the market", action: join)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(joining || code.trimmingCharacters(in: .whitespaces).count < 4)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
    }

    private func join() {
        guard !joining else { return }
        joining = true
        error = nil
        Task {
            defer { joining = false }
            do {
                let league = try await store.join(code: code)
                store.flash("Welcome to \(league.name)")
                onDone()
            } catch {
                self.error = error.marketMessage
            }
        }
    }
}

struct ScreenHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.display(30))
                .foregroundStyle(Theme.chalk)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.chalk)
                    .frame(width: 34, height: 34)
                    .background(Theme.turf, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.top, 8)
    }
}
