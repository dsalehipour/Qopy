import SwiftUI
import AppKit

struct SendQRView: View {
    @EnvironmentObject private var model: AppModel

    private var payload: String? {
        if model.sendImage != nil { return model.sendImageURL }
        guard TextPayload.isWithinLimit(model.sendText), !model.sendText.isEmpty else { return nil }
        // Camera / Lens should decode the actual clipboard, including Unicode.
        return TextPayload.encodeForQR(model.sendText)
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 14) {
                Text(model.sendImage == nil ? "Send text to phone" : "Send image to phone")
                    .font(.system(size: 18, weight: .semibold))

                if let warning = model.sendImageError ?? model.sendWarning {
                    Text(warning)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(height: 224)
                } else if let payload, let image = QRCodeGenerator.image(from: payload, dimension: 640) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel(model.sendImage == nil ? "QR for current text" : "QR to download image")
                } else {
                    ProgressView("Preparing image…")
                        .frame(width: 224, height: 224)
                }

                HStack(spacing: 10) {
                    if let image = model.sendImage {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 52, height: 52)
                            .accessibilityLabel("Image being sent")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.sendSource).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Text(model.sendImage == nil ? model.sendText : "PNG · ready to download")
                            .font(.system(size: 14))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                Text(model.sendImage == nil
                     ? "Scan with Camera / Lens, then copy."
                     : "Same Wi-Fi. Scan, then save image.\nKeep this panel open until saved.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Use Latest Clipboard") { model.sendClipboardToPhone() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(28)
            .frame(width: GlassChrome.sendCardSize.width, height: GlassChrome.sendCardSize.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .padding(GlassChrome.inset)
        .frame(width: GlassChrome.sendWindowSize.width, height: GlassChrome.sendWindowSize.height)
    }
}
