import Testing
import Foundation
@testable import RecallCore

@Suite struct RepositoryTests {
    private func makeRepo() throws -> SQLiteDocumentRepository {
        try SQLiteDocumentRepository(path: ":memory:")
    }

    private func makeChunk(doc: Int64, index: Int, text: String, page: Int? = nil) -> Chunk {
        Chunk(documentID: doc, chunkIndex: index, text: text, pageNumber: page,
              embeddingModel: "fake", embedding: [Float(index), 0.1, 0.2])
    }

    @Test func upsertAndFetchDocument() throws {
        let repo = try makeRepo()
        let doc = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text,
                           modifiedAt: Date(timeIntervalSince1970: 100), contentHash: "h1")
        let id = try repo.upsertDocument(doc)
        #expect(id > 0)
        let fetched = try repo.document(withPath: "/tmp/a.txt")
        #expect(fetched?.filename == "a.txt")
        #expect(fetched?.contentHash == "h1")
    }

    @Test func upsertUpdatesExistingByPath() throws {
        let repo = try makeRepo()
        let d1 = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let id1 = try repo.upsertDocument(d1)
        var d2 = d1
        d2.contentHash = "h2"
        let id2 = try repo.upsertDocument(d2)
        #expect(id1 == id2)
        #expect(try repo.document(withPath: "/tmp/a.txt")?.contentHash == "h2")
        #expect(try repo.allDocuments().count == 1)
    }

    @Test func replaceChunksIsAtomicAndReplaces() throws {
        let repo = try makeRepo()
        let doc = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let id = try repo.upsertDocument(doc)
        try repo.replaceChunks(documentID: id, chunks: [
            makeChunk(doc: id, index: 0, text: "first"),
            makeChunk(doc: id, index: 1, text: "second")
        ])
        #expect(try repo.chunkCount(documentID: id) == 2)
        try repo.replaceChunks(documentID: id, chunks: [makeChunk(doc: id, index: 0, text: "only")])
        #expect(try repo.chunkCount(documentID: id) == 1)
    }

    @Test func deleteDocumentCascadesToChunks() throws {
        let repo = try makeRepo()
        let doc = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let id = try repo.upsertDocument(doc)
        try repo.replaceChunks(documentID: id, chunks: [makeChunk(doc: id, index: 0, text: "x")])
        #expect(try repo.chunkCount(documentID: id) == 1)
        try repo.deleteDocument(id: id)
        #expect(try repo.chunkCount(documentID: id) == 0)
        #expect(try repo.document(id: id) == nil)
        #expect(try repo.loadAllVectors().isEmpty)
    }

    @Test func keywordSearchFindsChunks() throws {
        let repo = try makeRepo()
        let doc = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let id = try repo.upsertDocument(doc)
        try repo.replaceChunks(documentID: id, chunks: [
            makeChunk(doc: id, index: 0, text: "postgres detects deadlocks with a wait-for graph"),
            makeChunk(doc: id, index: 1, text: "redis persistence uses rdb and aof")
        ])
        let hits = try repo.keywordSearch("\"deadlocks\"*", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first!.text.contains("deadlocks"))
    }

    @Test func ftsEntriesRemovedWhenChunksReplaced() throws {
        let repo = try makeRepo()
        let doc = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let id = try repo.upsertDocument(doc)
        try repo.replaceChunks(documentID: id, chunks: [makeChunk(doc: id, index: 0, text: "deadlocks everywhere")])
        #expect(try repo.keywordSearch("\"deadlocks\"*", limit: 10).count == 1)
        try repo.replaceChunks(documentID: id, chunks: [makeChunk(doc: id, index: 0, text: "something unrelated")])
        #expect(try repo.keywordSearch("\"deadlocks\"*", limit: 10).count == 0)
    }

    @Test func removeFolderDeletesContainedDocuments() throws {
        let repo = try makeRepo()
        let inside = Document(path: "/tmp/folder/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let outside = Document(path: "/tmp/other/b.txt", filename: "b.txt", fileType: .text, modifiedAt: Date(), contentHash: "h2")
        _ = try repo.upsertDocument(inside)
        _ = try repo.upsertDocument(outside)
        try repo.addFolder(path: "/tmp/folder", bookmark: nil)
        try repo.removeFolder(path: "/tmp/folder")
        #expect(try repo.document(withPath: "/tmp/folder/a.txt") == nil)
        #expect(try repo.document(withPath: "/tmp/other/b.txt") != nil)
        #expect(try repo.allFolders().isEmpty)
    }

    @Test func vectorRoundTripsThroughStorage() throws {
        let repo = try makeRepo()
        let doc = Document(path: "/tmp/a.txt", filename: "a.txt", fileType: .text, modifiedAt: Date(), contentHash: "h1")
        let id = try repo.upsertDocument(doc)
        let embedding: [Float] = [0.1, 0.2, 0.3, 0.4]
        try repo.replaceChunks(documentID: id, chunks: [
            Chunk(documentID: id, chunkIndex: 0, text: "x", pageNumber: 7, embeddingModel: "fake", embedding: embedding)
        ])
        let loaded = try repo.loadAllVectors()
        #expect(loaded.count == 1)
        #expect(loaded[0].1 == embedding)
        #expect(loaded[0].0.pageNumber == 7)
    }
}
