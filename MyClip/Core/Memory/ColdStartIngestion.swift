import AppKit
import Foundation
import PDFKit

/// One-time scan of ~/Desktop and ~/Documents to seed Memory with the user's existing notes on first launch.
public enum ColdStartIngestion {
    public struct ScannedFile: Sendable {
        public let label: String
        public let text: String
    }

    static let scanFolderNames = ["Desktop", "Documents"]
    static let allowedExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "pdf", "docx", "doc"]
    static let maxFiles = 40
    static let perFileCharacterLimit = 4_000
    static let totalCharacterBudget = 24_000

    public static func scan() -> [ScannedFile] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var candidates: [(url: URL, label: String, modified: Date)] = []
        for name in scanFolderNames {
            let root = home.appendingPathComponent(name)
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { continue }
                if values.isPackage == true { enumerator.skipDescendants(); continue }
                guard values.isSymbolicLink != true, values.isRegularFile == true, allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                candidates.append((url, name + "/" + url.lastPathComponent, values.contentModificationDate ?? .distantPast))
            }
        }
        candidates.sort { $0.modified > $1.modified }
        var results: [ScannedFile] = []
        var totalCharacters = 0
        for candidate in candidates {
            guard results.count < maxFiles, totalCharacters < totalCharacterBudget else { break }
            guard let text = extractText(from: candidate.url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let truncated = String(text.prefix(perFileCharacterLimit))
            results.append(ScannedFile(label: candidate.label, text: truncated))
            totalCharacters += truncated.count
        }
        return results
    }

    private static func extractText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown":
            return try? String(contentsOf: url, encoding: .utf8)
        case "pdf":
            return PDFDocument(url: url)?.string
        case "rtf":
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        case "doc":
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.docFormat], documentAttributes: nil).string
        case "docx":
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        default:
            return nil
        }
    }
}
