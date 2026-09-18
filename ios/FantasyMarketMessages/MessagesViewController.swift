import UIKit
import Messages

final class MessagesViewController: MSMessagesAppViewController {
 private let marketURL = URL(string: "https://fantasy-market-nine.vercel.app")!
 override func willBecomeActive(with conversation: MSConversation) { super.willBecomeActive(with: conversation); render() }
 private func render() {
  let title=UILabel(); title.text="Fantasy Market"; title.font=.boldSystemFont(ofSize:28)
  let subtitle=UILabel(); subtitle.text="Trade your fantasy league with friends"; subtitle.textColor=.secondaryLabel
  let open=UIButton(type:.system); open.setTitle("Open Market",for:.normal); open.addTarget(self,action:#selector(openMarket),for:.touchUpInside)
  let send=UIButton(type:.system); send.setTitle("Send Market to Chat",for:.normal); send.addTarget(self,action:#selector(sendMarket),for:.touchUpInside)
  let stack=UIStackView(arrangedSubviews:[title,subtitle,open,send]); stack.axis=.vertical; stack.spacing=16; stack.translatesAutoresizingMaskIntoConstraints=false
  view.subviews.forEach{$0.removeFromSuperview()}; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),stack.centerYAnchor.constraint(equalTo:view.centerYAnchor)])
 }
 @objc private func openMarket(){ extensionContext?.open(marketURL) }
 @objc private func sendMarket(){ guard let conversation=activeConversation else{return}; let layout=MSMessageTemplateLayout(); layout.caption="Fantasy 2026 Market"; layout.subcaption="Tap to open the live market"; layout.trailingCaption="LIVE"; let message=MSMessage(session:MSSession()); message.layout=layout; var c=URLComponents(string:"https://fantasy-market-nine.vercel.app")!; c.queryItems=[URLQueryItem(name:"source",value:"imessage")]; message.url=c.url; conversation.insert(message) }
}
