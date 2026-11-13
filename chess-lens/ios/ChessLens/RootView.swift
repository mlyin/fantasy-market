import SwiftUI
import UIKit

struct RootView: View {
  @ObservedObject var glasses: GlassesController

  var body: some View {
    ZStack(alignment: .bottom) {
      // Inside the safe area: the web app lays itself out as an ordinary page.
      WebContainer(glasses: glasses)

      if glasses.lensPreviewVisible {
        LensPreviewPanel(
          makePreview: { glasses.makeLensPreviewView() },
          close: { glasses.setLensPreview(visible: false) }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.2), value: glasses.lensPreviewVisible)
    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
  }
}

/// What the simulated glasses' display is showing, floating over the web app. Its
/// buttons are live: selecting "Scan" here runs the same path as on real glasses.
struct LensPreviewPanel: View {
  let makePreview: () -> UIView?
  let close: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Label("Lens preview", systemImage: "eyeglasses")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.white.opacity(0.85))
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityLabel("Close lens preview")
      }

      LensPreviewHost(makePreview: makePreview)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .padding(12)
    .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
  }
}

private struct LensPreviewHost: UIViewRepresentable {
  let makePreview: () -> UIView?

  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    container.backgroundColor = .black
    if let preview = makePreview() {
      preview.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(preview)
      NSLayoutConstraint.activate([
        preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        preview.topAnchor.constraint(equalTo: container.topAnchor),
        preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
    }
    return container
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}
