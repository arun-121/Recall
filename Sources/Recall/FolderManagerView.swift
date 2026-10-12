import SwiftUI
import RecallCore

/// A sheet for managing which folders are indexed. Lets the user add folders via
/// the native picker, remove folders (deleting their indexed data), and trigger
/// a rescan.
struct FolderManagerView: View {
    @ObservedObject var indexing: IndexingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Indexed Folders").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if indexing.folders.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No folders yet")
                        .font(.headline)
                    Text("Add a folder to index its PDFs, Markdown and text files.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(indexing.folders) { folder in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                                    .fontWeight(.medium)
                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                indexing.removeFolder(folder)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove folder and its indexed data")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    indexing.pickFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Button {
                    indexing.startIndexing()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(indexing.folders.isEmpty || indexing.progress.isRunning)
                Spacer()
                if indexing.progress.isRunning {
                    Button("Cancel", role: .cancel) { indexing.cancelIndexing() }
                    ProgressView().controlSize(.small)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 420)
    }
}
