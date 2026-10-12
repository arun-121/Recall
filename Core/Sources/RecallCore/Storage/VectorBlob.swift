import Foundation

/// Encodes/decodes `[Float]` vectors to/from a compact little-endian BLOB for
/// storage in SQLite. Using raw Float32 keeps storage small and decoding fast.
public enum VectorBlob {
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    public static func decode(_ data: Data, dimensions: Int) -> [Float] {
        guard data.count == dimensions * MemoryLayout<Float>.size else {
            // Fallback: decode whatever whole floats are present.
            let count = data.count / MemoryLayout<Float>.size
            var out = [Float](repeating: 0, count: count)
            _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return out
        }
        var out = [Float](repeating: 0, count: dimensions)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }
}
