import Foundation
import RecallCore

/// Composition root that wires concrete implementations together. This is the
/// single place that knows about Ollama, SQLite and the filesystem; the views
/// and view models depend only on the protocols/types exposed here.
@MainActor
final class RecallEnvironment: ObservableObject {
    let repository: SQLiteDocumentRepository
    let embedder: EmbeddingProvider
    let searchService: SearchService
    let indexer: DocumentIndexer

    /// The on-disk location of the Recall database (Application Support).
    static func defaultDatabasePath() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Recall", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recall.sqlite").path
    }

    init(databasePath: String? = nil) throws {
        let path = databasePath ?? Self.defaultDatabasePath()
        self.repository = try SQLiteDocumentRepository(path: path)
        let localEmbedder = LocalEmbeddingProvider()
        self.embedder = localEmbedder
        self.searchService = HybridSearchService(repository: repository, embedder: localEmbedder)
        self.indexer = DocumentIndexer(repository: repository, embedder: localEmbedder)
    }
}
