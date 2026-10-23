import Foundation

/// Incremental Server-Sent Events decoder. Feed it raw byte chunks in any split; it returns
/// the `data` payload of each complete event. Handles `\n` and `\r\n`, comments, `event:`/`id:`
/// fields (ignored) and multi-line data (joined with `\n`).
public struct SSEDecoder: Sendable {
    private var lineBuffer: [UInt8] = []
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        var out: [String] = []
        for byte in data {
            if byte == 0x0A {
                if let payload = processLine() { out.append(payload) }
            } else {
                lineBuffer.append(byte)
            }
        }
        return out
    }

    /// Call at end of stream to flush a final event that was not followed by a blank line.
    public mutating func finish() -> [String] {
        var out: [String] = []
        if !lineBuffer.isEmpty, let payload = processLine() { out.append(payload) }
        if let payload = dispatch() { out.append(payload) }
        return out
    }

    private mutating func processLine() -> String? {
        var line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            dataLines.append(String(value))
        }
        return nil
    }

    private mutating func dispatch() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        return payload
    }

    /// Some servers omit the blank line between events. If a payload is not valid JSON but its
    /// lines are, treat each line as its own payload.
    public static func splitIfConcatenated(_ payload: String) -> [String] {
        guard payload.contains("\n") else { return [payload] }
        if (try? JSONValue.parse(payload)) != nil { return [payload] }
        return payload.split(separator: "\n").map(String.init)
    }
}
