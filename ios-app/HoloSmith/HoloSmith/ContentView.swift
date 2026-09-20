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
    @StateObject private var voice = VoiceCommandManager()
    // The ESP32 streams a color frame ~45x/sec regardless of what's set
    // here, so a spoken color needs its own slot instead of trying to write
    // into client.committedColor directly — otherwise the very next sensor
    // frame would clobber it within milliseconds. nil means "use the
    // sensor's committed color," which "use sensor color" (spoken) restores.
    @State private var colorOverride: Color?
    // Which part's name to show as a label while pointing/selecting among
    // separated parts — kept as plain @State (rather than making
    // SpatialScene observable) since it's only updated from the same
    // gesture-handling code path that's already synced this way.
    @State private var activePartLabel: String?
    // Fingertip position from the last "pinch" tick, used only to compute
    // how far it moved since then — see applyGesture()'s pinch-and-drag
    // handling. nil whenever pinch isn't the active gesture, so a fresh
    // pinch never computes a jump-delta from a stale, unrelated position.
    @State private var lastPinchPointer: CGPoint?
    // Same idea for open-palm drag (moves the whole assembly — see
    // applyGesture()'s openPalm case), tracked separately from pinch's
    // since they're independent gesture sessions.
    @State private var lastOpenPalmPointer: CGPoint?

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
            .onChange(of: client.committedColor) { _ in refreshScene() }
            .onChange(of: handTracking.activeGesture) { _ in applyGesture() }
            .onChange(of: handTracking.pointerX) { _ in applyGesture() }
            .onChange(of: handTracking.pointerY) { _ in applyGesture() }
            .onChange(of: handTracking.pinchDistance) { _ in applyGesture() }

            topBar

            if let label = activePartLabel {
                Text(label)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.65))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.top, 70)
                    .padding(.horizontal, 40)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: activePartLabel)
            }

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
            seedBundledDemoIfNeeded()
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
                // Copy into the app's own storage instead of only using the
                // picker's temporary reference — that's what makes this file
                // findable by its real name next time, including by voice,
                // without needing to re-pick it.
                let persisted = persistImportedFile(url) ?? url
                let ok = spatial.loadModel(from: persisted)
                loadedModelName = ok ? persisted.deletingPathExtension().lastPathComponent : nil
                importFailed = !ok
                voice.modelOptions = loadModelLibrary()
            case .failure:
                importFailed = true
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                client: client,
                onLoadDemoModel: loadDemoModel,
                onLoadSegmentedDemo: loadSegmentedHeartDemo
            )
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
                    Image(systemName: "cube")
                        .font(.caption)
                        .padding(8)
                        .background(.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }

                if loadedModelName != nil {
                    Button {
                        spatial.resetToDefaultTorus()
                        loadedModelName = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                            .padding(8)
                            .background(.black.opacity(0.6))
                            .foregroundColor(.white)
                            .clipShape(Circle())
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
 
    // Loads the bundled single-mesh heart — no picker, no parts.
    private func loadDemoModel() {
        guard let url = Bundle.main.url(forResource: "DemoHeart", withExtension: "usdz") else { return }
        let ok = spatial.loadModel(from: url)
        loadedModelName = ok ? url.lastPathComponent : nil
        importFailed = !ok
        voice.speak(ok ? "Loaded heart" : "Couldn't load that model")
    }

    // Loads the bundled 6 separate STL files (one per heart structure) as
    // one combined, genuinely multi-part model — this is the one that
    // actually exercises explode/collapse/select, unlike every single-file
    // model tried so far.
    private func loadSegmentedHeartDemo() {
        let names: [(name: String, file: String)] = [
            ("Arteries", "arteries"),
            ("Atrium", "atrium"),
            ("Papillary Muscles", "papillary"),
            ("Valves", "valve"),
            ("Veins", "veins"),
            ("Ventricle", "ventricle")
        ]
        let files: [(name: String, url: URL)] = names.compactMap { entry in
            guard let url = Bundle.main.url(forResource: entry.file, withExtension: "stl") else { return nil }
            return (entry.name, url)
        }
        guard !files.isEmpty else { return }
        let ok = spatial.loadMultiPartModel(from: files)
        loadedModelName = ok ? "Heart (\(files.count) parts)" : nil
        importFailed = !ok
        voice.speak(ok ? "Loaded the segmented heart" : "Couldn't load the segmented heart")
    }

    // The app's own persistent storage — files copied here survive across
    // launches and, critically, can be listed and read anytime without
    // needing the system picker again (unlike the picker's own temporary,
    // security-scoped URLs).
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // Copies a file the user picked into the app's own storage, keyed by its
    // real filename, so it's discoverable later by name instead of only
    // being loadable once from the picker's temporary reference.
    private func persistImportedFile(_ url: URL) -> URL? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let destination = documentsDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            print("Could not persist imported file '\(url.lastPathComponent)': \(error)")
            return nil
        }
    }

    // Puts the bundled demo heart into the same persistent storage imported
    // files live in, once, so it's discovered by loadModelLibrary() the same
    // way as anything you import yourself — one system, not a special case.
    private func seedBundledDemoIfNeeded() {
        guard let bundleURL = Bundle.main.url(forResource: "DemoHeart", withExtension: "usdz") else { return }
        let destination = documentsDirectory.appendingPathComponent("DemoHeart.usdz")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.copyItem(at: bundleURL, to: destination)
    }

    // Builds the voice-loadable model list by looking at what's actually in
    // the app's storage right now, instead of a fixed, hand-picked list —
    // each file's real name (tokenized into words) becomes its own aliases,
    // so saying that file's actual name is what makes it match, not a name
    // guessed in advance. The segmented heart is the one exception: it's a
    // deliberate composite of 6 separate STL files with no single filename
    // of its own to read, so it stays one named entry alongside the rest.
    private func loadModelLibrary() -> [VoiceCommandManager.VoiceModelOption] {
        var options: [VoiceCommandManager.VoiceModelOption] = []

        let files = (try? FileManager.default.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in files where url.pathExtension.lowercased() == "usdz" {
            let displayName = url.deletingPathExtension().lastPathComponent
            let aliases = tokenize(displayName)
            guard !aliases.isEmpty else { continue }
            options.append(VoiceCommandManager.VoiceModelOption(aliases: aliases) {
                let ok = spatial.loadModel(from: url)
                loadedModelName = ok ? displayName : nil
                importFailed = !ok
                voice.speak(ok ? "Loaded \(displayName)" : "Couldn't load \(displayName)")
            })
        }

        options.append(VoiceCommandManager.VoiceModelOption(
            aliases: ["segmented", "heart", "parts", "part", "pieces", "separated", "multi", "six", "components"],
            action: loadSegmentedHeartDemo
        ))

        return options
    }

    // Splits a filename into lowercase word tokens on underscores, hyphens,
    // spaces, and camelCase boundaries — "Cardiac_Anatomy_External_view"
    // becomes ["cardiac", "anatomy", "external", "view"], each of which can
    // independently match against what was actually said.
    private func tokenize(_ name: String) -> [String] {
        var spaced = ""
        for (index, char) in name.enumerated() {
            if char == "_" || char == "-" || char == " " {
                spaced.append(" ")
            } else if char.isUppercase && index > 0 {
                spaced.append(" ")
                spaced.append(char)
            } else {
                spaced.append(char)
            }
        }
        return spaced.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private func refreshScene() {
        spatial.update(
            pitchDeg: client.pitch,
            rollDeg: client.roll,
            distCM: client.dist,
            color: UIColor(colorOverride ?? client.committedColor)
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
        voice.onRecenter = {
            spatial.gesturePositionOffset = SCNVector3(0, 0, 0)
            refreshScene()
        }
        voice.onImportModel = {
            showImporter = true
        }
        voice.onCloseImporter = {
            showImporter = false
        }
        voice.modelOptions = loadModelLibrary()
        voice.onExplode = {
            spatial.explodeParts()
        }
        voice.onCollapse = {
            spatial.collapseParts()
        }
        voice.onLabelPart = { rawLabel in
            let name = rawLabel.capitalized
            if spatial.labelActivePart(name) {
                activePartLabel = name
                voice.speak("Labeled \(name)")
            }
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

    // Left-hand gesture -> scene state. Meaning depends on whether the
    // loaded model has separable parts (spatial.hasParts):
    //
    // No parts (default torus, or an unsegmented import) — gestures act on
    // the whole model directly: point drives yaw (an axis the puck never
    // touches), pinch overrides scale AND, if your pinched hand moves while
    // held, drags the whole model's position — the same combo as pinch-zoom
    // + drag in Photos/Maps. The dragged offset persists after releasing,
    // same as explode/collapse persisting rather than snapping back.
    //
    // Has parts — point sweeps a highlight across them, pinch confirms the
    // one currently highlighted (spatial handles the idempotence: confirming
    // the same part twice, or with nothing highlighted, is a no-op) — a
    // discrete grab, not a drag, so position dragging doesn't apply here.
    // Once confirmed, the puck's rotate/zoom/color drives that part alone —
    // see SpatialScene.update(). Open palm explodes the parts apart; a fist
    // collapses them back and clears any selection.
    private func applyGesture() {
        let multiPart = spatial.hasParts

        switch handTracking.activeGesture {
        case .point:
            if multiPart {
                spatial.setCandidatePart(atFraction: Double(handTracking.pointerX))
                activePartLabel = spatial.candidatePartName ?? spatial.selectedPartName
            } else {
                let yawDeg = Double(handTracking.pointerX - 0.5) * 2 * 60.0 // -60...60 degrees
                spatial.gestureYawDegrees = yawDeg
            }
            spatial.gestureScaleOverride = nil
            lastPinchPointer = nil
            lastOpenPalmPointer = nil

        case .pinch:
            if multiPart {
                spatial.confirmSelection()
                activePartLabel = spatial.selectedPartName
            } else {
                let minDistance: CGFloat = 0.02
                let maxDistance: CGFloat = 0.25
                let t = Float(min(max((handTracking.pinchDistance - minDistance) / (maxDistance - minDistance), 0), 1))
                spatial.gestureScaleOverride = 0.4 + t * (2.5 - 0.4) // same range the puck's distance drives

                lastPinchPointer = applyDrag(from: lastPinchPointer)
            }
            lastOpenPalmPointer = nil

        case .fist:
            spatial.collapseParts()
            spatial.gestureScaleOverride = nil
            activePartLabel = nil
            lastPinchPointer = nil
            lastOpenPalmPointer = nil

        case .openPalm:
            // explodeParts() is idempotent (guarded on !isExploded), so
            // this is harmless to call repeatedly while the gesture is held.
            // Moving your open hand afterward drags the whole assembly —
            // this is the one way to move it while pinch is busy selecting
            // individual parts (pinch-drag only applies in single-model
            // mode, since pinch means "select" once parts exist).
            spatial.explodeParts()
            spatial.gestureScaleOverride = nil
            lastPinchPointer = nil
            lastOpenPalmPointer = applyDrag(from: lastOpenPalmPointer)

        case .none:
            spatial.gestureScaleOverride = nil
            lastPinchPointer = nil
            lastOpenPalmPointer = nil
        }
        refreshScene()
    }

    // Shared by pinch-drag (single-model mode) and open-palm-drag (moves
    // the whole assembly regardless of mode): compares the current
    // fingertip position against `previous`, and — if the movement clears
    // a dead zone that filters out ordinary hand tremor (confirmed live:
    // without it, the model visibly "beat"/drifted even while holding
    // still) — accumulates it into the model's position offset. Returns
    // the position to remember for next time.
    private func applyDrag(from previous: CGPoint?) -> CGPoint {
        let current = CGPoint(x: handTracking.pointerX, y: handTracking.pointerY)
        if let last = previous {
            let dx = Float(current.x - last.x)
            let dy = Float(current.y - last.y)
            let deadZone: Float = 0.006
            if sqrt(dx * dx + dy * dy) > deadZone {
                spatial.gesturePositionOffset.x += dx * 4.0
                spatial.gesturePositionOffset.y += dy * 4.0
            }
        }
        return current
    }
}
 
