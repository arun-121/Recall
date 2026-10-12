import Testing
import Foundation
@testable import RecallCore

@Suite struct EmbeddingProviderTests {
    @Test func fakeProviderIsDeterministic() async throws {
        let p = FakeEmbeddingProvider(dimensions: 32)
        let a = try await p.embed("hello world")
        let b = try await p.embed("hello world")
        #expect(a == b)
        #expect(a.count == 32)
    }

    @Test func similarTextsAreCloserThanDissimilar() async throws {
        let p = FakeEmbeddingProvider(dimensions: 128)
        let base = try await p.embed("redis persistence rdb aof")
        let similar = try await p.embed("redis persistence configuration")
        let different = try await p.embed("postgres deadlock detection graph")
        let simScore = VectorMath.cosineSimilarity(base, similar)
        let diffScore = VectorMath.cosineSimilarity(base, different)
        #expect(simScore > diffScore)
    }

    @Test func emptyInputThrows() async {
        let p = FakeEmbeddingProvider()
        await #expect(throws: EmbeddingError.emptyInput) {
            _ = try await p.embed([" "])
        }
    }

    @Test func emptyBatchReturnsEmpty() async throws {
        let p = FakeEmbeddingProvider()
        let result = try await p.embed([String]())
        #expect(result.isEmpty)
    }

    @Test func providerFailurePropagates() async {
        let p = FakeEmbeddingProvider(shouldFail: true)
        await #expect(throws: EmbeddingError.self) {
            try await p.ensureAvailable()
        }
    }
}

@Suite struct IndexAndSearchIntegrationTests {
    @Test func indexThenSearchReturnsRelevantDocument() async throws {
        let dir = try TempDir()
        _ = try dir.writeFile("postgres.md", contents: "# Postgres\nPostgres detects deadlocks using a wait-for graph and aborts a transaction.")
        _ = try dir.writeFile("redis.md", contents: "# Redis\nRedis persistence works via RDB snapshots and the AOF append-only file.")
        _ = try dir.writeFile("vectors.txt", contents: "A vector database stores embeddings and supports nearest neighbor search.")

        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider(dimensions: 128)
        let indexer = DocumentIndexer(repository: repo, embedder: embedder, maxConcurrentTasks: 2)
        try await indexer.index(folders: [dir.url])

        #expect(try repo.allDocuments().count == 3)
        #expect(try repo.allDocuments().allSatisfy { $0.indexStatus == .indexed })

        let search = HybridSearchService(repository: repo, embedder: embedder)
        let results = try await search.search(query: "how are deadlocks detected", limit: 10)
        #expect(!results.isEmpty)
        #expect(results.first?.filename == "postgres.md")
    }

    @Test func emptyQueryReturnsNoResultsWithoutError() async throws {
        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider()
        let search = HybridSearchService(repository: repo, embedder: embedder)
        let results = try await search.search(query: "   ", limit: 10)
        #expect(results.isEmpty)
    }

    @Test func unchangedFilesAreSkippedOnReindex() async throws {
        let dir = try TempDir()
        _ = try dir.writeFile("a.txt", contents: "stable content that will not change")
        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider()
        let indexer = DocumentIndexer(repository: repo, embedder: embedder)

        try await indexer.index(folders: [dir.url])
        #expect(try repo.allDocuments().first?.lastIndexedAt != nil)

        try await indexer.index(folders: [dir.url])
        let progress = await indexer.currentProgress()
        #expect(progress.skipped == 1)
    }

    @Test func modifiedFileIsReindexed() async throws {
        let dir = try TempDir()
        let url = try dir.writeFile("a.txt", contents: "original content about cats")
        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider()
        let indexer = DocumentIndexer(repository: repo, embedder: embedder)
        try await indexer.index(folders: [dir.url])
        let originalHash = try repo.allDocuments().first?.contentHash

        try "completely different content about dogs".data(using: .utf8)!.write(to: url)
        try await indexer.index(folders: [dir.url])
        let newHash = try repo.allDocuments().first?.contentHash
        #expect(originalHash != newHash)
    }

    @Test func deletedFileIsRemovedOnReconcile() async throws {
        let dir = try TempDir()
        let url = try dir.writeFile("a.txt", contents: "temporary content")
        _ = try dir.writeFile("b.txt", contents: "surviving content")
        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider()
        let indexer = DocumentIndexer(repository: repo, embedder: embedder)
        try await indexer.index(folders: [dir.url])
        #expect(try repo.allDocuments().count == 2)

        try FileManager.default.removeItem(at: url)
        try await indexer.index(folders: [dir.url])
        let docs = try repo.allDocuments()
        #expect(docs.count == 1)
        #expect(docs.first?.filename == "b.txt")
    }

    @Test func searchSkipsDeletedFileOnDisk() async throws {
        let dir = try TempDir()
        let url = try dir.writeFile("gone.txt", contents: "deadlock detection content here")
        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider()
        let indexer = DocumentIndexer(repository: repo, embedder: embedder)
        try await indexer.index(folders: [dir.url])

        try FileManager.default.removeItem(at: url)
        let search = HybridSearchService(repository: repo, embedder: embedder)
        let results = try await search.search(query: "deadlock detection", limit: 10)
        #expect(results.isEmpty)
    }

    @Test func embeddingFailureSurfacesWhenNoKeywordResults() async throws {
        let repo = try SQLiteDocumentRepository(path: ":memory:")
        let embedder = FakeEmbeddingProvider(shouldFail: true)
        let search = HybridSearchService(repository: repo, embedder: embedder)
        await #expect(throws: EmbeddingError.self) {
            _ = try await search.search(query: "anything", limit: 10)
        }
    }
}
