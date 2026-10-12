import Testing
import Foundation
@testable import RecallCore

@Suite struct TextChunkerTests {
    @Test func shortTextProducesSingleChunk() {
        let chunker = TextChunker(maxChunkSize: 1000, overlap: 100)
        let chunks = chunker.chunk(text: "hello world", pageNumber: 1)
        #expect(chunks.count == 1)
        #expect(chunks.first?.text == "hello world")
        #expect(chunks.first?.pageNumber == 1)
    }

    @Test func emptyTextProducesNoChunks() {
        let chunker = TextChunker()
        #expect(chunker.chunk(text: "   \n\t ", pageNumber: nil).isEmpty)
    }

    @Test func longTextIsSplitIntoMultipleChunks() {
        let chunker = TextChunker(maxChunkSize: 50, overlap: 10)
        let words = Array(repeating: "word", count: 100).joined(separator: " ")
        let chunks = chunker.chunk(text: words, pageNumber: 3)
        #expect(chunks.count > 1)
        for c in chunks {
            #expect(c.text.count <= 50)
            #expect(c.pageNumber == 3)
        }
    }

    @Test func chunksOverlap() {
        let chunker = TextChunker(maxChunkSize: 40, overlap: 15)
        let text = (1...40).map { "t\($0)" }.joined(separator: " ")
        let chunks = chunker.chunk(text: text, pageNumber: nil)
        #expect(chunks.count > 1)
        for i in 0..<(chunks.count - 1) {
            let endTokens = Set(chunks[i].text.split(separator: " ").suffix(3).map(String.init))
            let startTokens = Set(chunks[i + 1].text.split(separator: " ").prefix(3).map(String.init))
            #expect(!endTokens.isDisjoint(with: startTokens))
        }
    }

    @Test func whitespaceIsNormalized() {
        let chunker = TextChunker(maxChunkSize: 1000, overlap: 0)
        let chunks = chunker.chunk(text: "a\n\n  b\t\tc", pageNumber: nil)
        #expect(chunks.first?.text == "a b c")
    }

    @Test func perSegmentPagePreservation() {
        let chunker = TextChunker(maxChunkSize: 1000, overlap: 0)
        let segments = [
            TextSegment(text: "page one content", pageNumber: 1),
            TextSegment(text: "page two content", pageNumber: 2)
        ]
        let chunks = chunker.chunk(segments: segments)
        #expect(chunks.count == 2)
        #expect(chunks[0].pageNumber == 1)
        #expect(chunks[1].pageNumber == 2)
    }
}

@Suite struct ContentHasherTests {
    @Test func sameContentSameHash() {
        #expect(ContentHasher.hash("abc") == ContentHasher.hash("abc"))
    }

    @Test func differentContentDifferentHash() {
        #expect(ContentHasher.hash("abc") != ContentHasher.hash("abd"))
    }

    @Test func knownSHA256Vector() {
        #expect(ContentHasher.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hashFileMatchesStringHash() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("f.txt")
        try "hello file".data(using: .utf8)!.write(to: url)
        let fileHash = try ContentHasher.hashFile(at: url)
        #expect(fileHash == ContentHasher.hash("hello file"))
    }
}
