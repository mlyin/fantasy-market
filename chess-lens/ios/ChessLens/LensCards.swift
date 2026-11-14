// What the glasses show. Kept in a file that imports MWDATDisplay but not SwiftUI:
// both define `Text`, `Button` and `Image`.

import MWDATDisplay
import UIKit

/// The one thing on the lens at a time. Every send replaces the whole screen and
/// its tap handlers, so the controller keeps this value and re-sends it whenever
/// the display (re)starts.
enum LensCard {
  case idle
  case scanning
  case result(board: UIImage, summary: String)
  case failure(reason: String)

  var isResult: Bool {
    if case .result = self { return true }
    return false
  }
}

enum LensCards {
  /// The display canvas is 600 x 600; the board is sent smaller so the summary and
  /// buttons stay on screen with it.
  static let boardMaxPixels: CGFloat = 360

  static func view(
    for card: LensCard,
    onScan: @escaping @Sendable () -> Void,
    onFlip: @escaping @Sendable () -> Void
  ) -> FlexBox {
    switch card {
    case .idle:
      return idle(onScan: onScan)
    case .scanning:
      return scanning()
    case .result(let board, let summary):
      return result(board: board, summary: summary, onScan: onScan, onFlip: onFlip)
    case .failure(let reason):
      return failure(reason: reason, onScan: onScan)
    }
  }

  static func idle(onScan: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("Chess Lens", style: .heading)
        Text("Look at the board, then select Scan.", style: .body, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
        ButtonGroup {
          Button(label: "Scan", onClick: onScan)
            .actionRole(.primary)
        }
      }
    }
  }

  static func scanning() -> FlexBox {
    FlexBox(direction: .column, spacing: 8) {
      Text("Scanning…", style: .heading)
      Text("Hold still for a moment.", style: .body, color: .secondary)
    }
    .padding(24)
    .background(.card)
  }

  static func result(
    board: UIImage,
    summary: String,
    onScan: @escaping @Sendable () -> Void,
    onFlip: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8, crossAlignment: .center) {
        Image(image: board)
        Text(summary, style: .meta, color: .secondary)
      }

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
        ButtonGroup {
          Button(label: "Scan", onClick: onScan)
            .actionRole(.primary)
          Button(label: "Flip", onClick: onFlip)
        }
      }
    }
  }

  static func failure(reason: String, onScan: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 8) {
        Text("No position", style: .heading)
        Text(reason, style: .body, color: .secondary)
      }
      .padding(24)
      .background(.card)

      FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
        ButtonGroup {
          Button(label: "Scan", onClick: onScan)
            .actionRole(.primary)
        }
      }
    }
  }

  /// A base64 PNG from the web renderer, decoded and scaled for the lens.
  static func boardImage(fromBase64PNG string: String) -> UIImage? {
    var payload = string
    if let comma = payload.range(of: "base64,") {
      payload = String(payload[comma.upperBound...])
    }
    guard
      let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
      let image = UIImage(data: data)
    else {
      return nil
    }
    let longest = max(image.size.width * image.scale, image.size.height * image.scale)
    guard longest > boardMaxPixels, longest > 0 else { return image }
    let ratio = boardMaxPixels / longest
    let target = CGSize(
      width: (image.size.width * image.scale * ratio).rounded(),
      height: (image.size.height * image.scale * ratio).rounded()
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  }
}
