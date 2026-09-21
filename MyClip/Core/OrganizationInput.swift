import Foundation

public struct OrganizationInput: Sendable {
    public let capture: ClipCapture
    public let text: String?
    public var usesImage: Bool { text == nil }

    public init(capture: ClipCapture, text: String? = nil) {
        self.capture = capture
        self.text = text
    }
}

extension CaptureReason {
    var prefersText: Bool {
        switch self {
        case .pointerIdle, .clickIdle, .clickAfterIdle, .scrollIdle: true
        case .enter, .manual: false
        }
    }
}

extension LibraryStore {
    func organizationInput(_ capture: ClipCapture) throws -> OrganizationInput {
        let text = try capture.reason.prefersText
            ? database.run("SELECT body FROM image_text WHERE image_id=?", [capture.imageID]).first?["body"] : nil
        // An empty or oversized OCR result falls back to the original image without losing content.
        let usable = text.flatMap { value in
            value.count <= OrganizationQueue.textCharacterLimit && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? value : nil
        }
        return OrganizationInput(capture: capture, text: usable)
    }

    func freezeOrganizationInputs(_ inputs: [OrganizationInput], jobID: UUID) throws {
        for input in inputs {
            try database.run("INSERT INTO job_inputs(job_id,capture_id,ocr_text) VALUES(?,?,?)",
                [jobID.uuidString, input.capture.id.uuidString, input.text])
        }
    }

    public func organizationInputs(jobID: UUID) throws -> [OrganizationInput] {
        guard let row = try database.run("SELECT * FROM jobs WHERE id=?", [jobID.uuidString]).first else {
            throw LibraryError.invalidResult("任务不存在")
        }
        return try captures(ids: job(row).sourceIDs).map { capture in
            let frozen = try database.run("SELECT ocr_text FROM job_inputs WHERE job_id=? AND capture_id=?",
                [jobID.uuidString, capture.id.uuidString]).first
            // Jobs created by older versions and explicit reorganization retain their original image inputs.
            return OrganizationInput(capture: capture, text: frozen?["ocr_text"])
        }
    }
}
