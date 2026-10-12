import Foundation

/// The search interface the UI depends on. Concrete implementations handle the
/// real retrieval; the UI never touches the embedding model or database directly.
public protocol SearchService: Sendable {
    func search(query: String, limit: Int) async throws -> [SearchResult]
}

/// Reciprocal Rank Fusion.
///
/// We deliberately avoid summing cosine similarity and bm25 scores because they
/// live on different, incomparable scales. RRF instead fuses *rankings*: each
/// candidate list contributes 1/(k + rank) for the documents/chunks it ranks,
/// and contributions are summed. This is robust, parameter-light and well
/// documented in IR literature.
public enum ReciprocalRankFusion {
    /// A ranked list of chunk candidates from one retrieval source.
    public struct RankedList {
        public var chunks: [ScoredChunk]
        /// Optional per-source weight (default 1.0).
        public var weight: Double
        public init(_ chunks: [ScoredChunk], weight: Double = 1.0) {
            self.chunks = chunks
            self.weight = weight
        }
    }

    /// Fuses multiple ranked lists into a single chunk-level score map.
    /// - Parameter k: RRF damping constant (60 is the common default).
    /// - Returns: chunkID -> fused score, plus the best `ScoredChunk` seen per id.
    public static func fuse(
        lists: [RankedList],
        k: Double = 60
    ) -> [(chunk: ScoredChunk, score: Double)] {
        var scoreByChunk: [Int64: Double] = [:]
        var chunkByID: [Int64: ScoredChunk] = [:]

        for list in lists {
            for (rank, chunk) in list.chunks.enumerated() {
                let contribution = list.weight * (1.0 / (k + Double(rank + 1)))
                scoreByChunk[chunk.chunkID, default: 0] += contribution
                // Keep the representative chunk (first seen wins; they share identity).
                if chunkByID[chunk.chunkID] == nil {
                    chunkByID[chunk.chunkID] = chunk
                }
            }
        }

        return scoreByChunk
            .map { (chunkByID[$0.key]!, $0.value) }
            .sorted { $0.1 > $1.1 }
    }
}

/// Groups fused chunk results into document-level results, keeping the single
/// best-scoring chunk per document as the representative snippet.
public enum ResultGrouping {
    public static func groupByDocument(
        _ fused: [(chunk: ScoredChunk, score: Double)]
    ) -> [(documentID: Int64, best: ScoredChunk, score: Double)] {
        var bestByDoc: [Int64: (ScoredChunk, Double)] = [:]
        var totalByDoc: [Int64: Double] = [:]

        for (chunk, score) in fused {
            totalByDoc[chunk.documentID, default: 0] += score
            if let existing = bestByDoc[chunk.documentID] {
                if score > existing.1 {
                    bestByDoc[chunk.documentID] = (chunk, score)
                }
            } else {
                bestByDoc[chunk.documentID] = (chunk, score)
            }
        }

        // Document score = sum of its chunk contributions (rewards multiple hits),
        // ordered descending.
        return bestByDoc.map { (docID, pair) in
            (docID, pair.0, totalByDoc[docID] ?? pair.1)
        }
        .sorted { $0.2 > $1.2 }
    }
}

/// Translates a free-text query into an FTS5 MATCH expression. Each term is
/// quoted to neutralize FTS operators and a trailing `*` enables prefix match,
/// improving recall for partial words. Empty queries yield nil.
public enum FTSQueryBuilder {
    public static func build(from query: String) -> String? {
        let terms = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        // Quote each term and add prefix matching.
        return terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
