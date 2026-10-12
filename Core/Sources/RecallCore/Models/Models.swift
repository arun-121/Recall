import Foundation

/// A supported document type. The raw value is persisted in the `file_type` column.
public enum FileType: String, Codable, Sendable, CaseIterable {
    case pdf
    case markdown
    case text

    /// Maps a file extension (without the dot, case-insensitive) to a `FileType`.
    public static func from(pathExtension ext: String) -> FileType? {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "txt", "text": return .text
        default: return nil
        }
    }

    /// A short, user-facing label.
    public var displayLabel: String {
        switch self {
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        case .text: return "Text"
        }
    }
}

/// Lifecycle status of a document in the index.
public enum IndexStatus: String, Codable, Sendable {
    /// Discovered but not yet processed.
    case pending
    /// Currently being extracted/embedded.
    case indexing
    /// Fully indexed and searchable.
    case indexed
    /// Extraction or embedding failed.
    case failed
}

/// Persisted document metadata. The absolute path is stored exactly once here;
/// chunks reference the document via `documentID` rather than duplicating paths.
public struct Document: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var path: String
    public var filename: String
    public var fileType: FileType
    public var modifiedAt: Date
    public var contentHash: String
    public var indexStatus: IndexStatus
    public var lastIndexedAt: Date?
    public var errorMessage: String?

    public init(
        id: Int64 = 0,
        path: String,
        filename: String,
        fileType: FileType,
        modifiedAt: Date,
        contentHash: String,
        indexStatus: IndexStatus = .pending,
        lastIndexedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.path = path
        self.filename = filename
        self.fileType = fileType
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.indexStatus = indexStatus
        self.lastIndexedAt = lastIndexedAt
        self.errorMessage = errorMessage
    }
}

/// A chunk of extracted text belonging to a document, plus its embedding vector.
public struct Chunk: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var documentID: Int64
    public var chunkIndex: Int
    public var text: String
    public var pageNumber: Int?
    public var embeddingModel: String
    public var embedding: [Float]

    public init(
        id: Int64 = 0,
        documentID: Int64,
        chunkIndex: Int,
        text: String,
        pageNumber: Int? = nil,
        embeddingModel: String,
        embedding: [Float]
    ) {
        self.id = id
        self.documentID = documentID
        self.chunkIndex = chunkIndex
        self.text = text
        self.pageNumber = pageNumber
        self.embeddingModel = embeddingModel
        self.embedding = embedding
    }
}

/// A chunk candidate carrying a raw similarity/relevance score, used during ranking.
public struct ScoredChunk: Sendable {
    public var chunkID: Int64
    public var documentID: Int64
    public var chunkIndex: Int
    public var text: String
    public var pageNumber: Int?
    public var score: Double

    public init(
        chunkID: Int64,
        documentID: Int64,
        chunkIndex: Int,
        text: String,
        pageNumber: Int?,
        score: Double
    ) {
        self.chunkID = chunkID
        self.documentID = documentID
        self.chunkIndex = chunkIndex
        self.text = text
        self.pageNumber = pageNumber
        self.score = score
    }
}

/// A document-level search result returned to the UI.
public struct SearchResult: Identifiable, Equatable, Sendable {
    public var id: Int64 { documentID }
    public var documentID: Int64
    public var filename: String
    public var fileURL: URL
    public var fileType: FileType
    public var snippet: String
    public var pageNumber: Int?
    /// Fused ranking score for internal use (higher is better).
    public var score: Double

    public init(
        documentID: Int64,
        filename: String,
        fileURL: URL,
        fileType: FileType,
        snippet: String,
        pageNumber: Int?,
        score: Double
    ) {
        self.documentID = documentID
        self.filename = filename
        self.fileURL = fileURL
        self.fileType = fileType
        self.snippet = snippet
        self.pageNumber = pageNumber
        self.score = score
    }
}
