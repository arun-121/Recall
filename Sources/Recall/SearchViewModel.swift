import Foundation
import SwiftUI
import RecallCore

/// UI-facing state for a search session. Owns query text, debouncing, result
/// list, selection index and all loading/empty/error states. Depends only on
/// the `SearchService` protocol, never on the embedder or database directly.
@MainActor
final class SearchViewModel: ObservableObject {
    enum ViewState: Equatable {
        case idle
        case loading
        case results([SearchResult])
        case empty          // query ran, no matches
        case error(String)  // actionable message
    }

    @Published var query: String = ""
    @Published private(set) var state: ViewState = .idle
    @Published var selectedIndex: Int = 0

    private let searchService: SearchService
    private var searchTask: Task<Void, Never>?
    private let debounce: Duration
    private let resultLimit: Int

    init(searchService: SearchService, debounce: Duration = .milliseconds(250), resultLimit: Int = 30) {
        self.searchService = searchService
        self.debounce = debounce
        self.resultLimit = resultLimit
    }

    var results: [SearchResult] {
        if case .results(let r) = state { return r }
        return []
    }

    /// Called whenever the query changes. Debounces then searches.
    func queryChanged(_ newValue: String) {
        query = newValue
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            selectedIndex = 0
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self.performSearch(trimmed)
        }
    }

    func performSearch(_ q: String) async {
        state = .loading
        do {
            let results = try await searchService.search(query: q, limit: resultLimit)
            if Task.isCancelled { return }
            selectedIndex = 0
            state = results.isEmpty ? .empty : .results(results)
        } catch {
            if Task.isCancelled { return }
            state = .error(Self.friendlyMessage(for: error))
        }
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        state = .idle
        selectedIndex = 0
    }

    // MARK: - Keyboard navigation

    func moveSelectionDown() {
        guard !results.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, results.count - 1)
    }

    func moveSelectionUp() {
        guard !results.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func selectedResult() -> SearchResult? {
        let r = results
        guard r.indices.contains(selectedIndex) else { return nil }
        return r[selectedIndex]
    }

    /// Opens the currently selected result's actual file.
    @discardableResult
    func openSelected() -> Bool {
        guard let result = selectedResult() else { return false }
        return FileOpener.open(url: result.fileURL, pageNumber: result.pageNumber)
    }

    /// Turns errors into actionable, user-facing guidance.
    static func friendlyMessage(for error: Error) -> String {
        if let e = error as? EmbeddingError {
            switch e {
            case .runtimeUnavailable:
                return "Can't reach the local embedding runtime. Start Ollama with `ollama serve`, then try again."
            case .modelNotInstalled(let model):
                return "The embedding model '\(model)' isn't installed. Run `ollama pull \(model)` in Terminal, then retry."
            default:
                return e.errorDescription ?? "Embedding error."
            }
        }
        return error.localizedDescription
    }
}
