import SwiftUI

struct ReceiveScannerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scanner: QRScannerController

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                ZStack {
                    CameraPreview(session: scanner.session)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if scanner.permissionDenied {
                        overlayMessage("Allow Camera in System Settings")
                    } else if scanner.cameraUnavailable {
                        overlayMessage("No camera available")
                    }
                }
                .frame(width: 224, height: 224)

                VStack(spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                    Text(statusDetail)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 240)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(width: 300)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .padding(GlassChrome.inset)
        .frame(width: 300 + GlassChrome.inset * 2, height: 360)
        .onAppear {
            scanner.onCode = { payload in
                model.handleScannedPayload(payload)
            }
            scanner.start()
        }
    }

    private var statusTitle: String {
        model.lastReceived == nil ? "Point at phone QR" : "Copied"
    }

    private var statusDetail: String {
        if let text = model.lastReceived {
            if text.count <= 48 { return text }
            return String(text.prefix(48)) + "…"
        }
        return model.receiveStatus
    }

    private func overlayMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.clear, in: .rect(cornerRadius: 14, style: .continuous))
    }
}
