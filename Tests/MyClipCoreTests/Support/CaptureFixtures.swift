import XCTest
import CoreGraphics
@testable import MyClipCore

func fixtureImage(changed: Bool = false, x: Int = 4) throws -> CapturedImage {
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    if changed {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: x, y: 4, width: 1, height: 1))
    }
    return try CapturedImage(image: XCTUnwrap(context.makeImage()))
}

func fixtureContext(at time: TimeInterval = 100, windowID: UInt32 = 1) -> CaptureContext {
    CaptureContext(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "窗口采集规则", windowID: windowID, reason: .pointerIdle, date: Date(timeIntervalSince1970: time))
}
