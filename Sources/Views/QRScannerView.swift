import AVFoundation
import SwiftUI

/// Scans the QR code ZCode shows when pairing a new session. The code is a
/// normal `/remote/v4?sid=…&mid=…` link, parsed by `RemoteLink`.
struct QRScannerView: UIViewRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        let coordinator = context.coordinator

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            coordinator.start(in: view)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else { return }
                DispatchQueue.main.async { coordinator.start(in: view) }
            }
        case .denied, .restricted:
            coordinator.showPermissionHint(in: view)
        @unknown default:
            break
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// AVFoundation invokes the metadata delegate on its own queue. Keeping the
    /// coordinator nonisolated avoids the Swift 6 actor check in the @objc thunk;
    /// only the scanned-code callback hops to the main actor.
    nonisolated final class Coordinator: NSObject, @unchecked Sendable, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: @MainActor (String) -> Void
        private let session = AVCaptureSession()
        private let lock = NSLock()
        private var hasCode = false

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        @MainActor
        func start(in view: UIView) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                showPermissionHint(in: view)
                return
            }
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)

            session.startRunning()
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let code = object.stringValue else { return }

            lock.lock()
            let isFirstCode = !hasCode
            if isFirstCode { hasCode = true }
            lock.unlock()
            guard isFirstCode else { return }

            let callback = onCode
            Task { @MainActor in
                callback(code)
            }
        }

        @MainActor
        func showPermissionHint(in view: UIView) {
            let label = UILabel()
            label.text = "Камера недоступна"
            label.textColor = .white
            label.textAlignment = .center
            label.frame = view.bounds
            view.addSubview(label)
        }
    }
}
