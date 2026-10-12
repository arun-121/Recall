import Foundation

/// The production search service. It combines three retrieval signals and fuses
/// them with Reciprocal Rank Fusion:
///   1. Semantic similarity (query embedding vs. chunk vectors, exact cosine)
///   2. Keyword relevance (SQLite FTS5 / bm25)
///   3. Filename matching (lightweight lexical signal)
///
/// Results are grouped by document and only accessible, existing files are
/// returned, so a deleted or moved file is never surfaced as available.
public final class HybridSearchService: SearchService, @unchecked Sendable {
    private let repository: SQLiteDocumentRepository
    private let embedder: EmbeddingProvider
    private let semanticCandidateLimit: Int
    private let keywordCandidateLimit: Int
    /// Minimum cosine similarity for a chunk to count as a semantic match.
    /// Below this, the chunk is considered unrelated and is discarded, so an
    /// off-topic query (e.g. "umbrella" against a resume) returns no results
    /// instead of surfacing the nearest-but-irrelevant document.
    private let minSemanticSimilarity: Double
    private let fileManager: FileManager

    public init(
        repository: SQLiteDocumentRepository,
        embedder: EmbeddingProvider,
        semanticCandidateLimit: Int = 50,
        keywordCandidateLimit: Int = 50,
        minSemanticSimilarity: Double = 0.5,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.embedder = embedder
        self.semanticCandidateLimit = semanticCandidateLimit
        self.keywordCandidateLimit = keywordCandidateLimit
        self.minSemanticSimilarity = minSemanticSimilarity
        self.fileManager = fileManager
    }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty query -> no results (handled explicitly, never an error).
        guard !trimmed.isEmpty else { return [] }

        // 1. Semantic candidates (best-effort: if embedding fails we still return
        //    keyword results so search degrades gracefully).
        var semantic: [ScoredChunk] = []
        var semanticError: Error?
        do {
            semantic = try await semanticCandidates(for: trimmed)
        } catch {
            semanticError = error
        }

        // 2. Keyword candidates via FTS5.
        var keyword: [ScoredChunk] = []
        if let fts = FTSQueryBuilder.build(from: trimmed) {
            keyword = (try? repository.keywordSearch(fts, limit: keywordCandidateLimit)) ?? []
        }

        // If semantic failed AND keyword produced nothing, surface the embedding
        // error so the UI can show an actionable setup message.
        if let semanticError, keyword.isEmpty {
            throw semanticError
        }

        // 3. Filename signal: rank chunks of documents whose filename matches.
        let filename = try filenameCandidates(for: trimmed)

        // Fuse the three ranked lists. Semantic is weighted slightly higher since
        // it captures meaning; filename is a light tiebreaker.
        let fused = ReciprocalRankFusion.fuse(lists: [
            .init(semantic, weight: 1.0),
            .init(keyword, weight: 0.9),
            .init(filename, weight: 0.5)
        ])

        let grouped = ResultGrouping.groupByDocument(fused)

        // Build document-level results, skipping files that no longer exist.
        var results: [SearchResult] = []
        for group in grouped {
            guard let doc = try repository.document(id: group.documentID) else { continue }
            let url = URL(fileURLWithPath: doc.path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            results.append(SearchResult(
                documentID: doc.id,
                filename: doc.filename,
                fileURL: url,
                fileType: doc.fileType,
                snippet: Self.makeSnippet(from: group.best.text, query: trimmed),
                pageNumber: group.best.pageNumber,
                score: group.score
            ))
            if results.count >= limit { break }
        }
        return results
    }

    // MARK: - Candidate retrieval

    private func semanticCandidates(for query: String) async throws -> [ScoredChunk] {
        let queryVector = try await embedder.embed(query)
        let all = try repository.loadAllVectors()
        guard !all.isEmpty else { return [] }
        // Exact cosine similarity over all chunk vectors.
        var scored: [ScoredChunk] = all.map { (meta, vec) in
            var m = meta
            m.score = Double(VectorMath.cosineSimilarity(queryVector, vec))
            return m
        }
        scored.sort { $0.score > $1.score }
        // Discard chunks that are not similar enough to be considered relevant.
        // This prevents an off-topic query from matching the nearest-but-unrelated
        // document just because it is the closest vector available.
        let relevant = scored.filter { $0.score >= minSemanticSimilarity }
        return Array(relevant.prefix(semanticCandidateLimit))
    }

    private func filenameCandidates(for query: String) throws -> [ScoredChunk] {
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !terms.isEmpty else { return [] }
        let docs = try repository.allDocuments()
        // Score by number of query terms appearing in the filename.
        var matches: [(Document, Int)] = []
        for doc in docs {
            let name = doc.filename.lowercased()
            let hits = terms.reduce(0) { $0 + (name.contains($1) ? 1 : 0) }
            if hits > 0 { matches.append((doc, hits)) }
        }
        matches.sort { $0.1 > $1.1 }
        // Represent each matched document by a synthetic chunk pointing at its
        // first chunk's identity is unnecessary; we use documentID with a
        // placeholder chunk so fusion/grouping can attribute the signal.
        return matches.map { (doc, hits) in
            ScoredChunk(
                chunkID: -doc.id, // negative synthetic id to avoid colliding with real chunks
                documentID: doc.id,
                chunkIndex: 0,
                text: doc.filename,
                pageNumber: nil,
                score: Double(hits)
            )
        }
    }

    // MARK: - Snippet

    /// Produces a short snippet centered on the first query-term hit, falling
    /// back to the chunk prefix.
    static func makeSnippet(from text: String, query: String, maxLength: Int = 240) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let lower = collapsed.lowercased()
        var hitRange: Range<String.Index>?
        for term in terms {
            if let r = lower.range(of: term) { hitRange = r; break }
        }
        guard let hit = hitRange else {
            return String(collapsed.prefix(maxLength))
        }
        let start = collapsed.index(hit.lowerBound, offsetBy: -60, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let end = collapsed.index(hit.upperBound, offsetBy: 180, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        var snippet = String(collapsed[start..<end])
        if start != collapsed.startIndex { snippet = "…" + snippet }
        if end != collapsed.endIndex { snippet += "…" }
        return snippet
    }
}
