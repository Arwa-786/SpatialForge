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

            let wrapperNode = SCNNode()
            for child in scene.rootNode.childNodes {
                wrapperNode.addChildNode(child)
            }
            objectNode.addChildNode(wrapperNode)
            
            // Compute bounding box
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
            
            if hasValidGeometry {
                let size = SCNVector3(maxVec.x - minVec.x, maxVec.y - minVec.y, maxVec.z - minVec.z)
                let maxDimension = max(size.x, max(size.y, size.z))
                
                // Set scale and center pivot
                let scaleFactor = maxDimension > 0 ? Float(1.8 / Double(maxDimension)) : 1.0
                wrapperNode.scale = SCNVector3(scaleFactor, scaleFactor, scaleFactor)
                
                wrapperNode.pivot = SCNMatrix4MakeTranslation(
                    minVec.x + size.x / 2.0,
                    minVec.y + size.y / 2.0,
                    minVec.z + size.z / 2.0
                )
                print("Successfully mounted imported model. Scaled by factor: \(scaleFactor)")
            }
            
            return true
        } catch {
            print("Import error: \(error)")
            return false
        }
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
 
