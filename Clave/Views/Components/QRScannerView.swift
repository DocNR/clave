import SwiftUI
import AVFoundation

/// SwiftUI wrapper around AVCaptureSession + AVCaptureMetadataOutput
/// configured for QR detection. Calls `onCode(_:)` once per detected
/// QR (after which the parent should stop scanning by hiding this view
/// or setting `isScanning = false`). Supports the empty/denied/restricted
/// permission cases via the `onPermissionDenied` closure.
struct QRScannerView: UIViewRepresentable {
    var isScanning: Bool
    var onCode: (String) -> Void
    var onPermissionDenied: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onPermissionDenied: onPermissionDenied)
    }

    func makeUIView(context: Context) -> ScannerUIView {
        let view = ScannerUIView()
        view.coordinator = context.coordinator
        view.checkPermissionAndStart()
        return view
    }

    func updateUIView(_ uiView: ScannerUIView, context: Context) {
        uiView.coordinator = context.coordinator
        if isScanning {
            uiView.startIfReady()
        } else {
            uiView.stop()
        }
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        let onPermissionDenied: () -> Void
        private var lastCodeAt: Date?

        init(onCode: @escaping (String) -> Void,
             onPermissionDenied: @escaping () -> Void) {
            self.onCode = onCode
            self.onPermissionDenied = onPermissionDenied
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            // Debounce so we don't flood the parent with the same code repeated.
            if let last = lastCodeAt, Date().timeIntervalSince(last) < 1.0 { return }
            lastCodeAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.onCode(value)
            }
        }
    }

    class ScannerUIView: UIView {
        weak var coordinator: Coordinator?
        private var session: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override class var layerClass: AnyClass { CALayer.self }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }

        func checkPermissionAndStart() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startIfReady()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startIfReady()
                        } else {
                            self?.coordinator?.onPermissionDenied()
                        }
                    }
                }
            case .denied, .restricted:
                coordinator?.onPermissionDenied()
            @unknown default:
                coordinator?.onPermissionDenied()
            }
        }

        func startIfReady() {
            guard session == nil else {
                if let s = session, !s.isRunning {
                    DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
                }
                return
            }
            let s = AVCaptureSession()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  s.canAddInput(input) else {
                coordinator?.onPermissionDenied()
                return
            }
            s.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard s.canAddOutput(output) else {
                coordinator?.onPermissionDenied()
                return
            }
            s.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: s)
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
            previewLayer = layer
            session = s

            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        func stop() {
            if let s = session, s.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
            }
        }

        deinit { stop() }
    }
}
