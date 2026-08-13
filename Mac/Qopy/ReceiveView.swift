import SwiftUI
import AppKit

struct ReceiveView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(width: GlassChrome.receiveCardSize.width, height: GlassChrome.receiveCardSize.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .padding(GlassChrome.inset)
        .frame(width: GlassChrome.receiveWindowSize.width, height: GlassChrome.receiveWindowSize.height)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.phoneServerError {
            Text(error)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.red.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        } else if model.receivePhase == .copied, let text = model.lastReceived {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 224, height: 160)

            VStack(spacing: 3) {
                Text("Copied")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                Text(preview(text))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 240)
            }
        } else if let url = model.phonePageURL,
                  let image = QRCodeGenerator.image(from: url, dimension: 640) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 3) {
                Text("Scan to open on phone")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                Text("Paste there, then Send to Mac")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
        } else {
            ProgressView()
                .frame(width: 224, height: 224)
        }
    }

    private func preview(_ text: String) -> String {
        if text.count <= 48 { return text }
        return String(text.prefix(48)) + "…"
    }
}
