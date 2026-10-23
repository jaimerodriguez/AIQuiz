import Foundation
import Testing
@testable import LLMKit

@Suite("SSEDecoder")
struct SSEDecoderTests {
    private func decodeAll(_ text: String, chunkSize: Int) -> [String] {
        var decoder = SSEDecoder()
        var out: [String] = []
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            out += decoder.feed(Data(bytes[i..<min(i + chunkSize, bytes.count)]))
            i += chunkSize
        }
        return out + decoder.finish()
    }

    @Test("events are identical regardless of how bytes are split", arguments: [1, 2, 3, 7, 64, 10_000])
    func splitInvariance(chunkSize: Int) {
        let text = "event: a\ndata: {\"x\":1}\n\nevent: b\ndata: {\"x\":2}\n\n"
        #expect(decodeAll(text, chunkSize: chunkSize) == [#"{"x":1}"#, #"{"x":2}"#])
    }

    @Test("CRLF line endings")
    func crlf() {
        #expect(decodeAll("data: one\r\n\r\ndata: two\r\n\r\n", chunkSize: 4) == ["one", "two"])
    }

    @Test("comments and unknown fields are ignored")
    func comments() {
        #expect(decodeAll(": keepalive\nid: 5\nretry: 10\ndata: x\n\n", chunkSize: 3) == ["x"])
    }

    @Test("multi-line data is joined with newline")
    func multiline() {
        #expect(decodeAll("data: a\ndata: b\n\n", chunkSize: 2) == ["a\nb"])
    }

    @Test("final event without trailing blank line is flushed by finish")
    func flush() {
        #expect(decodeAll("data: [DONE]", chunkSize: 5) == ["[DONE]"])
    }

    @Test("data without a space after the colon")
    func noSpace() {
        #expect(decodeAll("data:{\"k\":true}\n\n", chunkSize: 4) == [#"{"k":true}"#])
    }

    @Test("concatenated JSON lines are split back apart")
    func splitConcatenated() {
        #expect(SSEDecoder.splitIfConcatenated("{\"a\":1}\n{\"b\":2}") == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(SSEDecoder.splitIfConcatenated("{\"a\":1}") == [#"{"a":1}"#])
    }
}
