import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Author simple vector layers. Icon Composer supplies the glass, lighting and mask.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = root.appendingPathComponent("Percuscore/Resources")
let icon = resources.appendingPathComponent("AppIcon.icon")
let assets = icon.appendingPathComponent("Assets")
let fallback = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
for directory in [assets, fallback] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\(body)</svg>"
}
let rear = "<rect x=\"190\" y=\"223\" width=\"557\" height=\"616\" rx=\"52\" fill=\"white\" transform=\"rotate(-9 468.5 531)\"/>"
let paper = "<rect x=\"256\" y=\"160\" width=\"576\" height=\"704\" rx=\"56\" fill=\"white\"/>"
let staff = (0..<5).map { "<rect x=\"320\" y=\"\(397 + $0 * 48)\" width=\"448\" height=\"9\" rx=\"4.5\" fill=\"#EDB6BE\"/>" }.joined()
let note = "<ellipse cx=\"477\" cy=\"575\" rx=\"76\" ry=\"51\" fill=\"#DF193B\" transform=\"rotate(-18 477 575)\"/><rect x=\"529\" y=\"306\" width=\"28\" height=\"268\" rx=\"14\" fill=\"#DF193B\"/>"
let caption = "<rect x=\"320\" y=\"738\" width=\"190\" height=\"14\" rx=\"7\" fill=\"#EDB6BE\"/>"
for (name, body) in [("Back score.svg", rear), ("Score paper.svg", paper), ("Notation.svg", staff + note + caption)] {
    try svg(body).write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
var document: [String: Any] = [
    "fill-specializations": [
        ["value": ["linear-gradient": ["srgb:1.00000,0.25490,0.37647,1.00000", "srgb:0.85882,0.06275,0.20392,1.00000"]]],
        ["appearance": "dark", "value": ["linear-gradient": ["srgb:0.36078,0.03529,0.11373,1.00000", "srgb:0.12549,0.01961,0.04314,1.00000"]]]
    ],
    "groups": [
        ["name": "Library depth", "layers": [["image-name": "Back score.svg", "name": "Back score", "glass": true, "fill": "automatic"]],
         "lighting": "individual", "shadow": ["kind": "neutral", "opacity": 0.3], "translucency": ["enabled": true, "value": 0.65]],
        ["name": "Score", "layers": [["image-name": "Score paper.svg", "name": "Score paper", "glass": true, "fill": "automatic"]],
         "lighting": "individual", "shadow": ["kind": "neutral", "opacity": 0.35], "translucency": ["enabled": true, "value": 0.12]],
        ["name": "Music", "layers": [["image-name": "Notation.svg", "name": "Notation", "glass": false, "fill": "automatic"]],
         "lighting": "individual", "shadow": ["kind": "neutral", "opacity": 0.0], "translucency": ["enabled": false, "value": 0.0]]
    ],
    "supported-platforms": ["squares": "shared"]
]
// Icon Composer stores foreground groups first.
document["groups"] = Array((document["groups"] as! [[String: Any]]).reversed())
try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: icon.appendingPathComponent("icon.json"))

// Opaque legacy artwork for older toolchains / systems, using the same geometry.
let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 1, green: 0.255, blue: 0.376, alpha: 1),
    CGColor(red: 0.859, green: 0.063, blue: 0.204, alpha: 1)
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1024, y: 1024), options: [])
func rounded(_ rect: CGRect, radius: CGFloat, color: CGColor) {
    cg.setFillColor(color)
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); cg.fillPath()
}
cg.saveGState(); cg.translateBy(x: 468.5, y: 531); cg.rotate(by: -9 * .pi / 180); cg.translateBy(x: -468.5, y: -531)
rounded(CGRect(x: 190, y: 223, width: 557, height: 616), radius: 52, color: CGColor(red: 1, green: 0.72, blue: 0.78, alpha: 1))
cg.restoreGState()
rounded(CGRect(x: 256, y: 160, width: 576, height: 704), radius: 56, color: CGColor(red: 1, green: 0.98, blue: 0.99, alpha: 1))
let pale = CGColor(red: 0.929, green: 0.714, blue: 0.745, alpha: 1)
for i in 0..<5 { rounded(CGRect(x: 320, y: 397 + i * 48, width: 448, height: 9), radius: 4.5, color: pale) }
let red = CGColor(red: 0.875, green: 0.098, blue: 0.231, alpha: 1)
cg.saveGState(); cg.translateBy(x: 477, y: 575); cg.rotate(by: -18 * .pi / 180)
cg.setFillColor(red); cg.fillEllipse(in: CGRect(x: -76, y: -51, width: 152, height: 102)); cg.restoreGState()
rounded(CGRect(x: 529, y: 306, width: 28, height: 268), radius: 14, color: red)
rounded(CGRect(x: 320, y: 738, width: 190, height: 14), radius: 7, color: pale)
let destination = CGImageDestinationCreateWithURL(fallback.appendingPathComponent("AppIcon.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
try """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
""".write(to: fallback.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Generated layered AppIcon.icon and matching opaque 1024 × 1024 fallback")
