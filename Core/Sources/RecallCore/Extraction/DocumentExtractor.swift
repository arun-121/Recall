import Foundation
import PDFKit

/// The result of extracting a document: ordered text segments plus a content hash.
public struct ExtractedDocument: Sendable {
    public var segments: [TextSegment]
    public var contentHash: String

    public init(segments: [TextSegment], contentHash: String) {
        self.segments = segments
        self.contentHash = contentHash
    }
}

/// Extracts plain text and page metadata from a document.
///
/// Implementations are intentionally pure with respect to the filesystem input
/// so they can be swapped and tested. Each extractor handles one `FileType`.
public protocol DocumentExtractor: Sendable {
    /// The file types this extractor can handle.
    var supportedTypes: Set<FileType> { get }
    /// Extracts text segments and a content hash from the file at `url`.
    func extract(from url: URL, fileType: FileType) throws -> ExtractedDocument
}

/// Extracts selectable text from text-based PDFs, one segment per page so that
/// page numbers are preserved. Scanned/image PDFs produce no text; this is
/// reported explicitly because OCR is not supported in this version.
public struct PDFDocumentExtractor: DocumentExtractor {
    public let supportedTypes: Set<FileType> = [.pdf]

    public init() {}

    public func extract(from url: URL, fileType: FileType) throws -> ExtractedDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw ExtractionError.unreadableFile(url.path)
        }
        if pdf.isEncrypted && pdf.isLocked {
            throw ExtractionError.encrypted(url.path)
        }

        var segments: [TextSegment] = []
        var combined = ""
        let pageCount = pdf.pageCount
        for pageIndex in 0..<pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Page numbers are 1-based for display.
            if !trimmed.isEmpty {
                segments.append(TextSegment(text: pageText, pageNumber: pageIndex + 1))
                combined += pageText
            }
        }

        if segments.isEmpty {
            // No selectable text anywhere: almost certainly a scanned PDF.
            throw ExtractionError.noExtractableText(url.path)
        }

        return ExtractedDocument(segments: segments, contentHash: ContentHasher.hash(combined))
    }
}

/// Extracts text from Markdown. Markdown is treated as plain text for search
/// purposes (formatting markers are retained since they rarely hurt retrieval),
/// but we strip the most common structural noise to improve snippet quality.
public struct MarkdownDocumentExtractor: DocumentExtractor {
    public let supportedTypes: Set<FileType> = [.markdown]

    public init() {}

    public func extract(from url: URL, fileType: FileType) throws -> ExtractedDocument {
        let raw = try readText(at: url)
        let cleaned = MarkdownDocumentExtractor.stripFormatting(raw)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.noExtractableText(url.path)
        }
        // Markdown has no intrinsic pages.
        let segment = TextSegment(text: cleaned, pageNumber: nil)
        return ExtractedDocument(segments: [segment], contentHash: ContentHasher.hash(raw))
    }

    /// Removes code fences, heading markers, emphasis markers and link syntax
    /// while keeping the human-readable text.
    static func stripFormatting(_ text: String) -> String {
        var lines: [String] = []
        var inFence = false
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { lines.append(line); continue }
            // Strip leading heading hashes and blockquote markers.
            while line.hasPrefix("#") || line.hasPrefix(">") {
                line.removeFirst()
            }
            lines.append(line)
        }
        var joined = lines.joined(separator: "\n")
        // Convert [text](url) -> text
        joined = joined.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // Remove emphasis/inline-code characters.
        joined = joined.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        return joined
    }
}

/// Extracts text from plain `.txt` files.
public struct PlainTextDocumentExtractor: DocumentExtractor {
    public let supportedTypes: Set<FileType> = [.text]

    public init() {}

    public func extract(from url: URL, fileType: FileType) throws -> ExtractedDocument {
        let raw = try readText(at: url)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.noExtractableText(url.path)
        }
        return ExtractedDocument(
            segments: [TextSegment(text: raw, pageNumber: nil)],
            contentHash: ContentHasher.hash(raw)
        )
    }
}

/// Routes a file to the appropriate extractor based on its `FileType`.
public struct DocumentExtractorRegistry: Sendable {
    private let extractors: [DocumentExtractor]

    public init(extractors: [DocumentExtractor] = [
        PDFDocumentExtractor(),
        MarkdownDocumentExtractor(),
        PlainTextDocumentExtractor()
    ]) {
        self.extractors = extractors
    }

    public func extractor(for type: FileType) -> DocumentExtractor? {
        extractors.first { $0.supportedTypes.contains(type) }
    }

    public func extract(from url: URL, fileType: FileType) throws -> ExtractedDocument {
        guard let extractor = extractor(for: fileType) else {
            throw ExtractionError.unsupportedType(fileType.rawValue)
        }
        return try extractor.extract(from: url, fileType: fileType)
    }
}

/// Reads a text file trying UTF-8 first, then falling back to Latin-1 so that
/// legacy-encoded files do not fail hard.
private func readText(at url: URL) throws -> String {
    if let s = try? String(contentsOf: url, encoding: .utf8) {
        return s
    }
    if let s = try? String(contentsOf: url, encoding: .isoLatin1) {
        return s
    }
    throw ExtractionError.unreadableFile(url.path)
}
