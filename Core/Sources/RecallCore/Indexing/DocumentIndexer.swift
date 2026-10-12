import Foundation

/// Observable progress for the indexing pipeline.
public struct IndexingProgress: Sendable, Equatable {
    public var total: Int
    public var processed: Int
    public var skipped: Int
    public var failed: Int
    public var currentFile: String?
    public var isRunning: Bool

    public init(total: Int = 0, processed: Int = 0, skipped: Int = 0, failed: Int = 0, currentFile: String? = nil, isRunning: Bool = false) {
        self.total = total
        self.processed = processed
        self.skipped = skipped
        self.failed = failed
        self.currentFile = currentFile
        self.isRunning = isRunning
    }
}

/// Discovers supported files under selected folders and coordinates extraction,
/// chunking, embedding and persistence.
///
/// Heavy work (extraction + embedding) runs off the main thread. Concurrency is
/// bounded by `maxConcurrentTasks` to keep memory and CPU in check. The pipeline
/// is cancellable and resumes cleanly: because each document is committed in its
/// own transaction and content hashes gate re-embedding, an interrupted run is
/// simply re-run and already-indexed, unchanged files are skipped.
public actor DocumentIndexer {
    private let repository: SQLiteDocumentRepository
    private let embedder: EmbeddingProvider
    private let extractors: DocumentExtractorRegistry
    private let chunker: TextChunker
    private let maxConcurrentTasks: Int
    private let embedBatchSize: Int
    private let fileManager: FileManager

    private var progress = IndexingProgress()
    private var progressHandler: (@Sendable (IndexingProgress) -> Void)?

    public init(
        repository: SQLiteDocumentRepository,
        embedder: EmbeddingProvider,
        extractors: DocumentExtractorRegistry = DocumentExtractorRegistry(),
        chunker: TextChunker = TextChunker(),
        maxConcurrentTasks: Int = 2,
        embedBatchSize: Int = 16,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.embedder = embedder
        self.extractors = extractors
        self.chunker = chunker
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
        self.embedBatchSize = max(1, embedBatchSize)
        self.fileManager = fileManager
    }

    public func setProgressHandler(_ handler: @escaping @Sendable (IndexingProgress) -> Void) {
        self.progressHandler = handler
    }

    public func currentProgress() -> IndexingProgress { progress }

    private func emit() {
        progressHandler?(progress)
    }

    /// Recursively discovers supported files under the given folders.
    /// Directory names that are never indexed. These hold dependencies, build
    /// output, or VCS metadata — not user documents — and would otherwise bloat
    /// the index with thousands of irrelevant files (e.g. node_modules READMEs).
    public static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", ".build", "build", "dist",
        "DerivedData", ".venv", "venv", "__pycache__", ".next", ".nuxt",
        "target", "Pods", "Carthage", ".gradle", ".idea", ".cache"
    ]

    public func discoverFiles(in folders: [URL]) -> [URL] {
        var found: [URL] = []
        for folder in folders {
            // Resolve symlinks so discovered paths are canonical (e.g. macOS maps
            // /var -> /private/var). This keeps stored paths consistent with the
            // folder-scope checks used during deletion reconciliation.
            let resolved = folder.resolvingSymlinksInPath()
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            guard let enumerator = fileManager.enumerator(
                at: resolved,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                // Skip (and don't descend into) excluded directories.
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if Self.excludedDirectoryNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension
                if FileType.from(pathExtension: ext) != nil {
                    found.append(url.resolvingSymlinksInPath())
                }
            }
        }
        return found
    }

    /// Indexes the given folders. Ensures the embedding runtime is available
    /// first so we fail fast with an actionable error instead of marking many
    /// documents failed. Honors Swift task cancellation.
    public func index(folders: [URL]) async throws {
        try await embedder.ensureAvailable()

        let files = discoverFiles(in: folders)
        progress = IndexingProgress(total: files.count, isRunning: true)
        emit()

        // Reconcile deletions: remove indexed documents that are under these
        // folders but no longer exist on disk.
        try reconcileDeletions(folders: folders, discovered: Set(files.map { $0.path }))

        // Bounded concurrency via a sliding window of child tasks. `addNext`
        // itself updates `active`, so callers must NOT also adjust it (an earlier
        // double-increment here caused the loop to spin forever).
        var iterator = files.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            @discardableResult
            func addNext() -> Bool {
                guard let url = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return }
                    try Task.checkCancellation()
                    await self.indexOne(url)
                }
                active += 1
                return true
            }
            // Prime the window.
            for _ in 0..<maxConcurrentTasks { if !addNext() { break } }
            // Each time a task completes, start at most one more.
            while active > 0 {
                try await group.next()
                active -= 1
                if Task.isCancelled { break }
                addNext()
            }
            if Task.isCancelled {
                group.cancelAll()
            }
        }

        progress.isRunning = false
        progress.currentFile = nil
        emit()
    }

    /// Indexes a single file, skipping it if its content hash is unchanged.
    private func indexOne(_ url: URL) async {
        progress.currentFile = url.lastPathComponent
        emit()

        guard let fileType = FileType.from(pathExtension: url.pathExtension) else {
            return
        }

        do {
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            let modified = (attrs[.modificationDate] as? Date) ?? Date()

            let extracted = try extractors.extract(from: url, fileType: fileType)

            // Skip if we already have this exact content indexed.
            if let existing = try repository.document(withPath: url.path),
               existing.contentHash == extracted.contentHash,
               existing.indexStatus == .indexed {
                progress.skipped += 1
                progress.processed += 1
                emit()
                return
            }

            // Upsert document metadata (status: indexing).
            var doc = Document(
                path: url.path,
                filename: url.lastPathComponent,
                fileType: fileType,
                modifiedAt: modified,
                contentHash: extracted.contentHash,
                indexStatus: .indexing
            )
            doc.id = try repository.upsertDocument(doc)

            // Chunk and embed.
            let textChunks = chunker.chunk(segments: extracted.segments)
            guard !textChunks.isEmpty else {
                try repository.updateStatus(documentID: doc.id, status: .failed, error: "No text to index")
                progress.failed += 1
                progress.processed += 1
                emit()
                return
            }

            var chunks: [Chunk] = []
            var chunkIndex = 0
            // Embed in bounded batches to limit peak memory.
            var batchStart = 0
            while batchStart < textChunks.count {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + embedBatchSize, textChunks.count)
                let batch = Array(textChunks[batchStart..<batchEnd])
                let vectors = try await embedder.embed(batch.map { $0.text })
                for (i, tc) in batch.enumerated() {
                    chunks.append(Chunk(
                        documentID: doc.id,
                        chunkIndex: chunkIndex,
                        text: tc.text,
                        pageNumber: tc.pageNumber,
                        embeddingModel: embedder.modelIdentifier,
                        embedding: vectors[i]
                    ))
                    chunkIndex += 1
                }
                batchStart = batchEnd
            }

            // Atomically replace this document's chunks.
            try repository.replaceChunks(documentID: doc.id, chunks: chunks)
            progress.processed += 1
            emit()
        } catch is CancellationError {
            // Leave status as-is; a later run resumes it.
        } catch {
            // Record the failure but keep going with other files.
            if let doc = try? repository.document(withPath: url.path) {
                try? repository.updateStatus(documentID: doc.id, status: .failed, error: error.localizedDescription)
            } else {
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                let modified = (attrs?[.modificationDate] as? Date) ?? Date()
                let doc = Document(
                    path: url.path,
                    filename: url.lastPathComponent,
                    fileType: fileType,
                    modifiedAt: modified,
                    contentHash: "",
                    indexStatus: .failed,
                    errorMessage: error.localizedDescription
                )
                _ = try? repository.upsertDocument(doc)
            }
            progress.failed += 1
            progress.processed += 1
            emit()
        }
    }

    /// Removes documents under the given folders that no longer exist on disk.
    private func reconcileDeletions(folders: [URL], discovered: Set<String>) throws {
        let folderPaths = folders.map { $0.resolvingSymlinksInPath().path }
        let docs = try repository.allDocuments()
        for doc in docs {
            let underScope = folderPaths.contains { doc.path == $0 || doc.path.hasPrefix($0 + "/") }
            guard underScope else { continue }
            if !discovered.contains(doc.path) || !fileManager.fileExists(atPath: doc.path) {
                try repository.deleteDocument(id: doc.id)
            }
        }
    }
}
