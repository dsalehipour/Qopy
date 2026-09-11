import SwiftUI
import AppKit

struct SendQRView: View {
    @EnvironmentObject private var model: AppModel

    // Two previews plus a count is what fits beside the label without squeezing it
    // onto three lines at the 340pt card width.
    private static let maxThumbnails = 2
    private static let thumbnailSize: CGFloat = 46

    private var isImageMode: Bool { !model.sendImages.isEmpty }
    private var imageCount: Int { model.sendImages.count }

    private var payload: String? {
        if isImageMode { return model.sendImageURL }
        guard TextPayload.isWithinLimit(model.sendText), !model.sendText.isEmpty else { return nil }
        // Camera / Lens should decode the actual clipboard, including Unicode.
        return TextPayload.encodeForQR(model.sendText)
    }

    private var title: String {
        guard isImageMode else { return "Send text to phone" }
        return imageCount == 1 ? "Send image to phone" : "Send \(imageCount) images to phone"
    }

    private var footer: String {
        guard isImageMode else { return "Scan with Camera / Lens, then copy." }
        let verb = imageCount == 1 ? "save image" : "save them"
        return "Same Wi-Fi. Scan, then \(verb).\nKeep this panel open until saved."
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 14) {
                Text(title)
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
                        .accessibilityLabel(isImageMode
                            ? (imageCount == 1 ? "QR to download image" : "QR to download \(imageCount) images")
                            : "QR for current text")
                } else {
                    ProgressView(imageCount > 1 ? "Preparing images…" : "Preparing image…")
                        .frame(width: 224, height: 224)
                }

                HStack(spacing: 10) {
                    if isImageMode {
                        thumbnails
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.sendSource).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Text(isImageMode ? "Ready to download" : model.sendText)
                            .font(.system(size: 14))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                Text(footer)
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

    /// Overlapping stack, same shorthand the phone page uses for a multi-file pick.
    /// Images are fitted rather than filled: a wide button and a tall screenshot are
    /// told apart by their shape, which a centre crop throws away.
    private var thumbnails: some View {
        HStack(spacing: -10) {
            ForEach(Array(model.sendImages.prefix(Self.maxThumbnails).enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .background(.white, in: shape)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white, lineWidth: 2))
            }
            if imageCount > Self.maxThumbnails {
                Text("+\(imageCount - Self.maxThumbnails)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .background(.primary.opacity(0.09), in: shape)
                    .overlay(shape.stroke(.white, lineWidth: 2))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(imageCount == 1 ? "Image being sent" : "\(imageCount) images being sent")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }
}
