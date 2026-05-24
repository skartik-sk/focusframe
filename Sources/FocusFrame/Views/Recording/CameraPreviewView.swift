import SwiftUI
import AVFoundation
import AppKit
import QuartzCore

struct CameraPreviewView: NSViewRepresentable {
    let isEnabled: Bool
    let deviceID: String?

    func makeNSView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.setRunning(isEnabled, deviceID: deviceID)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewContainerView, context: Context) {
        nsView.setRunning(isEnabled, deviceID: deviceID)
    }

    static func dismantleNSView(_ nsView: CameraPreviewContainerView, coordinator: ()) {
        nsView.setRunning(false, deviceID: nil)
    }
}

final class CameraPreviewContainerView: NSView {
    private let sessionController = CameraPreviewSessionController()
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = sessionController.session
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func setRunning(_ running: Bool, deviceID: String?) {
        sessionController.setRunning(running, deviceID: deviceID)
    }
}

private final class CameraPreviewSessionController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.screenrecorder.camera-preview")
    private var configured = false
    private var configuredDeviceID: String?

    func setRunning(_ running: Bool, deviceID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if running {
                do {
                    try self.configureIfNeeded(deviceID: deviceID)
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                } catch {
                    print("Camera preview failed: \(error)")
                }
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureIfNeeded(deviceID: String?) throws {
        if configured, configuredDeviceID == deviceID {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .medium
        defer {
            session.commitConfiguration()
        }

        for input in session.inputs {
            session.removeInput(input)
        }

        guard let device = MediaDeviceCatalog.device(for: deviceID, mediaType: .video) else {
            throw WebcamError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw WebcamError.configurationFailed
        }
        session.addInput(input)
        configured = true
        configuredDeviceID = deviceID
    }
}
