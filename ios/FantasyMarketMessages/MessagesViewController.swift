import Messages
import SwiftUI
import UIKit

/// Principal class of the extension (see Info.plist). Hosts the SwiftUI root view and
/// relays Messages lifecycle events to `ConversationHost`.
final class MessagesViewController: MSMessagesAppViewController {
    private let store = MarketStore()
    private let host = ConversationHost()
    private var hosting: UIHostingController<RootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.field)
        host.controller = self

        let hostingController = UIHostingController(rootView: RootView(store: store, host: host))
        hostingController.view.backgroundColor = .clear
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)
        hosting = hostingController
    }

    // MARK: - Conversation lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        host.conversation = conversation
        host.presentationStyle = presentationStyle
        if let selected = conversation.selectedMessage {
            host.handle(selected: selected)
        }
        Task { await store.bootstrap() }
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        host.conversation = conversation
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        host.conversation = conversation
        host.handle(selected: message)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
        host.conversation = conversation
        Task { await store.refresh() }
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        host.presentationStyle = presentationStyle
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        host.presentationStyle = presentationStyle
    }
}
