import Foundation
import Messages
import Observation

/// Bridge between the SwiftUI views and the `MSMessagesAppViewController`:
/// presentation style, the active conversation, and staging bubbles.
@MainActor
@Observable
final class ConversationHost {
    @ObservationIgnored weak var controller: MSMessagesAppViewController?
    var conversation: MSConversation?
    var presentationStyle: MSMessagesAppPresentationStyle = .compact

    /// Set when the user taps a League Market bubble; the token changes on every tap
    /// so the same invite can be handled twice.
    private(set) var pendingInvite: MarketInvite?
    private(set) var pendingInviteToken = 0
    var errorMessage: String?

    var isExpanded: Bool { presentationStyle == .expanded }

    /// `$<uuid>` for the local participant; Messages substitutes the contact's name.
    var senderToken: String {
        guard let conversation else { return "Someone" }
        return "$" + conversation.localParticipantIdentifier.uuidString
    }

    func expand() { controller?.requestPresentationStyle(.expanded) }
    func collapse() { controller?.requestPresentationStyle(.compact) }

    func handle(selected message: MSMessage) {
        guard let invite = MarketInvite(url: message.url) else { return }
        pendingInvite = invite
        pendingInviteToken += 1
    }

    /// Reuse the tapped bubble's session when it is for the same league, so Messages
    /// updates that bubble in place instead of stacking a new one (GamePigeon behaviour).
    func session(for leagueID: UUID) -> MSSession? {
        guard let selected = conversation?.selectedMessage,
              let invite = MarketInvite(url: selected.url),
              invite.leagueID == leagueID else { return nil }
        return selected.session
    }

    /// Put the bubble in the compose field. The person still taps send; Messages does not
    /// let an extension send on its own.
    func stage(_ message: MSMessage, collapseAfter: Bool = true, completion: ((Error?) -> Void)? = nil) {
        guard let conversation else {
            errorMessage = "No conversation is open. Reopen Fantasy Market from Messages to share."
            completion?(MarketError.message(errorMessage!))
            return
        }
        conversation.insert(message) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = "Could not add the card to Messages: \(error.localizedDescription). Your market changes are saved; use Share in chat to try again."
                } else if collapseAfter { self?.collapse() }
                completion?(error)
            }
        }
    }
}
