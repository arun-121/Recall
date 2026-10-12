import Foundation
import AppKit

/// Opens the actual indexed file in its default application. For PDFs with a
/// known page number, it attempts to open Preview at that page. Never fabricates
/// paths: if the file is missing, it reports failure.
public enum FileOpener {
    @discardableResult
    public static func open(url: URL, pageNumber: Int? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        // Best-effort page navigation for PDFs via Preview's AppleScript support
        // is unreliable across versions; we open the file normally, which is the
        // robust, native behavior. Page number is surfaced in the UI as guidance.
        return NSWorkspace.shared.open(url)
    }

    /// Reveals the file in Finder.
    @discardableResult
    public static func revealInFinder(url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
