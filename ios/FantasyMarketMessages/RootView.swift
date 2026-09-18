import SwiftUI

/// Switches between the compact drawer and the expanded screens, and turns a tapped
/// bubble into "join this league and open its board".
struct RootView: View {
    let store: MarketStore
    let host: ConversationHost

    @State private var route: Route = .drawer
    @State private var handledInviteToken = 0

    enum Route: Hashable {
        case drawer, board, newMarket, join
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.field.ignoresSafeArea()
            content
            if let toast = store.toast {
                ToastView(text: toast)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .preferredColorScheme(.dark)
        .tint(Theme.chalk)
        .onAppear(perform: handleInvite)
        .onChange(of: host.pendingInviteToken) { _, _ in handleInvite() }
        .onChange(of: store.isBootstrapped) { _, _ in handleInvite() }
        .onChange(of: store.needsName) { _, _ in handleInvite() }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil },
                                    set: { if !$0 { store.clearError() } })) {
            Button("OK") { store.clearError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.needsName {
            NameView(store: store)
        } else if !host.isExpanded {
            drawer
        } else {
            switch route {
            case .drawer:
                drawer
            case .board:
                BoardView(store: store, host: host) {
                    store.closeLeague()
                    route = .drawer
                    host.collapse()
                }
            case .newMarket:
                NewMarketView(store: store, host: host,
                              onDone: { route = .board },
                              onCancel: { route = .drawer; host.collapse() })
            case .join:
                JoinMarketView(store: store,
                               onDone: { route = .board },
                               onCancel: { route = .drawer; host.collapse() })
            }
        }
    }

    private var drawer: some View {
        DrawerView(store: store, host: host,
                   onOpen: { league in
                       route = .board
                       host.expand()
                       Task {
                           do { try await store.open(leagueID: league.id) }
                           catch { store.errorMessage = error.marketMessage }
                       }
                   },
                   onNew: { route = .newMarket; host.expand() },
                   onJoin: { route = .join; host.expand() })
    }

    /// A tapped bubble: join (idempotent server-side) and show the board.
    private func handleInvite() {
        guard let invite = host.pendingInvite,
              host.pendingInviteToken != handledInviteToken,
              store.isBootstrapped, !store.needsName else { return }
        handledInviteToken = host.pendingInviteToken
        route = .board
        host.expand()
        Task {
            do { try await store.join(code: invite.inviteCode) }
            catch { store.errorMessage = error.marketMessage }
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.body(15, weight: .semibold))
            .foregroundStyle(Theme.field)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.chalk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.horizontal, 24)
    }
}
