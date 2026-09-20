//
//  Spatialscene.swift
//  HoloSmith
//
//  Created by Arwa Arshad Ali on 9/19/26.
//
//  SpatialForge — the SceneKit scene itself: the default torus, USDZ
//  import/replace logic, and applying live telemetry to whatever
//  model is currently loaded.
//
 
import SceneKit
import UIKit
 
final class SpatialScene {
    let scene = SCNScene()
    let objectNode = SCNNode()

    private var baseScale: Float = 1.0

    // Left-hand gesture state, layered on top of the puck's telemetry.
    // Meaning depends on whether a multi-part model is loaded (see `parts`
    // below): with no parts, point/pinch act on the whole model directly;
    // once parts exist, point aims at one (see setCandidatePart) and pinch
    // selects it (see confirmSelection) instead.
    // - gestureYawDegrees: single-model fallback — "point" drives Y-axis
    //   rotation, an axis the puck never touches, so it never fights with it.
    // - gestureScaleOverride: single-model fallback — while "pinch" is held
    //   this temporarily replaces the puck's distance-driven scale; nil means
    //   "puck controls scale as normal."
    var gestureYawDegrees: Double = 0
    var gestureScaleOverride: Float?
    // Accumulates while dragging during a pinch (single-model mode only —
    // see ContentView.applyGesture) — persists after releasing, the same
    // way explode/collapse persists, rather than snapping back.
    var gesturePositionOffset = SCNVector3(0, 0, 0)

    // A part is any node with its own geometry found inside an imported
    // model (see discoverParts). Exploding moves each one outward from the
    // model's center; collapsing animates them back. Once exploded, `point`
    // sweeps a highlight across `parts` (candidatePart) and `pinch` confirms
    // it (selectedPart) — from then on the puck's rotate/zoom telemetry
    // drives that one part instead of the whole model.
    private struct Part {
        let node: SCNNode
        let originalPosition: SCNVector3
        let explodedPosition: SCNVector3
        let originalScale: SCNVector3
        let originalEulerAngles: SCNVector3
    }
    private var parts: [Part] = []
    private(set) var isExploded = false
    private(set) var selectedPart: SCNNode?
    private var candidatePart: SCNNode?

    var candidatePartName: String? { candidatePart?.name }
    var selectedPartName: String? { selectedPart?.name }

    // > 1, not just non-empty: a single-mesh import (like the plain demo
    // heart) still discovers exactly one geometry node, and treating that
    // as "has parts" wrongly hijacked point/pinch into the multi-part
    // candidate-selection logic for a model that isn't actually multi-part.
    var hasParts: Bool { parts.count > 1 }
 
    init() {
        objectNode.geometry = SCNTorus(ringRadius: 1.0, pipeRadius: 0.35)
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
 
    func loadModel(from url: URL) -> Bool {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let scene = try SCNScene(url: url, options: [.checkConsistency: true])
            
            // 1. Remove all previous nodes inside objectNode
            objectNode.childNodes.forEach { $0.removeFromParentNode() }

            // 2. Remove the default fallback torus geometry so it doesn't render
            // underneath/alongside the imported model
            objectNode.geometry = nil

            // Clear any part/selection state left over from a previous import
            parts.removeAll()
            isExploded = false
            selectedPart = nil
            candidatePart = nil
            gesturePositionOffset = SCNVector3(0, 0, 0)

            let wrapperNode = SCNNode()
            for child in scene.rootNode.childNodes {
                wrapperNode.addChildNode(child)
            }
            objectNode.addChildNode(wrapperNode)

            let modelSpan = fitAndCenter(wrapperNode)
            discoverParts(in: wrapperNode, modelSpan: modelSpan)

            return true
        } catch {
            print("Import error: \(error)")
            return false
        }
    }

    // Loads several single-mesh files (e.g. separate STL files, one per
    // anatomical structure) as one combined model — each file becomes its
    // own part, keyed by the name given for it. Unlike loadModel(), this
    // assumes the files already share one real-world coordinate space (true
    // for files meant to be 3D-printed together in different materials),
    // so no per-file re-centering happens — only the combined result is
    // fit to the standard on-screen size.
    func loadMultiPartModel(from files: [(name: String, url: URL)]) -> Bool {
        objectNode.childNodes.forEach { $0.removeFromParentNode() }
        objectNode.geometry = nil
        parts.removeAll()
        isExploded = false
        selectedPart = nil
        candidatePart = nil
        gesturePositionOffset = SCNVector3(0, 0, 0)

        let wrapperNode = SCNNode()
        var loadedAny = false

        for file in files {
            guard let partScene = try? SCNScene(url: file.url, options: [.checkConsistency: true]) else {
                print("Failed to load part '\(file.name)' from \(file.url.lastPathComponent)")
                continue
            }
            var geometryNode: SCNNode?
            partScene.rootNode.enumerateHierarchy { node, stop in
                if node.geometry != nil && geometryNode == nil {
                    geometryNode = node
                    stop.pointee = true
                }
            }
            guard let node = geometryNode else {
                print("Part '\(file.name)' has no geometry")
                continue
            }
            // STL carries no material/color info — give it a default so
            // applyColor() and the candidate-highlight always have a
            // material to work with.
            if node.geometry?.materials.isEmpty ?? true {
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.lightGray
                node.geometry?.materials = [material]
            }
            node.name = file.name
            wrapperNode.addChildNode(node)
            loadedAny = true
        }

        guard loadedAny else { return false }
        objectNode.addChildNode(wrapperNode)

        let modelSpan = fitAndCenter(wrapperNode)
        discoverParts(in: wrapperNode, modelSpan: modelSpan)
        return true
    }

    // Fits `wrapperNode`'s combined bounding box to a standard on-screen
    // size and centers its pivot. Returns the model's own pre-scale span,
    // which explode offsets are computed relative to (see discoverParts) —
    // imported files vary wildly in native units, so a fixed offset can't
    // work across all of them.
    @discardableResult
    private func fitAndCenter(_ wrapperNode: SCNNode) -> Float {
        var minVec = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxVec = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        var hasValidGeometry = false

        wrapperNode.enumerateChildNodes { (node, _) in
            let (bMin, bMax) = node.boundingBox
            if bMin.x < bMax.x && bMin.y < bMax.y && bMin.z < bMax.z {
                hasValidGeometry = true
                minVec.x = min(minVec.x, node.convertPosition(bMin, to: wrapperNode).x)
                minVec.y = min(minVec.y, node.convertPosition(bMin, to: wrapperNode).y)
                minVec.z = min(minVec.z, node.convertPosition(bMin, to: wrapperNode).z)
                maxVec.x = max(maxVec.x, node.convertPosition(bMax, to: wrapperNode).x)
                maxVec.y = max(maxVec.y, node.convertPosition(bMax, to: wrapperNode).y)
                maxVec.z = max(maxVec.z, node.convertPosition(bMax, to: wrapperNode).z)
            }
        }

        guard hasValidGeometry else { return 1.0 }

        let size = SCNVector3(maxVec.x - minVec.x, maxVec.y - minVec.y, maxVec.z - minVec.z)
        let maxDimension = max(size.x, max(size.y, size.z))

        let scaleFactor = maxDimension > 0 ? Float(1.8 / Double(maxDimension)) : 1.0
        wrapperNode.scale = SCNVector3(scaleFactor, scaleFactor, scaleFactor)
        wrapperNode.pivot = SCNMatrix4MakeTranslation(
            minVec.x + size.x / 2.0,
            minVec.y + size.y / 2.0,
            minVec.z + size.z / 2.0
        )
        print("Fit model to view. Scaled by factor: \(scaleFactor)")
        return maxDimension
    }

    func resetToDefaultTorus() {
        objectNode.childNodes.forEach { $0.removeFromParentNode() }
        objectNode.geometry = SCNTorus(ringRadius: 1.0, pipeRadius: 0.35)
        objectNode.geometry?.firstMaterial?.lightingModel = .physicallyBased
        baseScale = 1.0
        parts.removeAll()
        isExploded = false
        selectedPart = nil
        candidatePart = nil
        gesturePositionOffset = SCNVector3(0, 0, 0)
    }

    // Walks every descendant of `root` and treats each node that carries its
    // own geometry as one "part." Records both its original local position
    // (to animate back to on collapse) and an outward-exploded position
    // (original + a direction from the model's center through that part,
    // converted into the part's own parent space so rotation in the
    // hierarchy above it doesn't skew the direction).
    private func discoverParts(in root: SCNNode, modelSpan: Float) {
        var geometryNodes: [SCNNode] = []
        root.enumerateHierarchy { node, _ in
            if node.geometry != nil { geometryNodes.append(node) }
        }
        guard !geometryNodes.isEmpty else { return }

        // Parts of a model commonly share one exported material (this heart
        // file's 41 pieces all reference the same "defaultMat," for example),
        // meaning they can share the literal same SCNMaterial object. Without
        // giving each part its own copy, highlighting or recoloring "one"
        // part would visibly affect every part that shares it.
        for node in geometryNodes {
            node.geometry?.materials = node.geometry?.materials.map { $0.copy() as! SCNMaterial } ?? []
        }

        var center = SCNVector3(0, 0, 0)
        let positions = geometryNodes.map { $0.convertPosition(SCNVector3(0, 0, 0), to: root) }
        for p in positions {
            center.x += p.x
            center.y += p.y
            center.z += p.z
        }
        let count = Float(geometryNodes.count)
        center = SCNVector3(center.x / count, center.y / count, center.z / count)

        let explodeDistance: Float = max(modelSpan * 0.5, 0.01)
        var discovered: [Part] = []
        for (node, posInRoot) in zip(geometryNodes, positions) {
            var direction = SCNVector3(posInRoot.x - center.x, posInRoot.y - center.y, posInRoot.z - center.z)
            let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
            if length > 0.0001 {
                direction = SCNVector3(direction.x / length, direction.y / length, direction.z / length)
            } else {
                // Sits exactly at the center — pick an arbitrary outward direction
                // so it still moves somewhere on explode instead of staying put.
                direction = SCNVector3(1, 0, 0)
            }
            let directionInParentSpace = node.parent?.convertVector(direction, from: root) ?? direction
            let originalPosition = node.position
            let explodedPosition = SCNVector3(
                originalPosition.x + directionInParentSpace.x * explodeDistance,
                originalPosition.y + directionInParentSpace.y * explodeDistance,
                originalPosition.z + directionInParentSpace.z * explodeDistance
            )
            discovered.append(Part(
                node: node,
                originalPosition: originalPosition,
                explodedPosition: explodedPosition,
                originalScale: node.scale,
                originalEulerAngles: node.eulerAngles
            ))
        }
        parts = discovered
    }

    // A shatter, not a float-apart: each part bursts outward on a quick
    // ease-out curve, tumbling (a relative rotation, so it doesn't matter
    // what the exact end orientation is) rather than gliding, with a small
    // random per-part delay so they don't all move in perfect lockstep.
    func explodeParts() {
        guard !parts.isEmpty, !isExploded else { return }
        isExploded = true
        for part in parts {
            part.node.removeAllActions()
            let move = SCNAction.move(to: part.explodedPosition, duration: 0.45)
            move.timingMode = .easeOut
            let tumble = SCNAction.rotateBy(
                x: CGFloat.random(in: -0.9...0.9),
                y: CGFloat.random(in: -0.9...0.9),
                z: CGFloat.random(in: -0.9...0.9),
                duration: 0.45
            )
            tumble.timingMode = .easeOut
            let burst = SCNAction.group([move, tumble])
            let delay = SCNAction.wait(duration: Double.random(in: 0...0.08))
            part.node.runAction(.sequence([delay, burst]))
        }
    }

    // Reassembly is deliberately smoother/slower than the shatter — pieces
    // being pulled precisely back together, not another burst — and uses
    // SCNTransaction (not SCNAction) because it can animate eulerAngles to
    // an exact absolute value, undoing the tumble's relative rotation
    // precisely rather than approximately.
    func collapseParts() {
        guard !parts.isEmpty, isExploded else { return }
        isExploded = false
        setHighlighted(candidatePart, false)
        candidatePart = nil
        selectedPart = nil
        for part in parts {
            part.node.removeAllActions() // stop any still-running shatter tumble first
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        for part in parts {
            part.node.position = part.originalPosition
            part.node.scale = part.originalScale
            part.node.eulerAngles = part.originalEulerAngles
        }
        SCNTransaction.commit()
    }

    // `fraction` is 0...1 across the parts array — driven by the "point"
    // gesture's horizontal fingertip position. Highlights the part under it
    // by nudging its scale up so it visibly "pops," giving feedback before
    // confirming with a pinch. Deliberately NOT a material/emission change:
    // update() recolors the whole model via applyColor() on every gesture
    // tick when nothing's selected yet, which would immediately erase a
    // material-based highlight — scale is never touched by applyColor().
    func setCandidatePart(atFraction fraction: Double) {
        guard !parts.isEmpty, isExploded else { return }
        let index = min(parts.count - 1, max(0, Int(fraction * Double(parts.count))))
        let node = parts[index].node
        guard node !== candidatePart else { return }
        if candidatePart !== selectedPart {
            setHighlighted(candidatePart, false)
        }
        candidatePart = node
        if node !== selectedPart {
            setHighlighted(node, true)
        }
    }

    // Confirms whatever "point" is currently highlighting. From here on,
    // update()'s puck telemetry (rotate/zoom/color) drives this part alone
    // instead of the whole model.
    func confirmSelection() {
        guard let candidate = candidatePart else { return }
        setHighlighted(candidate, false)
        selectedPart = candidate
        candidatePart = nil
    }

    // Renames whichever part is currently selected, or candidate if nothing
    // is confirmed yet — lets a part whose source file/mesh name wasn't
    // granular enough (a single "Ventricle" STL covering both chambers, say)
    // get a more specific name assigned by hand. Returns false if nothing
    // is currently targeted to rename.
    @discardableResult
    func labelActivePart(_ name: String) -> Bool {
        guard let target = selectedPart ?? candidatePart else { return false }
        target.name = name
        return true
    }

    private func setHighlighted(_ node: SCNNode?, _ highlighted: Bool) {
        guard let node = node else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15
        let scale: Float = highlighted ? 1.15 : 1.0
        node.scale = SCNVector3(scale, scale, scale)
        SCNTransaction.commit()
    }
 
    func update(pitchDeg: Double, rollDeg: Double, distCM: Double, color: UIColor) {
        let clamped = max(3.0, min(20.0, distCM))
        let t = (clamped - 3.0) / (20.0 - 3.0)
        let distScale = Float(0.4 + t * (2.5 - 0.4))

        // A selected part takes over the puck's rotate/zoom/color entirely —
        // the whole model stays put (however it looked when exploded) while
        // just that one part responds.
        if let target = selectedPart {
            // A single small part fills much more of the screen once
            // selected/zoomed than the whole model normally does, so the
            // same raw sensor noise that's barely visible at normal scale
            // becomes an obvious twitch here — smooth the transition
            // instead of snapping straight to each new reading.
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.08
            target.eulerAngles = SCNVector3(
                Float(pitchDeg * .pi / 180.0),
                target.eulerAngles.y,
                Float(rollDeg * .pi / 180.0)
            )
            target.scale = SCNVector3(distScale, distScale, distScale)
            SCNTransaction.commit()
            applyColor(color, to: target)
            return
        }

        objectNode.eulerAngles = SCNVector3(
            Float(pitchDeg * .pi / 180.0),
            Float(gestureYawDegrees * .pi / 180.0),
            Float(rollDeg * .pi / 180.0)
        )
        objectNode.position = gesturePositionOffset

        let finalScale = baseScale * (gestureScaleOverride ?? distScale)
        objectNode.scale = SCNVector3(finalScale, finalScale, finalScale)

        applyColor(color, to: objectNode)
    }
 
    private func applyColor(_ color: UIColor, to node: SCNNode) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                material.lightingModel = .constant
                material.diffuse.contents = color
                material.normal.contents = nil
                material.specular.contents = nil
                material.emission.contents = nil
                material.metalness.contents = nil
                material.roughness.contents = nil
            }
        }
        for child in node.childNodes {
            applyColor(color, to: child)
        }
    }
}
 
