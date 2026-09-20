//
//  HomeView.swift
//  HoloSmith
//
//  SpatialForge — landing screen shown before entering the live workspace,
//  giving the app a real entry point instead of dropping straight into the
//  3D viewport on launch.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "cube.transparent")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("HoloSmith")
                    .font(.largeTitle.bold())
                Text("Live 3D telemetry from your SpatialPuck")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            NavigationLink {
                ContentView()
            } label: {
                Text("Enter Workspace")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }
}
