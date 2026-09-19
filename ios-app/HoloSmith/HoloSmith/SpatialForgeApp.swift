//
//  SpatialForgeApp.swift
//  SpatialForge (ChromaGrip) — iOS Companion
//
//  Single-file SwiftUI + SceneKit app. Connects to the ESP32's
//  WebSocket AP and drives a 3D node's rotation, scale, and material
//  color from live wrist-cuff telemetry.
//

import Combine
import SwiftUI
import SceneKit

// MARK: - Telemetry Model

struct Telemetry: Decodable {
    let pitch: Double
    let roll: Double
    let dist: Double
    let r: Int
    let g: Int
    let b: Int
}

// MARK: - WebSocket Client

final class TelemetryClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var pitch: Double = 0
    @Published var roll: Double = 0
    @Published var dist: Double = 10
    @Published var color: Color = .gray
    @Published var isConnected: Bool = false

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
                self.listen() // keep listening for the next frame
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
            self.color = Color(
                red: Double(frame.r) / 255.0,
                green: Double(frame.g) / 255.0,
                blue: Double(frame.b) / 255.0
            )
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.connect()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.isConnected = true }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.isConnected = false }
    }
}

// MARK: - Scene

final class SpatialScene {
    let scene = SCNScene()
    let objectNode = SCNNode(geometry: SCNTorus(ringRadius: 1.0, pipeRadius: 0.35))

    init() {
        objectNode.geometry?.firstMaterial?.diffuse.contents = UIColor.gray
        objectNode.geometry?.firstMaterial?.lightingModel = .physicallyBased
        scene.rootNode.addChildNode(objectNode)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 0, 6)
        scene.rootNode.addChildNode(camera)

        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .omni
        light.position = SCNVector3(0, 5, 8)
        scene.rootNode.addChildNode(light)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 300
        scene.rootNode.addChildNode(ambient)
    }

    func update(pitchDeg: Double, rollDeg: Double, distCM: Double, color: UIColor) {
        objectNode.eulerAngles = SCNVector3(
            Float(pitchDeg * .pi / 180.0),
            0,
            Float(rollDeg * .pi / 180.0)
        )

        // Map 3–20cm air-slider range to a 0.4x–2.5x model scale
        let clamped = max(3.0, min(20.0, distCM))
        let t = (clamped - 3.0) / (20.0 - 3.0)
        let scaleValue = Float(0.4 + t * (2.5 - 0.4))
        objectNode.scale = SCNVector3(scaleValue, scaleValue, scaleValue)

        objectNode.geometry?.firstMaterial?.diffuse.contents = color
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var client = TelemetryClient()
    @State private var spatial = SpatialScene()

    var body: some View {
        ZStack(alignment: .top) {
            SceneView(
                scene: spatial.scene,
                options: [.allowsCameraControl]
            )
            .ignoresSafeArea()
            .onChange(of: client.pitch) { _ in refreshScene() }
            .onChange(of: client.roll) { _ in refreshScene() }
            .onChange(of: client.dist) { _ in refreshScene() }
            .onChange(of: client.color) { _ in refreshScene() }

            statusBar
        }
        .onAppear { client.connect() }
        .onDisappear { client.disconnect() }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(client.isConnected ? "SpatialPuck Connected" : "Connecting…")
                .font(.caption)
                .foregroundColor(.white)
        }
        .padding(8)
        .background(.black.opacity(0.6))
        .cornerRadius(8)
        .padding()
    }

    private func refreshScene() {
        spatial.update(
            pitchDeg: client.pitch,
            rollDeg: client.roll,
            distCM: client.dist,
            color: UIColor(client.color)
        )
    }
}

// MARK: - App Entry

@main
struct SpatialForgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
