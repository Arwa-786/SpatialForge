//
//  OnboardingView.swift
//  HoloSmith
//
//  SpatialForge — one-time first-run walkthrough shown before the Home
//  screen, explaining how the SpatialPuck's tilt/distance/color sensing
//  and model import map onto the 3D viewport.
//

import SwiftUI

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let body: String
}

private let onboardingPages: [OnboardingPage] = [
    OnboardingPage(
        systemImage: "cube.transparent",
        title: "Welcome to HoloSmith",
        body: "Point the SpatialPuck at the world and watch a live 3D model respond to it in real time."
    ),
    OnboardingPage(
        systemImage: "rotate.3d",
        title: "Tilt to Rotate",
        body: "Tilting the puck rotates the model on screen to match — pitch and roll come straight from its onboard motion sensor."
    ),
    OnboardingPage(
        systemImage: "arrow.up.left.and.arrow.down.right",
        title: "Move to Zoom",
        body: "Moving the puck closer to or farther from a surface scales the model up or down."
    ),
    OnboardingPage(
        systemImage: "eyedropper.halffull",
        title: "Sense Real Color",
        body: "Hold the puck near a real surface and its color sensor tints the model to match. Import your own USDZ model from the workspace to try it on something you made."
    )
]

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(onboardingPages.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 20) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 72))
                            .foregroundColor(.accentColor)
                        Text(item.title)
                            .font(.title2.bold())
                        Text(item.body)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < onboardingPages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    isComplete = true
                }
            } label: {
                Text(page < onboardingPages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}
