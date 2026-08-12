import SwiftUI
import AppKit

struct SendQRView: View {
    @EnvironmentObject private var model: AppModel

    private var canShowQR: Bool {
        TextPayload.isWithinLimit(model.sendText) && !model.sendText.isEmpty
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                if let warning = model.sendWarning {
                    Text(warning)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                } else if canShowQR, let image = QRCodeGenerator.image(from: TextPayload.encodeForQR(model.sendText), dimension: 640) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Text("Nothing to send")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.5))
                        .frame(width: 224, height: 224)
                }

                VStack(spacing: 3) {
                    Text("Scan to copy")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                    Text(byteLabel)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(canShowQR ? Color.primary.opacity(0.45) : Color.red.opacity(0.85))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(width: GlassChrome.sendCardSize.width, height: GlassChrome.sendCardSize.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        // Inset must sit outside the glass so the shade can fall off cleanly.
        .padding(GlassChrome.inset)
        .frame(width: GlassChrome.sendWindowSize.width, height: GlassChrome.sendWindowSize.height)
    }

    private var byteLabel: String {
        "\(TextPayload.utf8ByteCount(model.sendText)) / \(TextPayload.maxUTF8Bytes)"
    }
}
