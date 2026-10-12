import Foundation
import CryptoKit

/// Computes stable content hashes used to detect whether a document's content
/// changed since it was last indexed. We hash extracted/normalized text content
/// rather than raw bytes so that trivially different encodings of the same text
/// are treated as equal where appropriate.
public enum ContentHasher {
    /// Hashes an arbitrary string (SHA-256, hex-encoded).
    public static func hash(_ string: String) -> String {
        hash(Data(string.utf8))
    }

    /// Hashes raw data (SHA-256, hex-encoded).
    public static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file's raw bytes by streaming it in bounded chunks so that large
    /// files are never fully loaded into memory at once.
    public static func hashFile(at url: URL, bufferSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: bufferSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
