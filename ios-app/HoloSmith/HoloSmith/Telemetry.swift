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
    @Published var color: Color = .gray
    @Published var rawR: Int = 128
    @Published var rawG: Int = 128
    @Published var rawB: Int = 128
    @Published var isConnected: Bool = false
 
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
 
