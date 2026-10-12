import Foundation
import SwiftUI
import AppKit
import RecallCore

/// Manages indexed folders and runs the indexing pipeline, exposing progress to
/// the UI. Folder selection uses a native open panel; only user-selected folders
/// are ever indexed.
@MainActor
final class IndexingViewModel: ObservableObject {
    @Published private(set) var folders: [IndexedFolder] = []
    @Published private(set) var progress = IndexingProgress()
    @Published var lastError: String?

    private let repository: SQLiteDocumentRepository
    private let indexer: DocumentIndexer
    private var monitor: FileChangeMonitor?
    private var indexTask: Task<Void, Never>?

    init(repository: SQLiteDocumentRepository, indexer: DocumentIndexer) {
        self.repository = repository
        self.indexer = indexer
        reloadFolders()
        Task { await setupProgressForwarding() }
    }

    private func setupProgressForwarding() async {
        await indexer.setProgressHandler { [weak self] progress in
            Task { @MainActor in self?.progress = progress }
        }
    }

    func reloadFolders() {
        folders = (try? repository.allFolders()) ?? []
    }

    /// Presents a native folder picker and adds the chosen folder.
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Index Folder"
        panel.message = "Choose folders to index for semantic search."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addFolder(url)
        }
        reloadFolders()
        startIndexing()
    }

    private func addFolder(_ url: URL) {
        // Persist a security-scoped bookmark so access survives relaunches.
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = try? repository.addFolder(path: url.path, bookmark: bookmark)
    }

    func removeFolder(_ folder: IndexedFolder) {
        try? repository.removeFolder(path: folder.path)
        reloadFolders()
        restartMonitoring()
    }

    /// Resolves folder URLs, honoring security-scoped bookmarks where available.
    private func folderURLs() -> [URL] {
        folders.map { folder in
            if let bookmark = folder.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    _ = url.startAccessingSecurityScopedResource()
                    return url
                }
            }
            return URL(fileURLWithPath: folder.path)
        }
    }

    /// Runs a full index pass over all selected folders.
    func startIndexing() {
        indexTask?.cancel()
        let urls = folderURLs()
        guard !urls.isEmpty else { return }
        indexTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.indexer.index(folders: urls)
                await MainActor.run { self.lastError = nil }
            } catch is CancellationError {
                // ignored
            } catch {
                await MainActor.run {
                    self.lastError = SearchViewModel.friendlyMessage(for: error)
                }
            }
        }
        restartMonitoring()
    }

    func cancelIndexing() {
        indexTask?.cancel()
    }

    /// Reconciles on launch and starts watching for changes.
    func startupReconcile() {
        startIndexing()
    }

    private func restartMonitoring() {
        monitor?.stop()
        let urls = folderURLs()
        guard !urls.isEmpty else { monitor = nil; return }
        let m = FileChangeMonitor { [weak self] in
            Task { @MainActor in self?.startIndexing() }
        }
        m.start(folders: urls)
        monitor = m
    }
}
