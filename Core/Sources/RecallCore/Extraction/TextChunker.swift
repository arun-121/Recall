import Foundation

/// A unit of text produced by extraction, carrying an optional source page number.
public struct TextSegment: Equatable, Sendable {
    public var text: String
    public var pageNumber: Int?

    public init(text: String, pageNumber: Int? = nil) {
        self.text = text
        self.pageNumber = pageNumber
    }
}

/// A chunk of text ready for embedding, with provenance back to a page.
public struct TextChunk: Equatable, Sendable {
    public var text: String
    public var pageNumber: Int?

    public init(text: String, pageNumber: Int? = nil) {
        self.text = text
        self.pageNumber = pageNumber
    }
}

/// Splits extracted text into overlapping, word-bounded chunks.
///
/// Chunking is performed per-segment so that a chunk never straddles two pages,
/// which keeps page-number provenance accurate. Sizes are measured in characters;
/// splits occur on whitespace boundaries so words are never cut in half.
public struct TextChunker: Sendable {
    public let maxChunkSize: Int
    public let overlap: Int

    /// - Parameters:
    ///   - maxChunkSize: Target maximum chunk length in characters (must be > 0).
    ///   - overlap: Number of characters of trailing context repeated at the start
    ///     of the next chunk (must be >= 0 and < maxChunkSize).
    public init(maxChunkSize: Int = 1000, overlap: Int = 150) {
        precondition(maxChunkSize > 0, "maxChunkSize must be positive")
        precondition(overlap >= 0 && overlap < maxChunkSize, "overlap must be in 0..<maxChunkSize")
        self.maxChunkSize = maxChunkSize
        self.overlap = overlap
    }

    /// Chunks a list of segments, preserving each segment's page number.
    public func chunk(segments: [TextSegment]) -> [TextChunk] {
        var result: [TextChunk] = []
        for segment in segments {
            result.append(contentsOf: chunk(text: segment.text, pageNumber: segment.pageNumber))
        }
        return result
    }

    /// Chunks a single string of text with the given page number.
    public func chunk(text: String, pageNumber: Int?) -> [TextChunk] {
        let normalized = normalizeWhitespace(text)
        guard !normalized.isEmpty else { return [] }

        // Short text fits in a single chunk.
        if normalized.count <= maxChunkSize {
            return [TextChunk(text: normalized, pageNumber: pageNumber)]
        }

        let words = normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var chunks: [TextChunk] = []
        var current: [String] = []
        var currentLen = 0

        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.joined(separator: " ")
            chunks.append(TextChunk(text: joined, pageNumber: pageNumber))
        }

        var i = 0
        while i < words.count {
            let word = words[i]
            // +1 accounts for the joining space.
            let addition = currentLen == 0 ? word.count : word.count + 1
            if currentLen + addition > maxChunkSize && !current.isEmpty {
                flush()
                // Build overlap tail from the end of the current chunk.
                let tail = overlapTail(from: current)
                current = tail.words
                currentLen = tail.length
                // Do not advance i; re-evaluate the current word against the new chunk.
                continue
            }
            current.append(word)
            currentLen += addition
            i += 1
        }
        flush()
        return chunks
    }

    /// Collapses runs of whitespace (including newlines) into single spaces and trims.
    private func normalizeWhitespace(_ text: String) -> String {
        let components = text.split(whereSeparator: { $0.isWhitespace })
        return components.joined(separator: " ")
    }

    /// Returns the trailing words of a chunk that fit within `overlap` characters,
    /// used to seed the next chunk with overlapping context.
    private func overlapTail(from words: [String]) -> (words: [String], length: Int) {
        guard overlap > 0 else { return ([], 0) }
        var tail: [String] = []
        var length = 0
        for word in words.reversed() {
            let addition = tail.isEmpty ? word.count : word.count + 1
            if length + addition > overlap { break }
            tail.insert(word, at: 0)
            length += addition
        }
        return (tail, length)
    }
}
