import AVFoundation
import AppKit
import CaptureKit
import SwiftUI

/// Live webcam preview: an `AVCaptureVideoPreviewLayer` on the camera's session. Frames go from the camera to
/// the window server without passing through the app, so the preview costs almost no CPU.
struct CameraPreviewView: NSViewRepresentable {
    let camera: CameraCapture

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.attach(camera.session)
        return view
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        view.attach(camera.session)
    }

    static func dismantleNSView(_ view: PreviewLayerView, coordinator: ()) {
        view.attach(nil)
    }

    final class PreviewLayerView: NSView {
        private let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = bounds
            previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func attach(_ session: AVCaptureSession?) {
            guard previewLayer.session !== session else { return }
            previewLayer.session = session
        }
    }
}
