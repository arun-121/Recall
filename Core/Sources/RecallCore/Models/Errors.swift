import Foundation

/// Errors surfaced by the embedding provider layer.
public enum EmbeddingError: Error, LocalizedError, Equatable {
    /// The local inference runtime (e.g. Ollama) could not be reached.
    case runtimeUnavailable(String)
    /// The requested embedding model is not installed in the runtime.
    case modelNotInstalled(String)
    /// The runtime returned an unexpected or malformed response.
    case invalidResponse(String)
    /// Embedding was requested for empty input.
    case emptyInput
    /// Returned vectors had an unexpected dimensionality.
    case dimensionMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let detail):
            return "Embedding runtime unavailable: \(detail)"
        case .modelNotInstalled(let model):
            return "Embedding model '\(model)' is not installed."
        case .invalidResponse(let detail):
            return "Invalid embedding response: \(detail)"
        case .emptyInput:
            return "Cannot embed empty input."
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimension mismatch (expected \(expected), got \(got))."
        }
    }
}

/// Errors surfaced by document extraction.
public enum ExtractionError: Error, LocalizedError, Equatable {
    case unreadableFile(String)
    case unsupportedType(String)
    case encrypted(String)
    /// A PDF produced no selectable text (likely scanned; OCR not supported).
    case noExtractableText(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let p): return "Could not read file: \(p)"
        case .unsupportedType(let t): return "Unsupported file type: \(t)"
        case .encrypted(let p): return "File is encrypted: \(p)"
        case .noExtractableText(let p):
            return "No extractable text (scanned PDF? OCR is not supported): \(p)"
        }
    }
}

/// Errors surfaced by the storage layer.
public enum StorageError: Error, LocalizedError {
    case openFailed(String)
    case migrationFailed(String)
    case queryFailed(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .openFailed(let d): return "Failed to open database: \(d)"
        case .migrationFailed(let d): return "Migration failed: \(d)"
        case .queryFailed(let d): return "Query failed: \(d)"
        case .notFound: return "Record not found."
        }
    }
}
