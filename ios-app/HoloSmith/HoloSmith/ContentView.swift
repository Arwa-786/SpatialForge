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
 
            topBar
 
            VStack {
                Spacer()
                HStack {
                    ColorWheelView(rawR: client.rawR, rawG: client.rawG, rawB: client.rawB)
                    Spacer()
                }
            }
            .padding(.leading, 16)
            .padding(.bottom, 20)
        }
        .onAppear { client.connect() }
        .onDisappear { client.disconnect() }
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
            color: UIColor(client.color)
        )
    }
}
 
