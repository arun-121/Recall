import Testing
import Foundation
@testable import RecallCore

@Suite struct VectorMathTests {
    @Test func cosineIdenticalVectorsIsOne() {
        let v: [Float] = [1, 2, 3, 4]
        #expect(abs(VectorMath.cosineSimilarity(v, v) - 1.0) < 1e-5)
    }

    @Test func cosineOrthogonalIsZero() {
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
    }

    @Test func cosineOppositeIsMinusOne() {
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [-1, 0]) + 1.0) < 1e-6)
    }

    @Test func cosineZeroVectorIsZero() {
        #expect(VectorMath.cosineSimilarity([0, 0], [1, 1]) == 0.0)
    }

    @Test func normalizedHasUnitLength() {
        let n = VectorMath.normalized([3, 4])
        let len = (n[0] * n[0] + n[1] * n[1]).squareRoot()
        #expect(abs(len - 1.0) < 1e-6)
    }

    @Test func normalizedZeroVectorUnchanged() {
        #expect(VectorMath.normalized([0, 0]) == [0, 0])
    }
}

@Suite struct FusionTests {
    private func chunk(_ id: Int64, doc: Int64 = 1) -> ScoredChunk {
        ScoredChunk(chunkID: id, documentID: doc, chunkIndex: Int(id), text: "c\(id)", pageNumber: nil, score: 0)
    }

    @Test func rrfRewardsAgreementAcrossLists() {
        let listA = [chunk(1), chunk(2)]
        let listB = [chunk(1), chunk(3)]
        let fused = ReciprocalRankFusion.fuse(lists: [.init(listA), .init(listB)])
        #expect(fused.first?.chunk.chunkID == 1)
        let score1 = fused.first { $0.chunk.chunkID == 1 }!.score
        let score2 = fused.first { $0.chunk.chunkID == 2 }!.score
        #expect(score1 > score2)
    }

    @Test func rrfRespectsWeights() {
        let listA = [chunk(1)]
        let listB = [chunk(2)]
        let fused = ReciprocalRankFusion.fuse(lists: [.init(listA, weight: 2.0), .init(listB, weight: 0.1)])
        #expect(fused.first?.chunk.chunkID == 1)
    }

    @Test func groupingSumsChunkContributionsPerDocument() {
        let fused: [(chunk: ScoredChunk, score: Double)] = [
            (chunk(1, doc: 10), 0.5),
            (chunk(2, doc: 10), 0.4),
            (chunk(3, doc: 20), 0.6)
        ]
        let grouped = ResultGrouping.groupByDocument(fused)
        #expect(grouped.first?.documentID == 10)
        #expect(grouped.first?.best.chunkID == 1)
    }
}

@Suite struct FTSQueryBuilderTests {
    @Test func emptyQueryReturnsNil() {
        #expect(FTSQueryBuilder.build(from: "   ") == nil)
        #expect(FTSQueryBuilder.build(from: "!!!") == nil)
    }

    @Test func termsAreQuotedAndPrefixed() {
        #expect(FTSQueryBuilder.build(from: "redis persistence") == "\"redis\"* OR \"persistence\"*")
    }
}

@Suite struct SnippetTests {
    @Test func snippetCentersOnQueryHit() {
        let text = String(repeating: "lorem ipsum ", count: 50) + "deadlock detection here " + String(repeating: "tail ", count: 50)
        let snippet = HybridSearchService.makeSnippet(from: text, query: "deadlock")
        #expect(snippet.lowercased().contains("deadlock"))
        #expect(snippet.count <= 260)
    }

    @Test func snippetFallsBackToPrefix() {
        let text = "this text has no matching term at all"
        let snippet = HybridSearchService.makeSnippet(from: text, query: "xyzzy")
        #expect(snippet.hasPrefix("this text"))
    }
}
