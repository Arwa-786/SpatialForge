//
//  HandTrackingManager.swift
//  HoloSmith
//
//  SpatialForge — front-camera hand tracking for the left-hand gesture set
//  (point / pinch / fist), used alongside the physical puck in the right
//  hand. Runs AVFoundation + Vision's hand-pose detector on a background
//  queue and publishes a debounced gesture plus continuous pointer/pinch
//  values for whichever gesture is currently active.
//

import AVFoundation
import Combine
import UIKit
import Vision

enum HandGestureKind: Equatable {
    case none
    case point
    case pinch
    case fist
}

final class HandTrackingManager: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var activeGesture: HandGestureKind = .none
    // Normalized (0-1) fingertip position while pointing, and thumb-to-index
    // distance while pinching. Vision's coordinate space has its origin at
    // the bottom-left.
    @Published var pointerX: CGFloat = 0.5
    @Published var pointerY: CGFloat = 0.5
    @Published var pinchDistance: CGFloat = 0
    // For the confirmation overlay's skeleton dots.
    @Published var currentPoints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]

    let session = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.holosmith.handtracking")
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private var configured = false

    // A raw per-frame classification is jittery — require the same gesture
    // kind for several consecutive frames before treating it as "active",
    // so a flicker between poses doesn't spam gesture-triggered actions.
    private var pendingKind: HandGestureKind = .none
    private var pendingCount = 0
    private let confirmFrames = 4

    override init() {
        super.init()
        handPoseRequest.maximumHandCount = 1
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self, granted else { return }
            self.processingQueue.async {
                self.configureSessionIfNeeded()
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.isActive = true }
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        isActive = false
        activeGesture = .none
        currentPoints = [:]
        pendingKind = .none
        pendingCount = 0
    }

    private func configureSessionIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .vga640x480 // hand pose detection doesn't need more, and it's faster

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        session.commitConfiguration()
    }

    private func classify(_ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) {
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > 0.4 else { return nil }
            return p.location
        }

        var overlay: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        for (name, p) in points where p.confidence > 0.3 { overlay[name] = p.location }

        guard let wrist = point(.wrist),
              let thumbTip = point(.thumbTip),
              let indexTip = point(.indexTip),
              let indexPIP = point(.indexPIP),
              let middleTip = point(.middleTip),
              let middlePIP = point(.middlePIP),
              let ringTip = point(.ringTip),
              let ringPIP = point(.ringPIP),
              let littleTip = point(.littleTip),
              let littlePIP = point(.littlePIP)
        else {
            publish(kind: .none, tipX: 0.5, tipY: 0.5, pinch: 0, overlay: overlay)
            return
        }

        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        // A finger counts as "curled" when its tip sits closer to the wrist
        // than its own middle knuckle does — a simple, resolution-independent
        // stand-in for a bent finger that doesn't need hand size calibration.
        func isCurled(tip: CGPoint, pip: CGPoint) -> Bool { dist(tip, wrist) < dist(pip, wrist) }

        let indexCurled = isCurled(tip: indexTip, pip: indexPIP)
        let middleCurled = isCurled(tip: middleTip, pip: middlePIP)
        let ringCurled = isCurled(tip: ringTip, pip: ringPIP)
        let littleCurled = isCurled(tip: littleTip, pip: littlePIP)
        let pinchDistance = dist(thumbTip, indexTip)

        if pinchDistance < 0.07 {
            publish(kind: .pinch, tipX: indexTip.x, tipY: indexTip.y, pinch: pinchDistance, overlay: overlay)
        } else if middleCurled && ringCurled && littleCurled && !indexCurled {
            publish(kind: .point, tipX: indexTip.x, tipY: indexTip.y, pinch: pinchDistance, overlay: overlay)
        } else if indexCurled && middleCurled && ringCurled && littleCurled {
            publish(kind: .fist, tipX: indexTip.x, tipY: indexTip.y, pinch: pinchDistance, overlay: overlay)
        } else {
            publish(kind: .none, tipX: indexTip.x, tipY: indexTip.y, pinch: pinchDistance, overlay: overlay)
        }
    }

    private func publish(
        kind: HandGestureKind,
        tipX: CGFloat,
        tipY: CGFloat,
        pinch: CGFloat,
        overlay: [VNHumanHandPoseObservation.JointName: CGPoint]
    ) {
        if kind == pendingKind {
            pendingCount += 1
        } else {
            pendingKind = kind
            pendingCount = 1
        }
        let confirmed = pendingCount >= confirmFrames

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if confirmed { self.activeGesture = kind }
            if kind == .point || kind == .pinch {
                self.pointerX = tipX
                self.pointerY = tipY
            }
            if kind == .pinch { self.pinchDistance = pinch }
            self.currentPoints = overlay
        }
    }
}

extension HandTrackingManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
            guard let observation = handPoseRequest.results?.first else {
                publish(kind: .none, tipX: 0.5, tipY: 0.5, pinch: 0, overlay: [:])
                return
            }
            let points = try observation.recognizedPoints(.all)
            classify(points)
        } catch {
            publish(kind: .none, tipX: 0.5, tipY: 0.5, pinch: 0, overlay: [:])
        }
    }
}
