import Foundation

/// Embedding provider backed by a local Ollama runtime.
///
/// Uses Ollama's HTTP API on localhost. Document contents never leave the
/// machine: requests go only to the configured local base URL. If the runtime
/// is unreachable or the model is missing, an actionable `EmbeddingError` is
/// thrown rather than falling back to any cloud service.
///
/// The default model is `nomic-embed-text`, a dedicated embedding model
/// (768 dimensions), not a generative LLM.
public final class LocalEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelIdentifier: String
    public let dimensions: Int
    private let baseURL: URL
    private let session: URLSession
    private let normalizeOutput: Bool

    public init(
        model: String = "nomic-embed-text",
        dimensions: Int = 768,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        normalizeOutput: Bool = true,
        session: URLSession = .shared
    ) {
        self.modelIdentifier = model
        self.dimensions = dimensions
        self.baseURL = baseURL
        self.normalizeOutput = normalizeOutput
        self.session = session
    }

    public func ensureAvailable() async throws {
        // 1. Is the runtime reachable?
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 5
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingError.runtimeUnavailable(
                "Could not reach Ollama at \(baseURL.absoluteString). Is it running? (\(error.localizedDescription))"
            )
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EmbeddingError.runtimeUnavailable("Ollama returned a non-200 response from /api/tags.")
        }

        // 2. Is the model installed?
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else {
            throw EmbeddingError.invalidResponse("Unexpected /api/tags payload.")
        }
        let installed = models.compactMap { $0["name"] as? String }
        let isInstalled = installed.contains { name in
            name == modelIdentifier || name.hasPrefix(modelIdentifier + ":")
        }
        guard isInstalled else {
            throw EmbeddingError.modelNotInstalled(modelIdentifier)
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EmbeddingError.emptyInput
        }

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        // Ollama's /api/embeddings takes a single prompt; we iterate but keep the
        // batch-shaped API so a future batching endpoint can be swapped in.
        for text in texts {
            let vector = try await embedSingle(text)
            if vector.count != dimensions {
                throw EmbeddingError.dimensionMismatch(expected: dimensions, got: vector.count)
            }
            results.append(normalizeOutput ? VectorMath.normalized(vector) : vector)
        }
        return results
    }

    private func embedSingle(_ text: String) async throws -> [Float] {
        let url = baseURL.appendingPathComponent("api/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let payload: [String: Any] = ["model": modelIdentifier, "prompt": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingError.runtimeUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.invalidResponse("No HTTP response.")
        }
        guard http.statusCode == 200 else {
            // Ollama returns 404 with a message when the model is missing.
            if http.statusCode == 404 {
                throw EmbeddingError.modelNotInstalled(modelIdentifier)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EmbeddingError.invalidResponse("HTTP \(http.statusCode): \(body)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let embedding = json["embedding"] as? [Double]
        else {
            throw EmbeddingError.invalidResponse("Missing 'embedding' field.")
        }
        return embedding.map { Float($0) }
    }
}
