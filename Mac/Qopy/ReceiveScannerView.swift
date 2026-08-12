import SwiftUI
import AppKit

struct ReceiveScannerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scanner: QRScannerController

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                switch model.receivePhase {
                case .openSite, .copied:
                    waitingContent
                case .scanning:
                    cameraContent
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(width: GlassChrome.receiveCardSize.width, height: GlassChrome.receiveCardSize.height)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .padding(GlassChrome.inset)
        .frame(width: GlassChrome.receiveWindowSize.width, height: GlassChrome.receiveWindowSize.height)
        .onAppear {
            if model.receivePhase == .scanning {
                beginScanning()
            }
        }
        .onChange(of: model.receivePhase) { _, phase in
            if phase == .scanning {
                beginScanning()
            } else {
                scanner.stop()
            }
        }
    }

    @ViewBuilder
    private var waitingContent: some View {
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

        if model.receivePhase != .copied {
            Button(action: { model.advanceReceiveToCamera() }) {
                Text("Scan QR instead")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary.opacity(0.55))
            .disabled(model.phonePageURL == nil)
            .opacity(model.phonePageURL == nil ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private var cameraContent: some View {
        ZStack {
            CameraPreview(session: scanner.session, mirrored: true)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if scanner.permissionDenied {
                overlayMessage("Allow Camera in System Settings")
            } else if scanner.cameraUnavailable {
                overlayMessage("No camera available")
            }
        }
        .frame(width: 224, height: 224)

        VStack(spacing: 3) {
            Text(model.lastReceived == nil ? "Point at phone QR" : "Copied")
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

    private var statusDetail: String {
        if let text = model.lastReceived {
            return preview(text)
        }
        return model.receiveStatus
    }

    private func preview(_ text: String) -> String {
        if text.count <= 48 { return text }
        return String(text.prefix(48)) + "…"
    }

    private func beginScanning() {
        scanner.onCode = { payload in
            model.handleScannedPayload(payload)
        }
        scanner.start()
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
