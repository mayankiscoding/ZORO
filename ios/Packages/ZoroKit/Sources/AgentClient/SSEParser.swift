import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?
    public var retry: Int?
    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Incremental `text/event-stream` parser (WHATWG rules): LF, CR and CRLF line endings (including a
/// CRLF split across chunks), comments, multi-line `data`, a leading BOM, and UTF-8 sequences split
/// across chunks. Feed arbitrary chunks; complete events come out in order.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var atStreamStart = true
    private var dataLines: [String] = []
    private var hasData = false
    private var eventName: String?
    private var lastEventId: String?
    private var retry: Int?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for byte in chunk {
            if atStreamStart {
                line.append(byte)
                // Strip a UTF-8 BOM (EF BB BF) at the very start of the stream.
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                if line.count < 3, Array(bom.prefix(line.count)) == line { continue }
                if line == bom {
                    line.removeAll()
                    atStreamStart = false
                    continue
                }
                atStreamStart = false
                let pending = line
                line.removeAll()
                for b in pending { consume(b, into: &out) }
                continue
            }
            consume(byte, into: &out)
        }
        return out
    }

    /// End of stream: a trailing event without its blank line is still delivered when it has data.
    public mutating func finish() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !line.isEmpty { processLine(into: &out) }
        dispatch(into: &out)
        return out
    }

    private mutating func consume(_ byte: UInt8, into out: inout [SSEEvent]) {
        if lastWasCR {
            lastWasCR = false
            if byte == 0x0A { return }  // the LF of a CRLF pair
        }
        switch byte {
        case 0x0D:
            processLine(into: &out)
            lastWasCR = true
        case 0x0A:
            processLine(into: &out)
        default:
            line.append(byte)
        }
    }

    private mutating func processLine(into out: inout [SSEEvent]) {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            dispatch(into: &out)
            return
        }
        if line.first == UInt8(ascii: ":") { return }  // comment / keep-alive
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data":
            dataLines.append(String(value))
            hasData = true
        case "id": if !value.contains("\u{0}") { lastEventId = String(value) }
        case "retry": if !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) { retry = Int(value) }
        default: break
        }
    }

    private mutating func dispatch(into out: inout [SSEEvent]) {
        defer {
            dataLines.removeAll()
            hasData = false
            eventName = nil
        }
        guard hasData else { return }
        out.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastEventId, retry: retry))
    }
}
