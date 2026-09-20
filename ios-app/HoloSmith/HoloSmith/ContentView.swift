//
//  ContentView.swift
//  HoloSmith
//
//  Created by Arwa Arshad Ali on 9/19/26.
//
//  SpatialForge — the main screen: the 3D viewport, status bar,
//  color wheel overlay, and the Import Model / Reset buttons.
//
 
import SwiftUI
import SceneKit
import UniformTypeIdentifiers
 
struct ContentView: View {
    @StateObject private var client = TelemetryClient()
    @State private var spatial = SpatialScene()
    @State private var showImporter = false
    @State private var loadedModelName: String? = nil
    @State private var importFailed = false
    @State private var showSettings = false
    @StateObject private var handTracking = HandTrackingManager()
    @State private var lastFistToggle = Date.distantPast
    @StateObject private var voice = VoiceCommandManager()
    // The ESP32 streams a color frame ~45x/sec regardless of what's set
    // here, so a spoken color needs its own slot instead of trying to write
    // into client.color directly — otherwise the very next sensor frame
    // would clobber it within milliseconds. nil means "use the live sensor
    // color," which "use sensor color" (spoken) restores.
    @State private var colorOverride: Color?

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
            .onChange(of: handTracking.activeGesture) { _ in applyGesture() }
            .onChange(of: handTracking.pointerX) { _ in applyGesture() }
            .onChange(of: handTracking.pinchDistance) { _ in applyGesture() }

            topBar

            VStack {
                Spacer()
                HStack {
                    ColorWheelView(rawR: client.rawR, rawG: client.rawG, rawB: client.rawB)
                    Spacer()
                    if handTracking.isActive {
                        HandTrackingOverlayView(handTracking: handTracking)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .onAppear {
            client.connect()
            registerVoiceCommands()
        }
        .onDisappear {
            client.disconnect()
            handTracking.stop()
            voice.stop()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "usdz") ?? .item]
        ) { result in
            switch result {
            case .success(let url):
                let ok = spatial.loadModel(from: url)
                loadedModelName = ok ? url.lastPathComponent : nil
                importFailed = !ok
            case .failure:
                importFailed = true
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(client: client)
        }
    }
 
    private var topBar: some View {
        HStack {
            statusBar
            Spacer()
            HStack(spacing: 8) {
                Button {
                    voice.isListening ? voice.stop() : voice.start()
                } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.caption)
                        .padding(8)
                        .background(voice.isListening ? Color.accentColor.opacity(0.8) : Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }

                Button {
                    handTracking.isActive ? handTracking.stop() : handTracking.start()
                } label: {
                    Image(systemName: handTracking.isActive ? "hand.raised.fill" : "hand.raised")
                        .font(.caption)
                        .padding(8)
                        .background(handTracking.isActive ? Color.accentColor.opacity(0.8) : Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.caption)
                        .padding(8)
                        .background(.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }

                Button {
                    showImporter = true
                } label: {
                    Label("Import Model", systemImage: "cube")
                        .font(.caption)
                        .padding(8)
                        .background(.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
 
                if loadedModelName != nil {
                    Button {
                        spatial.resetToDefaultTorus()
                        loadedModelName = nil
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                            .padding(8)
                            .background(.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.trailing)
        }
        .padding(.top)
    }
 
    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(8)
        .background(.black.opacity(0.6))
        .cornerRadius(8)
        .padding(.leading)
    }
 
    private var statusText: String {
        if !client.isConnected { return importFailed ? "Connecting… (import failed)" : "Connecting…" }
        if let name = loadedModelName { return "Connected — \(name)" }
        return "Connected"
    }
 
    private func refreshScene() {
        spatial.update(
            pitchDeg: client.pitch,
            rollDeg: client.roll,
            distCM: client.dist,
            color: UIColor(colorOverride ?? client.color)
        )
    }

    // Wires the voice manager's callbacks to real app state. Registered on
    // every appear, which is harmless — re-assigning the same closures is a
    // no-op in effect.
    private func registerVoiceCommands() {
        voice.onReset = {
            spatial.resetToDefaultTorus()
            loadedModelName = nil
            colorOverride = nil
        }
        voice.onImportModel = {
            showImporter = true
        }
        voice.onCalibrateWhite = {
            client.send("calibrate_white")
        }
        voice.onCalibrateBlack = {
            client.send("calibrate_black")
        }
        voice.onReadColor = {
            let name = nearestColorName(r: client.rawR, g: client.rawG, b: client.rawB)
            voice.speak(name)
        }
        voice.onSetColor = { name in
            guard let entry = namedColors.first(where: { $0.name == name }) else { return }
            colorOverride = Color(red: entry.r / 255, green: entry.g / 255, blue: entry.b / 255)
            refreshScene()
        }
        voice.onClearColorOverride = {
            colorOverride = nil
            refreshScene()
        }
    }

    // Left-hand gesture -> scene state. Point drives yaw (an axis the puck
    // never touches), pinch temporarily overrides scale, fist toggles freeze.
    // Releasing point/pinch (gesture goes back to .none) hands scale back to
    // the puck; yaw is left wherever it was last pointed, not reset.
    private func applyGesture() {
        switch handTracking.activeGesture {
        case .point:
            let yawDeg = Double(handTracking.pointerX - 0.5) * 2 * 60.0 // -60...60 degrees
            spatial.gestureYawDegrees = yawDeg
            spatial.gestureScaleOverride = nil

        case .pinch:
            let minDistance: CGFloat = 0.02
            let maxDistance: CGFloat = 0.25
            let t = Float(min(max((handTracking.pinchDistance - minDistance) / (maxDistance - minDistance), 0), 1))
            spatial.gestureScaleOverride = 0.4 + t * (2.5 - 0.4) // same range the puck's distance drives

        case .fist:
            let now = Date()
            if now.timeIntervalSince(lastFistToggle) > 0.8 { // cooldown so classifier jitter can't double-toggle
                spatial.isFrozen.toggle()
                lastFistToggle = now
            }
            spatial.gestureScaleOverride = nil

        case .none:
            spatial.gestureScaleOverride = nil
        }
        refreshScene()
    }
}
 
