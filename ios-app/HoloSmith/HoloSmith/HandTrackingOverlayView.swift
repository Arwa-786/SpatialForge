//
//  HandTrackingOverlayView.swift
//  HoloSmith
//
//  SpatialForge — small corner camera preview + hand-skeleton dots shown
//  while gesture control is active. This is a "yes, it sees your hand"
//  confirmation, not a full camera viewfinder — kept deliberately small so
//  it doesn't compete with the 3D model for attention.
//

import AVFoundation
import SwiftUI
import Vision

private struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        if let connection = view.videoPreviewLayer.connection, connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct HandTrackingOverlayView: View {
    @ObservedObject var handTracking: HandTrackingManager

    private let size: CGFloat = 120

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreviewLayerView(session: handTracking.session)

            Canvas { context, canvasSize in
                for (_, point) in handTracking.currentPoints {
                    // Vision points are normalized with origin at bottom-left,
                    // already mirrored to match the mirrored preview above.
                    let x = point.x * canvasSize.width
                    let y = (1 - point.y) * canvasSize.height
                    let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(.green))
                }
            }

            Text(gestureLabel)
                .font(.caption2.bold())
                .padding(4)
                .background(.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(4)
                .padding(4)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.4), lineWidth: 1))
    }

    private var gestureLabel: String {
        switch handTracking.activeGesture {
        case .none: return "—"
        case .point: return "Point"
        case .pinch: return "Pinch"
        case .fist: return "Fist"
        case .openPalm: return "Open Palm"
        }
    }
}
