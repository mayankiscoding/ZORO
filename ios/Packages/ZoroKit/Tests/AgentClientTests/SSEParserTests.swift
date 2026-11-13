import Foundation
import Testing
@testable import AgentClient

@Suite("SSE parser")
struct SSEParserTests {
    private func parse(_ chunks: [Data]) -> [SSEEvent] {
        var p = SSEParser()
        var out: [SSEEvent] = []
        for c in chunks { out += p.feed(c) }
        return out + p.finish()
    }

    private func parse(_ chunks: [String]) -> [SSEEvent] { parse(chunks.map { Data($0.utf8) }) }

    @Test func basicEvent() {
        let events = parse(["event: text_delta\ndata: {\"text\":\"hi\"}\n\n"])
        #expect(events == [SSEEvent(event: "text_delta", data: #"{"text":"hi"}"#)])
    }

    @Test func multiLineDataIsJoinedWithNewlines() {
        #expect(parse(["data: one\ndata: two\ndata:three\n\n"]).map(\.data) == ["one\ntwo\nthree"])
    }

    @Test func commentsAndKeepAlivesAreIgnored() {
        let events = parse([": keep-alive\n\n", ":ping\ndata: x\n: mid comment\n\n"])
        #expect(events.map(\.data) == ["x"])
    }

    @Test func crlfAndBareCRLineEndings() {
        #expect(parse(["event: a\r\ndata: 1\r\n\r\nevent: b\rdata: 2\r\r"]).map(\.data) == ["1", "2"])
        #expect(parse(["event: a\r\ndata: 1\r\n\r\n"]).first?.event == "a")
    }

    @Test func crlfSplitAcrossChunksDoesNotCreateAnExtraBlankLine() {
        // If the LF after a chunk-final CR were treated as its own line, "data: 1" would dispatch early
        // and the event name would be lost.
        let events = parse(["event: a\r", "\ndata: 1\r", "\n\r", "\n"])
        #expect(events == [SSEEvent(event: "a", data: "1")])
    }

    @Test func eventSplitAtEveryByte() {
        let raw = "event: text_delta\r\ndata: {\"text\":\"नमस्ते\"}\r\n\r\n"
        let bytes = Array(raw.utf8)
        let events = parse(bytes.map { Data([$0]) })
        #expect(events == [SSEEvent(event: "text_delta", data: #"{"text":"नमस्ते"}"#)])
    }

    @Test func eventWithoutDataIsNotDispatchedAndNameResets() {
        let events = parse(["event: orphan\n\ndata: x\n\n"])
        #expect(events == [SSEEvent(event: nil, data: "x")])
    }

    @Test func fieldsWithoutColonAndUnknownFields() {
        let events = parse(["data\nfoo: bar\n\n"])
        #expect(events == [SSEEvent(data: "")])
    }

    @Test func onlyOneLeadingSpaceIsStripped() {
        #expect(parse(["data:  two spaces\n\n"]).first?.data == " two spaces")
    }

    @Test func idAndRetry() {
        let events = parse(["id: 7\nretry: 1500\ndata: a\n\nretry: x\ndata: b\n\n"])
        #expect(events.map(\.id) == ["7", "7"])
        #expect(events.map(\.retry) == [1500, 1500])
    }

    @Test func leadingBOMIsStripped() {
        var bytes: [UInt8] = [0xEF, 0xBB]
        let rest: [UInt8] = [0xBF] + Array("event: a\ndata: 1\n\n".utf8)
        let events = parse([Data(bytes), Data(rest)])
        #expect(events == [SSEEvent(event: "a", data: "1")])
        bytes = Array("data: z\n\n".utf8)
        #expect(parse([Data(bytes)]).first?.data == "z")
    }

    @Test func trailingEventWithoutBlankLineIsDeliveredAtEnd() {
        #expect(parse(["data: last"]).map(\.data) == ["last"])
    }
}
