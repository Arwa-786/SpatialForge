//
//  Telemetry.swift
//  HoloSmith
//
//  Created by Arwa Arshad Ali on 9/19/26.
//
//  SpatialForge — handles the WebSocket connection to the ESP32 and
//  publishes live sensor values for the rest of the app to use.
//
 
import SwiftUI
import Combine
 
struct Telemetry: Decodable {
    let pitch: Double
    let roll: Double
    let dist: Double
    let r: Int
    let g: Int
    let b: Int
}
 
final class TelemetryClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var pitch: Double = 0
    @Published var roll: Double = 0
    @Published var dist: Double = 10
    // Live, instantly-updating sensor reading — the color wheel's dot and
    // swatch track this in real time, so aiming the sensor still gives
    // immediate visual feedback.
    @Published var color: Color = .gray
    @Published var rawR: Int = 128
    @Published var rawG: Int = 128
    @Published var rawB: Int = 128
    // What the 3D model is actually tinted — only changes once a real
    // (non-white) color has been held steady for commitHoldDuration. White
    // is excluded entirely from this, not just untracked: our own readings
    // show it's what the sensor reports with nothing deliberately held
    // against it, so treating it as a valid target would let "nothing
    // there" silently erase an already-captured color.
    @Published var committedColor: Color = .gray
    @Published var isConnected: Bool = false

    private var candidateColorName: String?
    private var candidateStartTime: Date?
    private let commitHoldDuration: TimeInterval = 3.0

    private var smoothR: Double = 128
    private var smoothG: Double = 128
    private var smoothB: Double = 128
    private let smoothing = 0.25
 
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private let espURL = URL(string: "ws://192.168.4.1:81/")!
 
    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }
 
    func connect() {
        webSocketTask = session.webSocketTask(with: espURL)
        webSocketTask?.resume()
        listen()
    }
 
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        isConnected = false
    }

    // Sends a plain-text command to the ESP32 (e.g. "calibrate_white") — the
    // firmware's onWebSocketEvent() handles WStype_TEXT frames and routes
    // these to the matching calibration routine.
    func send(_ command: String) {
        webSocketTask?.send(.string(command)) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }
 
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self.isConnected = false
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleFrame(text)
                    }
                @unknown default:
                    break
                }
                self.listen()
            }
        }
    }
 
    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(Telemetry.self, from: data) else { return }
 
        DispatchQueue.main.async {
            self.pitch = frame.pitch
            self.roll = frame.roll
            self.dist = frame.dist
 
            self.smoothR += self.smoothing * (Double(frame.r) - self.smoothR)
            self.smoothG += self.smoothing * (Double(frame.g) - self.smoothG)
            self.smoothB += self.smoothing * (Double(frame.b) - self.smoothB)
 
            self.rawR = Int(self.smoothR)
            self.rawG = Int(self.smoothG)
            self.rawB = Int(self.smoothB)
            self.color = Color(red: self.smoothR / 255, green: self.smoothG / 255, blue: self.smoothB / 255)

            self.updateCommittedColor()
        }
    }

    // Uses the *named* color (e.g. "Red") as the stability signal instead
    // of raw numeric tolerance — small sensor jitter almost never changes
    // which named color a reading is closest to, even though the raw
    // numbers themselves wobble constantly, which is exactly what made an
    // earlier, numeric-tolerance version of this idea get stuck on gray.
    private func updateCommittedColor() {
        let liveName = nearestColorName(r: rawR, g: rawG, b: rawB)

        // White is skipped entirely, not just excluded from committing — a
        // transient white reading (sensor angle wobble, brief loss of
        // contact) doesn't reset progress toward committing whatever real
        // color came before and after it.
        guard liveName != "White" else { return }

        let now = Date()
        if liveName == candidateColorName {
            if let start = candidateStartTime, now.timeIntervalSince(start) >= commitHoldDuration {
                committedColor = color
            }
        } else {
            candidateColorName = liveName
            candidateStartTime = now
        }
    }
 
    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.connect()
        }
    }
 
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.isConnected = true }
    }
 
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.isConnected = false }
    }
}
 
