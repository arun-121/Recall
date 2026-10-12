import SwiftUI
import RecallCore

/// Small observable holder for view-local UI flags. Used instead of `@State`
/// because the `@State` macro plugin is unavailable in the Command Line Tools
/// toolchain (it ships with full Xcode). `@StateObject` works fine here.
@MainActor
final class ContentUIState: ObservableObject {
    @Published var showingFolders = false
}

/// The main search interface. Keyboard-first: type to search (debounced),
/// arrow keys to move through results, Return to open, Escape to clear.
struct ContentView: View {
    @ObservedObject var search: SearchViewModel
    @ObservedObject var indexing: IndexingViewModel
    @FocusState private var searchFieldFocused: Bool
    @StateObject private var ui = ContentUIState()

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            searchFieldFocused = true
            indexing.startupReconcile()
        }
        .sheet(isPresented: $ui.showingFolders) {
            FolderManagerView(indexing: indexing)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search your documents by meaning…", text: Binding(
                get: { search.query },
                set: { search.queryChanged($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 18))
            .focused($searchFieldFocused)
            .accessibilityLabel("Search documents")
            .onSubmit { search.openSelected() }
            // Keyboard navigation handlers (onKeyPress requires macOS 14+).
            .modifier(KeyNavigationModifier(search: search))

            if !search.query.isEmpty {
                Button {
                    search.clear()
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            Button {
                ui.showingFolders = true
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .buttonStyle(.plain)
            .help("Manage indexed folders")
            .accessibilityLabel("Manage indexed folders")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch search.state {
        case .idle:
            placeholder(
                icon: "sparkle.magnifyingglass",
                title: "Search by meaning",
                subtitle: indexing.folders.isEmpty
                    ? "Add a folder to start indexing your documents."
                    : "Try: “how deadlocks are detected” or “notes about Redis persistence”."
            )
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            placeholder(
                icon: "doc.text.magnifyingglass",
                title: "No results",
                subtitle: "No documents matched “\(search.query)”."
            )
        case .error(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text("Something needs attention")
                    .font(.headline)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .results(let results):
            resultsList(results)
        }
    }

    private func resultsList(_ results: [SearchResult]) -> some View {
        ScrollViewReader { proxy in
            List(Array(results.enumerated()), id: \.element.documentID) { index, result in
                ResultRow(result: result, isSelected: index == search.selectedIndex)
                    .id(index)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        search.selectedIndex = index
                        search.openSelected()
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .listStyle(.inset)
            .modifier(ScrollOnSelectionModifier(selectedIndex: search.selectedIndex, proxy: proxy))
        }
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3).fontWeight(.medium)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if indexing.progress.isRunning {
                ProgressView().controlSize(.small)
                Text("Indexing \(indexing.progress.processed)/\(indexing.progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let file = indexing.progress.currentFile {
                    Text("· \(file)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            } else {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(indexing.folders.count) folder\(indexing.folders.count == 1 ? "" : "s") indexed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if indexing.progress.failed > 0 {
                    Text("· \(indexing.progress.failed) failed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if case .results(let r) = search.state {
                Text("\(r.count) result\(r.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// A single search result row showing filename, type, snippet and page.
struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? Color.white : .accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(result.fileType.displayLabel)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    if let page = result.pageNumber {
                        Text("p.\(page)")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    }
                }
                Text(result.snippet)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.filename), \(result.fileType.displayLabel)\(result.pageNumber.map { ", page \($0)" } ?? "")")
        .accessibilityValue(result.snippet)
    }

    private var iconName: String {
        switch result.fileType {
        case .pdf: return "doc.richtext"
        case .markdown: return "text.alignleft"
        case .text: return "doc.text"
        }
    }
}


/// Applies arrow/return/escape key handling. `onKeyPress` requires macOS 14+,
/// so on macOS 13 we fall back to no inline key handling (the window still
/// supports Return via `.onSubmit` and the toolbar/menus remain usable). The
/// deployment target is kept at macOS 13 so the test toolchain's swift-testing
/// macros resolve; at runtime on macOS 14+ full key navigation is active.
struct KeyNavigationModifier: ViewModifier {
    @ObservedObject var search: SearchViewModel

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.downArrow) { search.moveSelectionDown(); return .handled }
                .onKeyPress(.upArrow) { search.moveSelectionUp(); return .handled }
                .onKeyPress(.return) { search.openSelected() ? .handled : .ignored }
                .onKeyPress(.escape) {
                    if search.query.isEmpty { return .ignored }
                    search.clear(); return .handled
                }
        } else {
            content
        }
    }
}

/// Scrolls the selected result into view when the selection changes. The
/// two-parameter `onChange` requires macOS 14+; on macOS 13 we use the
/// single-parameter variant.
struct ScrollOnSelectionModifier: ViewModifier {
    let selectedIndex: Int
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        } else {
            content.onChange(of: selectedIndex) { newValue in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}
