import SwiftUI
import RecallCore

/// Application entry point. Builds the composition root once and injects the
/// view models into the UI. If the database cannot be opened, a clear failure
/// screen is shown instead of crashing.
@main
struct RecallApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup("Recall") {
            Group {
                switch container.state {
                case .ready(let search, let indexing):
                    ContentView(search: search, indexing: indexing)
                case .failed(let message):
                    StartupErrorView(message: message)
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the default "New" with nothing meaningful; keep standard menus.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Holds the constructed environment and derived view models, surfacing any
/// startup failure as UI state.
@MainActor
final class AppContainer: ObservableObject {
    enum State {
        case ready(SearchViewModel, IndexingViewModel)
        case failed(String)
    }

    @Published private(set) var state: State

    init() {
        do {
            let env = try RecallEnvironment()
            let search = SearchViewModel(searchService: env.searchService)
            let indexing = IndexingViewModel(repository: env.repository, indexer: env.indexer)
            self.state = .ready(search, indexing)
        } catch {
            self.state = .failed("Could not open the Recall database: \(error.localizedDescription)")
        }
    }
}

struct StartupErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Recall couldn't start").font(.title2).fontWeight(.semibold)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
        }
        .frame(minWidth: 520, minHeight: 360)
        .padding()
    }
}
