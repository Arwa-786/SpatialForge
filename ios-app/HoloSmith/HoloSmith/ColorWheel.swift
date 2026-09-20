//
//  ColorWheel.swift
//  HoloSmith
//
//  Created by Arwa Arshad Ali on 9/19/26.
//
//  SpatialForge — the HSB color wheel view, its image generator, and
//  the closest-named-color helper used under the wheel.
//
 
import SwiftUI
 
let namedColors: [(name: String, r: Double, g: Double, b: Double)] = [
    ("Red", 220, 40, 40), ("Orange", 235, 130, 30), ("Yellow", 235, 215, 40),
    ("Green", 45, 165, 75), ("Teal", 30, 170, 170), ("Blue", 40, 100, 220),
    ("Purple", 140, 60, 200), ("Pink", 230, 110, 170), ("Brown", 120, 75, 45),
    ("White", 235, 235, 230), ("Gray", 130, 130, 130), ("Black", 25, 25, 25)
]
 
func nearestColorName(r: Int, g: Int, b: Int) -> String {
    namedColors.min(by: { lhs, rhs in
        let dl = pow(lhs.r - Double(r), 2) + pow(lhs.g - Double(g), 2) + pow(lhs.b - Double(b), 2)
        let dr = pow(rhs.r - Double(r), 2) + pow(rhs.g - Double(g), 2) + pow(rhs.b - Double(b), 2)
        return dl < dr
    })?.name ?? "—"
}
 
enum ColorWheelRenderer {
    static func makeWheel(diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let radius = diameter / 2
            let cg = ctx.cgContext
            for y in stride(from: 0, to: Int(diameter), by: 1) {
                for x in stride(from: 0, to: Int(diameter), by: 1) {
                    let dx = CGFloat(x) - radius
                    let dy = CGFloat(y) - radius
                    let dist = sqrt(dx * dx + dy * dy)
                    guard dist <= radius else { continue }
                    let angle = atan2(dy, dx)
                    let hue = (angle + .pi) / (2 * .pi)
                    let sat = dist / radius
                    let color = UIColor(hue: hue, saturation: sat, brightness: 1, alpha: 1)
                    cg.setFillColor(color.cgColor)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}
 
func wheelPosition(r: Int, g: Int, b: Int, diameter: CGFloat) -> CGPoint {
    var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
    UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
 
    let radius = diameter / 2
    let angle = hue * 2 * .pi - .pi
    let dist = sat * radius
    let x = radius + dist * cos(angle)
    let y = radius + dist * sin(angle)
    return CGPoint(x: x, y: y)
}
 
struct ColorWheelView: View {
    let rawR: Int
    let rawG: Int
    let rawB: Int
 
    private let diameter: CGFloat = 100
    private static var cachedWheel: UIImage?
 
    private var wheelImage: UIImage {
        if let cached = Self.cachedWheel { return cached }
        let img = ColorWheelRenderer.makeWheel(diameter: diameter)
        Self.cachedWheel = img
        return img
    }
 
    var body: some View {
        let point = wheelPosition(r: rawR, g: rawG, b: rawB, diameter: diameter)
        let name = nearestColorName(r: rawR, g: rawG, b: rawB)
        let hex = String(format: "#%02X%02X%02X", rawR, rawG, rawB)
 
        VStack(spacing: 10) {
            ZStack {
                Image(uiImage: wheelImage)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
 
                // Dark + light halo keeps the marker visible against any part of the
                // wheel (including near-white, low-saturation areas near the center),
                // and the inner dot shows the actual sensed color, not just its position.
                ZStack {
                    Circle().fill(Color.black.opacity(0.55)).frame(width: 16, height: 16)
                    Circle().fill(Color.white).frame(width: 13, height: 13)
                    Circle().fill(Color(red: Double(rawR) / 255, green: Double(rawG) / 255, blue: Double(rawB) / 255))
                        .frame(width: 9, height: 9)
                }
                .shadow(radius: 2)
                .position(x: point.x, y: point.y)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: point.x)
            }
            .frame(width: diameter, height: diameter)
 
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: Double(rawR) / 255, green: Double(rawG) / 255, blue: Double(rawB) / 255))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                Text("\(name)  \(hex)")
                    .font(.caption.monospaced())
                    .foregroundColor(.white)
            }
        }
        .padding(14)
        .background(.black.opacity(0.55))
        .cornerRadius(20)
    }
}
 
