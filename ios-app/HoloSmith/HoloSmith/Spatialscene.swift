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
 
    @discardableResult
    func loadModel(from url: URL) -> Bool {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
 
        guard let imported = try? SCNScene(url: url, options: [.checkConsistency: true]) else {
            return false
        }
 
        objectNode.geometry = nil
        objectNode.childNodes.forEach { $0.removeFromParentNode() }
 
        for child in imported.rootNode.childNodes {
            objectNode.addChildNode(child)
        }
 
        let (minB, maxB) = objectNode.boundingBox
        let size = SCNVector3(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
        let maxDimension = max(size.x, max(size.y, size.z))
        baseScale = maxDimension > 0 ? (2.5 / maxDimension) : 1.0
 
        return true
    }
 
    func resetToDefaultTorus() {
        objectNode.childNodes.forEach { $0.removeFromParentNode() }
        objectNode.geometry = SCNTorus(ringRadius: 1.0, pipeRadius: 0.35)
        objectNode.geometry?.firstMaterial?.lightingModel = .physicallyBased
        baseScale = 1.0
    }
 
    func update(pitchDeg: Double, rollDeg: Double, distCM: Double, color: UIColor) {
        objectNode.eulerAngles = SCNVector3(
            Float(pitchDeg * .pi / 180.0),
            0,
            Float(rollDeg * .pi / 180.0)
        )
 
        let clamped = max(3.0, min(20.0, distCM))
        let t = (clamped - 3.0) / (20.0 - 3.0)
        let distScale = Float(0.4 + t * (2.5 - 0.4))
        let finalScale = baseScale * distScale
        objectNode.scale = SCNVector3(finalScale, finalScale, finalScale)
 
        applyColor(color, to: objectNode)
    }
 
    private func applyColor(_ color: UIColor, to node: SCNNode) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                material.diffuse.contents = color
            }
        }
        for child in node.childNodes {
            applyColor(color, to: child)
        }
    }
}
 
