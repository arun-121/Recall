import Foundation

/// A deterministic, dependency-free embedding provider for tests and SwiftUI
/// previews. It maps text to a vector using a hashed bag-of-tokens projection so
/// that similar texts (sharing tokens) produce similar vectors, while remaining
/// fully reproducible and requiring no model download.
///
/// This is explicitly NOT used in the production search path.
public final class FakeEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelIdentifier: String
    public let dimensions: Int
    private let shouldFail: Bool

    public init(modelIdentifier: String = "fake-embed", dimensions: Int = 64, shouldFail: Bool = false) {
        self.modelIdentifier = modelIdentifier
        self.dimensions = dimensions
        self.shouldFail = shouldFail
    }

    public func ensureAvailable() async throws {
        if shouldFail {
            throw EmbeddingError.runtimeUnavailable("FakeEmbeddingProvider configured to fail.")
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        if shouldFail {
            throw EmbeddingError.runtimeUnavailable("FakeEmbeddingProvider configured to fail.")
        }
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EmbeddingError.emptyInput
        }
        return texts.map { vector(for: $0) }
    }

    /// Builds a normalized vector by hashing lowercased word tokens into buckets.
    private func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            let bucket = Int(stableHash(String(token)) % UInt64(dimensions))
            v[bucket] += 1
        }
        return VectorMath.normalized(v)
    }

    /// A stable FNV-1a hash so results do not vary across runs or processes
    /// (unlike Swift's `Hasher`, which is seeded per-process).
    private func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}
