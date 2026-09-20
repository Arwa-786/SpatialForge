//
//  SettingsView.swift
//  HoloSmith
//
//  SpatialForge — in-app color sensor calibration and connection info, so
//  calibrating the white/black points no longer requires plugging into a
//  computer and sending 'w'/'k' over the Arduino Serial Monitor.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: TelemetryClient
    @Environment(\.dismiss) private var dismiss

    @State private var calibrationStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    HStack {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(client.isConnected ? "Connected to SpatialPuck" : "Not connected")
                    }
                    LabeledContent("Network", value: "SpatialPuck")
                    LabeledContent("Address", value: "192.168.4.1:81")
                }

                Section {
                    Button {
                        runCalibration(command: "calibrate_white", label: "White")
                    } label: {
                        Label("Calibrate White Point", systemImage: "circle.fill")
                    }
                    .disabled(!client.isConnected || calibrationStatus != nil)

                    Button {
                        runCalibration(command: "calibrate_black", label: "Black")
                    } label: {
                        Label("Calibrate Black Point", systemImage: "circle")
                    }
                    .disabled(!client.isConnected || calibrationStatus != nil)

                    Button(role: .destructive) {
                        client.send("reset_calibration")
                        showStatus("Calibration reset to defaults.")
                    } label: {
                        Label("Reset Calibration", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!client.isConnected)
                } header: {
                    Text("Color Sensor Calibration")
                } footer: {
                    Text(calibrationStatus ?? "Hold a bright white surface against the puck's sensor, then tap Calibrate White. Repeat with a black surface for Calibrate Black.")
                }

                Section("About") {
                    LabeledContent("App", value: "HoloSmith")
                    LabeledContent(
                        "Version",
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    )
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // Sends the command, then walks the on-screen status through the same
    // timing the firmware's calibrateWhitePoint()/calibrateBlackPoint() use
    // (a hold delay + averaged samples) — there's no completion message sent
    // back over the wire, so this is a local timer, not a device ack.
    private func runCalibration(command: String, label: String) {
        client.send(command)
        calibrationStatus = "Hold a \(label.lowercased()) surface against the sensor now…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            showStatus("\(label) point captured.")
        }
    }

    private func showStatus(_ message: String) {
        calibrationStatus = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            calibrationStatus = nil
        }
    }
}
