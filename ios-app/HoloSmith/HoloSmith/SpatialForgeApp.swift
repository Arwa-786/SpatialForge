//
//  SpatialForgeApp.swift
//  SpatialForge (ChromaGrip) — iOS Companion
//
//  App entry point: routes a first launch through OnboardingView, then to
//  HomeView, which pushes into the live ContentView workspace.
//

import SwiftUI

@main
struct SpatialForgeApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                NavigationStack {
                    HomeView()
                }
            } else {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            }
        }
    }
}
