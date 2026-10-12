import Foundation

/// A temporary directory that cleans itself up when deallocated. Used for
/// integration tests that need real files on disk.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeFile(_ name: String, contents: String) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: fileURL)
        return fileURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
