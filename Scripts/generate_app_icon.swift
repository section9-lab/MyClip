import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputRoot = root.appendingPathComponent("MyClip/Assets.xcassets")
let appIconSet = outputRoot.appendingPathComponent("AppIcon.appiconset")
let iconset = root.appendingPathComponent("build/MyClip.iconset")
let sources = root.appendingPathComponent("MyClip/Supporting/IconSources")
let iconComposerDocument = root.appendingPathComponent("MyClip/Supporting/AppIcon.icon")

try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconComposerDocument, withIntermediateDirectories: true)

func image(pixels: Int, actions: (NSRect) -> Void) -> NSImage {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap context")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    actions(NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

func savePNG(_ img: NSImage, to url: URL) throws {
    guard
        let tiff = img.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let data = rep.representation(using: .png, properties: [:])
    else {
        fatalError("Could not encode \(url.lastPathComponent)")
    }
    try data.write(to: url)
}

let master = image(pixels: 1024) { rect in
    NSColor.clear.setFill()
    rect.fill()

    let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 54, dy: 54), xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedWhite: 0.86, alpha: 1).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let clip = NSBezierPath()
    clip.move(to: NSPoint(x: 356, y: 655))
    clip.line(to: NSPoint(x: 356, y: 378))
    clip.curve(to: NSPoint(x: 512, y: 222), controlPoint1: NSPoint(x: 356, y: 292), controlPoint2: NSPoint(x: 426, y: 222))
    clip.curve(to: NSPoint(x: 668, y: 378), controlPoint1: NSPoint(x: 598, y: 222), controlPoint2: NSPoint(x: 668, y: 292))
    clip.line(to: NSPoint(x: 668, y: 666))
    clip.curve(to: NSPoint(x: 550, y: 784), controlPoint1: NSPoint(x: 668, y: 731), controlPoint2: NSPoint(x: 615, y: 784))
    clip.curve(to: NSPoint(x: 432, y: 666), controlPoint1: NSPoint(x: 485, y: 784), controlPoint2: NSPoint(x: 432, y: 731))
    clip.line(to: NSPoint(x: 432, y: 386))
    clip.curve(to: NSPoint(x: 512, y: 306), controlPoint1: NSPoint(x: 432, y: 342), controlPoint2: NSPoint(x: 468, y: 306))
    clip.curve(to: NSPoint(x: 592, y: 386), controlPoint1: NSPoint(x: 556, y: 306), controlPoint2: NSPoint(x: 592, y: 342))
    clip.line(to: NSPoint(x: 592, y: 614))
    var orientation = AffineTransform(translationByX: 512, byY: 512)
    orientation.rotate(byDegrees: -35)
    orientation.translate(x: -512, y: -503)
    clip.transform(using: orientation)
    clip.lineWidth = 52
    clip.lineCapStyle = .round
    clip.lineJoinStyle = .round
    NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 1).setStroke()
    clip.stroke()
}

let masterPNG = sources.appendingPathComponent("MyClipIcon-1024.png")
try savePNG(master, to: masterPNG)
try savePNG(master, to: iconComposerDocument.appendingPathComponent("MyClipIcon-1024.png"))

let slots: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, pixels) in slots {
    let resized = image(pixels: pixels) { rect in
        master.draw(in: rect, from: NSRect(x: 0, y: 0, width: 1024, height: 1024), operation: .sourceOver, fraction: 1.0)
    }
    try savePNG(resized, to: appIconSet.appendingPathComponent(name))
    try savePNG(resized, to: iconset.appendingPathComponent(name))
}

let documentationImages = root.appendingPathComponent("docs/images")
try FileManager.default.createDirectory(at: documentationImages, withIntermediateDirectories: true)
try savePNG(image(pixels: 256) { master.draw(in: $0) }, to: documentationImages.appendingPathComponent("myclip-icon.png"))

let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

try contents.write(to: appIconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try """
{
  "fill" : "system-light",
  "groups" : [
    {
      "layers" : [
        {
          "hidden" : false,
          "image-name" : "MyClipIcon-1024.png",
          "name" : "MyClipIcon",
          "position" : {
            "scale" : 1,
            "translation-in-points" : [
              0,
              0
            ]
          }
        }
      ],
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "supported-platforms" : {
    "circles" : [
      "watchOS"
    ],
    "squares" : "shared"
  }
}
""".write(to: iconComposerDocument.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

try """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""".write(to: outputRoot.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
