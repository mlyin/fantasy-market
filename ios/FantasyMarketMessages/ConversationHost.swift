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
        guard let conversation else { completion?(MarketError.message("No conversation is open.")); return }
        conversation.insert(message) { error in
            Task { @MainActor in completion?(error) }
        }
        if collapseAfter { collapse() }
    }
}
