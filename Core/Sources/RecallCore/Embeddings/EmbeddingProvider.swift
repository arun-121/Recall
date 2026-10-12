import Foundation

/// Generates embedding vectors for text. Implementations must keep document
/// chunks and search queries on the same model and dimensionality.
public protocol EmbeddingProvider: Sendable {
    /// A stable identifier for the underlying model (persisted with each chunk).
    var modelIdentifier: String { get }
    /// The dimensionality of vectors produced by this provider.
    var dimensions: Int { get }

    /// Verifies the provider is ready (runtime reachable, model installed).
    /// Throws `EmbeddingError` with an actionable message otherwise.
    func ensureAvailable() async throws

    /// Embeds a batch of texts, returning one vector per input in order.
    /// Implementations should normalize vectors when appropriate for cosine use.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingProvider {
    /// Convenience single-text embedding.
    func embed(_ text: String) async throws -> [Float] {
        let vectors = try await embed([text])
        guard let first = vectors.first else {
            throw EmbeddingError.invalidResponse("empty batch result")
        }
        return first
    }
}

/// Pure vector operations used by semantic search. Kept dependency-free and
/// deterministic so they can be unit tested directly.
public enum VectorMath {
    /// L2-normalizes a vector in place-returning form. A zero vector is returned
    /// unchanged to avoid division by zero.
    public static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Dot product of two equal-length vectors.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vector length mismatch")
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    /// Cosine similarity in [-1, 1]. Returns 0 if either vector is zero-length.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vector length mismatch")
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
