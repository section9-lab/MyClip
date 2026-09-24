import Foundation

public struct CaptureContext: Sendable {
    public var id: UUID
    public var appName: String
    public var bundleID: String
    public var windowTitle: String
    public var windowID: UInt32
    public var reason: CaptureReason
    public var date: Date

    public init(id: UUID = UUID(), appName: String, bundleID: String, windowTitle: String, windowID: UInt32, reason: CaptureReason, date: Date = Date()) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.reason = reason
        self.date = date
    }
}

public struct ClipCapture: Identifiable, Sendable {
    public let id: UUID
    public let appName: String
    public let bundleID: String
    public let windowTitle: String
    public let windowID: UInt32
    public let reason: CaptureReason
    public let date: Date
    public let imageID: String
    public let imageURL: URL
    public let width: Int
    public let height: Int
    /// Consecutive captures of one window within `LibraryStore.sceneGap` share a scene; the Timeline folds them.
    public var sceneID: String
    public var textURL: URL { imageURL.deletingPathExtension().appendingPathExtension("txt") }

    public init(id: UUID, appName: String, bundleID: String, windowTitle: String, windowID: UInt32, reason: CaptureReason, date: Date,
                imageID: String, imageURL: URL, width: Int, height: Int, sceneID: String? = nil) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.reason = reason
        self.date = date
        self.imageID = imageID
        self.imageURL = imageURL
        self.width = width
        self.height = height
        self.sceneID = sceneID ?? id.uuidString
    }
}
